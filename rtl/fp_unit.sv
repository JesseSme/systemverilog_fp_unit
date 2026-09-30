// IEEE 754-2019 floating-point unit top level.
//
// Combinational, parameterized by the format: W_EXP exponent bits and W_MANT
// fraction bits (3.3, 3.7 "extendable precision"). Decodes the operation
// select and drives the per-operation datapaths (added incrementally per the
// project plan; add/sub, mul, div, sqrt, fma, min/max, and M6 comparisons /
// roundToIntegral / totalOrder all implemented). OP_MUL selects the multiply
// datapaths (fp_mul/fp_mul_e8m0), OP_DIV the divide datapaths
// (fp_div/fp_div_e8m0), OP_SQRT the square-root datapaths
// (fp_sqrt/fp_sqrt_e8m0), OP_FMA the fused multiply-add datapaths
// (fp_fma/fp_fma_e8m0), OP_MIN/OP_MAX the min/max datapath (fp_minmax,
// format-generic), OP_CMP the comparison datapath (fp_cmp, format-generic),
// OP_TOTALORDER the totalOrder datapath (fp_totalorder, format-generic) and
// OP_RNDINT the roundToIntegral datapaths (fp_roundint/fp_roundint_e8m0);
// OP_ADD/OP_SUB select the add datapaths (fp_add/fp_add_e8m0). `c` is only
// used by OP_FMA.
//
// The `cmp` output carries the 2-bit comparison condition code for OP_CMP
// (fp_pkg::CMP_*) and, for OP_TOTALORDER, cmp[0] = totalOrder(a, b) (a
// precedes-or-equals b); every other op drives cmp = 0.
//
// W_MANT = 0 selects the dedicated E8M0 (1 + W_EXP + 0 bits, microscaling
// shared-exponent format): the generic datapaths cannot be elaborated at that
// width by Verilator 5.020, and the p = 1 tie rules are implemented
// explicitly in the *_e8m0 modules.

module fp_unit #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23,
  // Selects the shared iterative (multi-cycle) radix-4 division/square-root
  // engine (fp_divsqrt_iter) instead of the combinational fp_div/fp_sqrt
  // datapaths. With ITER_DIVSQRT = 1 a div/sqrt transaction is started by
  // pulsing in_valid (ignored while a transaction is in flight); `out_valid`
  // pulses one cycle with the registered result, at a constant latency of
  // K+1 cycles (K = ceil((W_MANT+3)/2)) for every input, including special
  // cases. All other operations keep the 1-cycle registered output. Only
  // supported for W_MANT > 0: E8M0 always uses the dedicated combinational
  // datapaths.
  parameter int ITER_DIVSQRT = 0
) (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    in_valid,
  input  fp_pkg::op_t             mode,
  input  fp_pkg::rounding_t       rm,
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
  input  logic [1+W_EXP+W_MANT-1:0] c,
  output logic [1+W_EXP+W_MANT-1:0] y,
  output logic [1:0]               cmp,
  output logic [4:0]               flags,
  output logic                    out_valid
);

  // Registered output interface (1-stage pipeline). The op datapaths are
  // combinational; y/flags/cmp are sampled into the output registers on every
  // rising edge of clk, so the result of the inputs present in a cycle is
  // available on the cycle after the next posedge. rst_n is a synchronous
  // active-low reset that clears all three outputs.

  logic [1+W_EXP+W_MANT-1:0] y_add;
  logic [4:0]                flags_add;
  logic [1+W_EXP+W_MANT-1:0] y_mul;
  logic [4:0]                flags_mul;
  logic [1+W_EXP+W_MANT-1:0] y_div;
  logic [4:0]                flags_div;
  logic [1+W_EXP+W_MANT-1:0] y_sqrt;
  logic [4:0]                flags_sqrt;
  logic [1+W_EXP+W_MANT-1:0] y_fma;
  logic [4:0]                flags_fma;
  logic [1+W_EXP+W_MANT-1:0] y_mm;
  logic [4:0]                flags_mm;
  logic [1+W_EXP+W_MANT-1:0] y_rnd;
  logic [4:0]                flags_rnd;
  logic [1+W_EXP+W_MANT-1:0] y_cmp;
  logic [4:0]                flags_cmp;
  logic [1:0]                cmp_cmp;
  logic [1+W_EXP+W_MANT-1:0] y_tot;
  logic [4:0]                flags_tot;
  logic [1:0]                cmp_tot;

  // Iterative div/sqrt engine and its handshake (only when selected and the
  // format has a significand; otherwise tied off).
  localparam int W = 1 + W_EXP + W_MANT;
  logic [W-1:0] y_iter;
  logic [4:0]   flags_iter;
  logic         busy_iter, done_iter, iter_run, iter_start;

  generate
    if (ITER_DIVSQRT != 0 && W_MANT > 0) begin : g_divsqrt_iter
      fp_divsqrt_iter #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_divsqrt (
        .a(a), .b(b), .rm(rm), .is_sqrt(mode == fp_pkg::OP_SQRT),
        .start(iter_start), .y(y_iter), .flags(flags_iter),
        .clk(clk), .rst_n(rst_n), .busy(busy_iter), .done(done_iter)
      );
    end else begin : g_no_divsqrt_iter
      assign y_iter     = '0;
      assign flags_iter = 5'd0;
      assign busy_iter  = 1'b0;
      assign done_iter  = 1'b0;
    end
  endgenerate

  // Engine availability (busy) rather than iter_run gates the start, so a new
  // transaction may begin in the same cycle the previous `done`/out_valid
  // pulse is visible (no dead cycle between back-to-back div/sqrt).
  assign iter_start = (ITER_DIVSQRT != 0 && W_MANT > 0) && in_valid
                    && (mode == fp_pkg::OP_DIV || mode == fp_pkg::OP_SQRT)
                    && !busy_iter;

  generate
    if (W_MANT > 0) begin : g_generic
      fp_add #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_add (
        .a(a), .b(b), .rm(rm), .op(mode),
        .y(y_add), .flags(flags_add)
      );
      fp_mul #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_mul (
        .a(a), .b(b), .rm(rm),
        .y(y_mul), .flags(flags_mul)
      );
      if (ITER_DIVSQRT != 0) begin : g_iter_divsqrt
        // Registered engine outputs replace the combinational datapaths.
        assign y_div      = y_iter;
        assign flags_div  = flags_iter;
        assign y_sqrt     = y_iter;
        assign flags_sqrt = flags_iter;
      end else begin : g_comb_divsqrt
        fp_div #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_div (
          .a(a), .b(b), .rm(rm),
          .y(y_div), .flags(flags_div)
        );
        fp_sqrt #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_sqrt (
          .a(a), .rm(rm),
          .y(y_sqrt), .flags(flags_sqrt)
        );
      end
      fp_fma #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_fma (
        .a(a), .b(b), .c(c), .rm(rm),
        .y(y_fma), .flags(flags_fma)
      );
      fp_minmax #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_minmax (
        .a(a), .b(b), .is_max(mode == fp_pkg::OP_MAX), .rm(rm),
        .y(y_mm), .flags(flags_mm)
      );
      fp_roundint #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_roundint (
        .a(a), .rm(rm),
        .y(y_rnd), .flags(flags_rnd)
      );
    end else begin : g_e8m0
      fp_add_e8m0 #(.W_EXP(W_EXP)) u_fp_add (
        .a(a), .b(b), .rm(rm), .op(mode),
        .y(y_add), .flags(flags_add)
      );
      fp_mul_e8m0 #(.W_EXP(W_EXP)) u_fp_mul (
        .a(a), .b(b), .rm(rm),
        .y(y_mul), .flags(flags_mul)
      );
      fp_div_e8m0 #(.W_EXP(W_EXP)) u_fp_div (
        .a(a), .b(b), .rm(rm),
        .y(y_div), .flags(flags_div)
      );
      fp_sqrt_e8m0 #(.W_EXP(W_EXP)) u_fp_sqrt (
        .a(a), .rm(rm),
        .y(y_sqrt), .flags(flags_sqrt)
      );
      fp_fma_e8m0 #(.W_EXP(W_EXP)) u_fp_fma (
        .a(a), .b(b), .c(c), .rm(rm),
        .y(y_fma), .flags(flags_fma)
      );
      fp_minmax #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_minmax (
        .a(a), .b(b), .is_max(mode == fp_pkg::OP_MAX), .rm(rm),
        .y(y_mm), .flags(flags_mm)
      );
      fp_roundint_e8m0 #(.W_EXP(W_EXP)) u_fp_roundint (
        .a(a), .rm(rm),
        .y(y_rnd), .flags(flags_rnd)
      );
    end
  endgenerate

  // Format-generic comparison / totalOrder datapaths (same as fp_minmax,
  // valid at every width including W_MANT = 0).
  fp_cmp #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_cmp (
    .a(a), .b(b), .rm(rm),
    .y(y_cmp), .cmp(cmp_cmp), .flags(flags_cmp)
  );
  fp_totalorder #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_totalorder (
    .a(a), .b(b), .rm(rm),
    .y(y_tot), .cmp(cmp_tot), .flags(flags_tot)
  );

  logic [1+W_EXP+W_MANT-1:0] y_c;
  logic [4:0]                flags_c;
  logic [1:0]                cmp_c;

  always_comb begin
    if (mode == fp_pkg::OP_MUL) begin
      y_c     = y_mul;
      flags_c = flags_mul;
    end else if (mode == fp_pkg::OP_DIV) begin
      y_c     = y_div;
      flags_c = flags_div;
    end else if (mode == fp_pkg::OP_SQRT) begin
      y_c     = y_sqrt;
      flags_c = flags_sqrt;
    end else if (mode == fp_pkg::OP_FMA) begin
      y_c     = y_fma;
      flags_c = flags_fma;
    end else if (mode == fp_pkg::OP_MIN || mode == fp_pkg::OP_MAX) begin
      y_c     = y_mm;
      flags_c = flags_mm;
    end else if (mode == fp_pkg::OP_RNDINT) begin
      y_c     = y_rnd;
      flags_c = flags_rnd;
    end else if (mode == fp_pkg::OP_CMP) begin
      y_c     = y_cmp;
      flags_c = flags_cmp;
    end else if (mode == fp_pkg::OP_TOTALORDER) begin
      y_c     = y_tot;
      flags_c = flags_tot;
    end else begin
      y_c     = y_add;
      flags_c = flags_add;
    end
  end

  always_comb begin
    if (mode == fp_pkg::OP_CMP)
      cmp_c = cmp_cmp;
    else if (mode == fp_pkg::OP_TOTALORDER)
      cmp_c = cmp_tot;
    else
      cmp_c = 2'd0;
  end

  // Output stage. During an iterative div/sqrt transaction the engine's
  // already-registered result is forwarded directly (out_valid = done), which
  // removes the second register stage and makes out_valid appear one cycle
  // after the engine finishes; the identical latency of every div/sqrt input
  // (including special cases) is K+1 cycles from in_valid.
  logic [1+W_EXP+W_MANT-1:0] y_r;
  logic [4:0]                flags_r;
  logic [1:0]                cmp_r;
  logic                      out_valid_r;

  assign y         = iter_run ? y_iter : y_r;
  assign flags     = iter_run ? flags_iter : flags_r;
  assign cmp       = iter_run ? 2'd0 : cmp_r;
  assign out_valid = iter_run ? done_iter : out_valid_r;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      y_r         <= '0;
      flags_r     <= 5'd0;
      cmp_r       <= 2'd0;
      out_valid_r <= 1'b0;
      iter_run    <= 1'b0;
    end else begin
      y_r         <= y_c;
      flags_r     <= flags_c;
      cmp_r       <= cmp_c;
      out_valid_r <= in_valid && !iter_start;
      if (iter_start)
        iter_run <= 1'b1;
      else if (iter_run && done_iter)
        iter_run <= 1'b0;
    end
  end

endmodule
