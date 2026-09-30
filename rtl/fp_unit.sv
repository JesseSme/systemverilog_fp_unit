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
  // engine (fp_divsqrt_iter) instead of the legacy combinational
  // fp_div/fp_sqrt datapaths (the Fmax-optimized default). A div/sqrt
  // transaction is started by pulsing in_valid (ignored while a transaction
  // is in flight); `out_valid` pulses one cycle with the registered result at
  // a constant, input-independent latency. All operations of the generic
  // datapath are pipelined with fixed per-operation latencies (see README);
  // only W_MANT = 0 (E8M0) uses the dedicated combinational modules.
  // ITER_DIVSQRT = 0 selects the legacy combinational divider/square root
  // (1-cycle, much longer critical path; kept for reference/formal).
  parameter int ITER_DIVSQRT = 1
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
  logic [1+W_EXP+W_MANT-1:0] y_rnd;
  logic [4:0]                flags_rnd;

  // Iterative div/sqrt engine and its handshake (only when selected and the
  // format has a significand; otherwise tied off).
  localparam int W = 1 + W_EXP + W_MANT;
  logic [W-1:0] y_iter;
  logic [4:0]   flags_iter;
  logic         busy_iter, done_iter, iter_run, iter_start;

  // Pipelined add/sub (generic formats); the other ops are still on the
  // 1-cycle legacy path while they are converted.
  localparam bit PIPE_ADD = (W_MANT > 0);
  logic [W-1:0] y_add_pipe;
  logic [4:0]   flags_add_pipe;
  logic         add_valid;
  logic         use_pipe_add;
  assign use_pipe_add = PIPE_ADD && (mode == fp_pkg::OP_ADD || mode == fp_pkg::OP_SUB);
  // Pipelined multiply (generic formats); same pattern as add/sub above.
  localparam bit PIPE_MUL = (W_MANT > 0);
  logic [W-1:0] y_mul_pipe;
  logic [4:0]   flags_mul_pipe;
  logic         mul_valid;
  logic         use_pipe_mul;
  assign use_pipe_mul = PIPE_MUL && (mode == fp_pkg::OP_MUL);
  logic start_mul;
  assign start_mul = in_valid && use_pipe_mul;

  // Pipelined FMA (generic formats).
  localparam bit PIPE_FMA = (W_MANT > 0);
  logic [W-1:0] y_fma_pipe;
  logic [4:0]   flags_fma_pipe;
  logic         fma_valid;
  logic         use_pipe_fma;
  assign use_pipe_fma = PIPE_FMA && (mode == fp_pkg::OP_FMA);
  logic start_fma;
  assign start_fma = in_valid && use_pipe_fma;

  // Pipelined roundToIntegral (generic formats).
  localparam bit PIPE_RND = (W_MANT > 0);
  logic [W-1:0] y_rnd_pipe;
  logic [4:0]   flags_rnd_pipe;
  logic         rnd_valid;
  logic         use_pipe_rnd;
  assign use_pipe_rnd = PIPE_RND && (mode == fp_pkg::OP_RNDINT);
  logic start_rnd;
  assign start_rnd = in_valid && use_pipe_rnd;

  // Pipelined min/max, comparison and totalOrder (format-generic).
  logic [W-1:0] y_mm_pipe, y_cmp_pipe, y_tot_pipe;
  logic [4:0]   flags_mm_pipe, flags_cmp_pipe;
  logic [1:0]   cmp_cmp_pipe, cmp_tot_pipe;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [4:0]   flags_tot_pipe;
  /* verilator lint_on UNUSEDSIGNAL */
  logic         mm_valid, cmp_valid, tot_valid;
  logic start_mm, start_cmp, start_tot;
  assign start_mm  = in_valid && (mode == fp_pkg::OP_MIN || mode == fp_pkg::OP_MAX);
  assign start_cmp = in_valid && (mode == fp_pkg::OP_CMP);
  assign start_tot = in_valid && (mode == fp_pkg::OP_TOTALORDER);

  logic start_add;
  assign start_add = in_valid && use_pipe_add;

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
    if (PIPE_ADD) begin : g_add_pipe
      fp_add_pipe #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_add_pipe (
        .a(a), .b(b), .rm(rm), .op(mode),
        .clk(clk), .rst_n(rst_n), .start(start_add),
        .y(y_add_pipe), .flags(flags_add_pipe), .out_valid(add_valid)
      );
    end else begin : g_no_add_pipe
      assign y_add_pipe     = '0;
      assign flags_add_pipe = 5'd0;
      assign add_valid      = 1'b0;
    end
  endgenerate

  generate
    if (PIPE_RND) begin : g_rnd_pipe
      fp_roundint_pipe #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_roundint_pipe (
        .a(a), .rm(rm),
        .clk(clk), .rst_n(rst_n), .start(start_rnd),
        .y(y_rnd_pipe), .flags(flags_rnd_pipe), .out_valid(rnd_valid)
      );
    end else begin : g_no_rnd_pipe
      assign y_rnd_pipe     = '0;
      assign flags_rnd_pipe = 5'd0;
      assign rnd_valid      = 1'b0;
    end
  endgenerate

  generate
    if (PIPE_FMA) begin : g_fma_pipe
      fp_fma_pipe #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_fma_pipe (
        .a(a), .b(b), .c(c), .rm(rm),
        .clk(clk), .rst_n(rst_n), .start(start_fma),
        .y(y_fma_pipe), .flags(flags_fma_pipe), .out_valid(fma_valid)
      );
    end else begin : g_no_fma_pipe
      assign y_fma_pipe     = '0;
      assign flags_fma_pipe = 5'd0;
      assign fma_valid      = 1'b0;
    end
  endgenerate

  generate
    if (PIPE_MUL) begin : g_mul_pipe
      fp_mul_pipe #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_mul_pipe (
        .a(a), .b(b), .rm(rm),
        .clk(clk), .rst_n(rst_n), .start(start_mul),
        .y(y_mul_pipe), .flags(flags_mul_pipe), .out_valid(mul_valid)
      );
    end else begin : g_no_mul_pipe
      assign y_mul_pipe     = '0;
      assign flags_mul_pipe = 5'd0;
      assign mul_valid      = 1'b0;
    end
  endgenerate

  generate
    if (W_MANT > 0) begin : g_generic
      // fp_add/fp_mul are replaced by the pipelined modules above; alias the
      // (registered) pipelined outputs so the legacy result mux stays
      // consistent.
      assign y_add     = y_add_pipe;
      assign flags_add = flags_add_pipe;
      assign y_mul     = y_mul_pipe;
      assign flags_mul = flags_mul_pipe;
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
      // fp_fma is replaced by the pipelined module above.
      assign y_fma     = y_fma_pipe;
      assign flags_fma = flags_fma_pipe;
      // fp_roundint is replaced by the pipelined module above.
      assign y_rnd     = y_rnd_pipe;
      assign flags_rnd = flags_rnd_pipe;
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
      fp_roundint_e8m0 #(.W_EXP(W_EXP)) u_fp_roundint (
        .a(a), .rm(rm),
        .y(y_rnd), .flags(flags_rnd)
      );
    end
  endgenerate

  // Pipelined format-generic min/max, comparison and totalOrder.
  fp_minmax_pipe #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_minmax_pipe (
    .a(a), .b(b), .is_max(mode == fp_pkg::OP_MAX),
    .clk(clk), .rst_n(rst_n), .start(start_mm),
    .y(y_mm_pipe), .flags(flags_mm_pipe), .out_valid(mm_valid)
  );
  fp_cmp_pipe #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_cmp_pipe (
    .a(a), .b(b), .clk(clk), .rst_n(rst_n), .start(start_cmp),
    .y(y_cmp_pipe), .cmp(cmp_cmp_pipe), .flags(flags_cmp_pipe), .out_valid(cmp_valid)
  );
  fp_totalorder_pipe #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_totalorder_pipe (
    .a(a), .b(b), .clk(clk), .rst_n(rst_n), .start(start_tot),
    .y(y_tot_pipe), .cmp(cmp_tot_pipe), .flags(flags_tot_pipe), .out_valid(tot_valid)
  );

  // Legacy format-generic comparison / totalOrder datapaths (same as fp_minmax,
  // valid at every width including W_MANT = 0).

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
    end else if (mode == fp_pkg::OP_RNDINT) begin
      y_c     = y_rnd;
      flags_c = flags_rnd;
    end else begin
      y_c     = y_add;
      flags_c = flags_add;
    end
  end

  assign cmp_c = 2'd0;  // cmp/direct comparison results come from the pipes

  // Output stage. During an iterative div/sqrt transaction the engine's
  // already-registered result is forwarded directly (out_valid = done), which
  // removes the second register stage and makes out_valid appear one cycle
  // after the engine finishes; the identical latency of every div/sqrt input
  // (including special cases) is K+1 cycles from in_valid.
  logic [1+W_EXP+W_MANT-1:0] y_r;
  logic [4:0]                flags_r;
  logic [1:0]                cmp_r;
  logic                      out_valid_r;

  assign y         = mul_valid ? y_mul_pipe
                   : fma_valid ? y_fma_pipe
                   : add_valid ? y_add_pipe
                   : rnd_valid ? y_rnd_pipe
                   : mm_valid ? y_mm_pipe
                   : cmp_valid ? y_cmp_pipe
                   : tot_valid ? y_tot_pipe
                   : (iter_run ? y_iter : y_r);
  assign flags     = mul_valid ? flags_mul_pipe
                   : fma_valid ? flags_fma_pipe
                   : add_valid ? flags_add_pipe
                   : rnd_valid ? flags_rnd_pipe
                   : mm_valid ? flags_mm_pipe
                   : cmp_valid ? flags_cmp_pipe
                   : tot_valid ? 5'd0
                   : (iter_run ? flags_iter : flags_r);
  assign cmp       = iter_run ? 2'd0
                   : cmp_valid ? cmp_cmp_pipe
                   : tot_valid ? cmp_tot_pipe
                   : cmp_r;
  assign out_valid = mul_valid | fma_valid | add_valid | rnd_valid
                   | mm_valid | cmp_valid | tot_valid
                   | (iter_run ? done_iter : out_valid_r);

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
      out_valid_r <= in_valid && !iter_start && !start_add && !start_mul
                   && !start_fma && !start_rnd && !start_mm && !start_cmp && !start_tot;
      if (iter_start)
        iter_run <= 1'b1;
      else if (iter_run && done_iter)
        iter_run <= 1'b0;
    end
  end

endmodule
