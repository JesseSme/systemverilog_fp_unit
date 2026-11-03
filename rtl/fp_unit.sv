// IEEE 754-2019 floating-point unit top level.
//
// Parameterized by the format: W_EXP exponent bits and W_MANT fraction bits
// (3.3, 3.7 "extendable precision"). Every operation runs on its own
// pipeline with a fixed, input-independent latency (fp_pkg::lat_* and the
// README latency table); the pipelines share one result port.
//
// Handshake (valid/ready, AXI-stream style):
//   * A request is accepted in a cycle with in_valid && in_ready ("fire").
//     While in_valid && !in_ready the caller must hold mode/rm/a/b/c/in_tag
//     stable. in_ready depends combinationally on `mode` (and on the
//     in-flight state), never on in_valid.
//   * Every accepted request produces exactly one out_valid pulse, with
//     y/flags/cmp and out_tag = the request's in_tag. Results return in
//     completion order (an ADD issued after a SQRT may finish first); use
//     in_tag/out_tag to match them.
//   * in_ready is low only when the requested op would finish in the same
//     cycle as an op already in flight (result-port reservation, `resv`
//     below). A caller that issues one op at a time and waits for out_valid
//     always sees in_ready = 1.
//
// Operation select (`mode`, fp_pkg::op_t): OP_ADD/OP_SUB fp_add_pipe,
// OP_MUL fp_mul_pipe, OP_FMA fp_fma_pipe (`c` is the addend), OP_DIV
// fp_div_srt, OP_SQRT fp_sqrt_srt, OP_RNDINT fp_roundint_pipe, OP_MIN/OP_MAX
// fp_minmax_pipe, OP_CMP fp_cmp_pipe, OP_TOTALORDER fp_totalorder_pipe.
// `cmp` carries the 2-bit comparison condition code for OP_CMP
// (fp_pkg::CMP_*) and, for OP_TOTALORDER, cmp[0] = totalOrder(a, b); every
// other op drives cmp = 0.
//
// W_MANT = 0 selects the dedicated E8M0 datapaths (1 + W_EXP + 0 bits,
// microscaling shared-exponent format; combinational, registered once here,
// so every E8M0 op has latency 1): the generic datapaths cannot be
// elaborated at that width by Verilator 5.020, and the p = 1 tie rules are
// implemented explicitly in the *_e8m0 modules.

module fp_unit #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23,
  // Division / square-root implementation for the generic formats:
  //   1 (default): fully pipelined radix-4 SRT datapaths (fp_div_srt /
  //     fp_sqrt_srt), one start per cycle; sets the clock (5.6 ns on
  //     VU9P-2L, 178.6 MHz).
  //   2: the shared iterative radix-4 engine fp_divsqrt_iter, latency
  //     K+3 (K = floor((W_MANT+3)/2)), ONE div/sqrt in flight at a time
  //     (in_ready is low for div/sqrt while it is busy); closes 4.0 ns
  //     (250 MHz) with about half the LUTs.
  //   0: the combinational reference datapaths (fp_div / fp_sqrt)
  //     registered once (latency 1, very long critical path; reference and
  //     formal only).
  parameter int DIVSQRT_IMPL = 1,
  // Width of the request tag carried from in_tag to out_tag.
  parameter int TAG_W = 1
) (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    in_valid,
  output logic                    in_ready,
  input  fp_pkg::op_t             mode,
  input  fp_pkg::rounding_t       rm,
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
  input  logic [1+W_EXP+W_MANT-1:0] c,
  input  logic [TAG_W-1:0]        in_tag,
  output logic [1+W_EXP+W_MANT-1:0] y,
  output logic [1:0]               cmp,
  output logic [4:0]               flags,
  output logic                    out_valid,
  output logic [TAG_W-1:0]        out_tag
);

  localparam int W = 1 + W_EXP + W_MANT;

  // Reserved encodings (README "Semantics"): rounding modes 5-7 behave as
  // RM_RNE in every datapath; an undefined opcode returns y = 0 with the
  // invalid flag after 1 cycle (through the output register).
  fp_pkg::rounding_t rm_eff;
  assign rm_eff = (rm > fp_pkg::RM_RM) ? fp_pkg::RM_RNE : rm;
  logic op_reserved;
  assign op_reserved = !fp_pkg::op_defined(mode);

  localparam bit GENERIC  = (W_MANT > 0);
  localparam bit SRT_DS   = GENERIC && (DIVSQRT_IMPL == 1);
  localparam bit ITER_DS  = GENERIC && (DIVSQRT_IMPL == 2);
  localparam int DIV_DPS  = 2;  // radix-4 digits per fp_div_srt stage
  localparam int SQRT_DPS = 1;  // radix-4 digits per fp_sqrt_srt stage

  // ------------------------------------------------------------ latencies
  // Cycles from an accepted request to its out_valid. Ops that are not on a
  // dedicated pipeline (E8M0, DIVSQRT_IMPL = 0 div/sqrt, reserved opcodes)
  // go through the 1-cycle output register below.
  localparam int LAT_ADD  = GENERIC ? fp_pkg::LAT_ADD : 1;
  localparam int LAT_MUL  = GENERIC ? fp_pkg::lat_mul(W_MANT) : 1;
  localparam int LAT_FMA  = GENERIC ? fp_pkg::lat_fma(W_MANT) : 1;
  localparam int LAT_DIV  = SRT_DS  ? fp_pkg::lat_div_srt(W_MANT, DIV_DPS)
                          : ITER_DS ? fp_pkg::lat_divsqrt_iter(W_MANT) : 1;
  localparam int LAT_SQRT = SRT_DS  ? fp_pkg::lat_sqrt_srt(W_MANT, SQRT_DPS)
                          : ITER_DS ? fp_pkg::lat_divsqrt_iter(W_MANT) : 1;
  localparam int LAT_RND  = GENERIC ? fp_pkg::LAT_RNDINT : 1;
  localparam int LAT_ORD  = 1;  // min/max/cmp/totalOrder
  localparam int LAT_REG  = 1;  // output-register path
  localparam int MAXLAT   = fp_pkg::max_int(fp_pkg::max_int(fp_pkg::max_int(LAT_ADD, LAT_MUL),
                                                            fp_pkg::max_int(LAT_FMA, LAT_DIV)),
                                             fp_pkg::max_int(LAT_SQRT, LAT_RND));

  int lat_sel;
  always_comb begin
    case (mode)
      fp_pkg::OP_ADD, fp_pkg::OP_SUB: lat_sel = LAT_ADD;
      fp_pkg::OP_MUL:                 lat_sel = LAT_MUL;
      fp_pkg::OP_FMA:                 lat_sel = LAT_FMA;
      fp_pkg::OP_DIV:                 lat_sel = LAT_DIV;
      fp_pkg::OP_SQRT:                lat_sel = LAT_SQRT;
      fp_pkg::OP_RNDINT:              lat_sel = LAT_RND;
      fp_pkg::OP_MIN, fp_pkg::OP_MAX,
      fp_pkg::OP_CMP,
      fp_pkg::OP_TOTALORDER:          lat_sel = LAT_ORD;
      default:                        lat_sel = LAT_REG;
    endcase
  end

  // ------------------------------------------- result-port reservation
  // resv[i] = 1 iff an in-flight request asserts out_valid i cycles from
  // now (i = 0: this cycle, so resv[0] == out_valid). A request with
  // latency L conflicts iff resv[L]; when accepted it books index L-1 of the
  // next cycle's (shifted) vector. resv[MAXLAT] is always 0 in the current
  // cycle; it exists so resv[lat_sel] is always in range.
  logic [MAXLAT:0] resv;
  logic            fire;
  logic            busy_iter;   // DIVSQRT_IMPL = 2: engine occupied
  logic            is_divsqrt;
  assign is_divsqrt = (mode == fp_pkg::OP_DIV) || (mode == fp_pkg::OP_SQRT);
  assign in_ready = !resv[lat_sel] && !(ITER_DS && is_divsqrt && busy_iter);
  assign fire     = in_valid && in_ready;

  always_ff @(posedge clk) begin
    if (!rst_n) resv <= '0;
    else        resv <= (resv >> 1) | (fire ? ((MAXLAT+1)'(1) << (lat_sel - 1)) : '0);
  end

  // Tag slots, shifted exactly like resv; slot 0 belongs to the result that
  // is on the port this cycle.
  logic [TAG_W-1:0] tag_q [MAXLAT+1];
  generate
    for (genvar gi = 0; gi <= MAXLAT; gi++) begin : g_tag
      always_ff @(posedge clk) begin
        if (fire && gi == lat_sel - 1) tag_q[gi] <= in_tag;
        else if (gi < MAXLAT)          tag_q[gi] <= tag_q[(gi < MAXLAT) ? gi + 1 : gi];
        else                           tag_q[gi] <= '0;
      end
    end
  endgenerate
  assign out_tag = tag_q[0];

  // ------------------------------------------------------- start strobes
  logic start_add, start_mul, start_fma, start_div, start_sqrt, start_rnd;
  logic start_mm, start_cmp, start_tot, start_reg;
  assign start_add  = fire && GENERIC && (mode == fp_pkg::OP_ADD || mode == fp_pkg::OP_SUB);
  assign start_mul  = fire && GENERIC && (mode == fp_pkg::OP_MUL);
  assign start_fma  = fire && GENERIC && (mode == fp_pkg::OP_FMA);
  assign start_div  = fire && SRT_DS  && (mode == fp_pkg::OP_DIV);
  assign start_sqrt = fire && SRT_DS  && (mode == fp_pkg::OP_SQRT);
  logic start_iter;
  assign start_iter = fire && ITER_DS && is_divsqrt;
  assign start_rnd  = fire && GENERIC && (mode == fp_pkg::OP_RNDINT);
  assign start_mm   = fire && (mode == fp_pkg::OP_MIN || mode == fp_pkg::OP_MAX);
  assign start_cmp  = fire && (mode == fp_pkg::OP_CMP);
  assign start_tot  = fire && (mode == fp_pkg::OP_TOTALORDER);
  assign start_reg  = fire && !start_add && !start_mul && !start_fma && !start_div
                    && !start_sqrt && !start_iter && !start_rnd && !start_mm && !start_cmp
                    && !start_tot;

  // ---------------------------------------------------------- pipelines
  logic [W-1:0] y_add_p, y_mul_p, y_fma_p, y_div_p, y_sqrt_p, y_rnd_p;
  logic [4:0]   f_add_p, f_mul_p, f_fma_p, f_div_p, f_sqrt_p, f_rnd_p;
  logic         v_add, v_mul, v_fma, v_div, v_sqrt, v_rnd;
  logic [W-1:0] y_iter_p;
  logic [4:0]   f_iter_p;
  logic         v_iter;

  generate
    if (GENERIC) begin : g_generic_pipes
      fp_add_pipe #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_add_pipe (
        .a(a), .b(b), .rm(rm_eff), .op(mode),
        .clk(clk), .rst_n(rst_n), .start(start_add),
        .y(y_add_p), .flags(f_add_p), .out_valid(v_add)
      );
      fp_mul_pipe #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_mul_pipe (
        .a(a), .b(b), .rm(rm_eff),
        .clk(clk), .rst_n(rst_n), .start(start_mul),
        .y(y_mul_p), .flags(f_mul_p), .out_valid(v_mul)
      );
      fp_fma_pipe #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_fma_pipe (
        .a(a), .b(b), .c(c), .rm(rm_eff),
        .clk(clk), .rst_n(rst_n), .start(start_fma),
        .y(y_fma_p), .flags(f_fma_p), .out_valid(v_fma)
      );
      fp_roundint_pipe #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_roundint_pipe (
        .a(a), .rm(rm_eff),
        .clk(clk), .rst_n(rst_n), .start(start_rnd),
        .y(y_rnd_p), .flags(f_rnd_p), .out_valid(v_rnd)
      );
    end else begin : g_no_generic_pipes
      assign {y_add_p, f_add_p, v_add} = '0;
      assign {y_mul_p, f_mul_p, v_mul} = '0;
      assign {y_fma_p, f_fma_p, v_fma} = '0;
      assign {y_rnd_p, f_rnd_p, v_rnd} = '0;
    end

    if (SRT_DS) begin : g_srt
      fp_div_srt #(.W_EXP(W_EXP), .W_MANT(W_MANT), .DPS(DIV_DPS)) u_fp_div_srt (
        .a(a), .b(b), .rm(rm_eff), .start(start_div),
        .y(y_div_p), .flags(f_div_p),
        .clk(clk), .rst_n(rst_n), .out_valid(v_div)
      );
      fp_sqrt_srt #(.W_EXP(W_EXP), .W_MANT(W_MANT), .DPS(SQRT_DPS)) u_fp_sqrt_srt (
        .a(a), .rm(rm_eff), .start(start_sqrt),
        .y(y_sqrt_p), .flags(f_sqrt_p),
        .clk(clk), .rst_n(rst_n), .out_valid(v_sqrt)
      );
    end else begin : g_no_srt
      assign {y_div_p, f_div_p, v_div}    = '0;
      assign {y_sqrt_p, f_sqrt_p, v_sqrt} = '0;
    end

    if (ITER_DS) begin : g_iter
      // One div/sqrt at a time; it accepts a new start in its done cycle
      // (busy is already low then), so back-to-back div/sqrt lose no cycle.
      fp_divsqrt_iter #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_divsqrt_iter (
        .a(a), .b(b), .rm(rm_eff), .is_sqrt(mode == fp_pkg::OP_SQRT),
        .start(start_iter), .y(y_iter_p), .flags(f_iter_p),
        .clk(clk), .rst_n(rst_n), .busy(busy_iter), .done(v_iter)
      );
    end else begin : g_no_iter
      assign {y_iter_p, f_iter_p, v_iter, busy_iter} = '0;
    end
  endgenerate

  // Format-generic min/max, comparison and totalOrder (every width).
  logic [W-1:0] y_mm_p, y_cmp_p;
  logic [4:0]   f_mm_p, f_cmp_p;
  logic [1:0]   c_cmp_p, c_tot_p;
  logic         v_mm, v_cmp, v_tot;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [W-1:0] y_tot_p;   // always 0 (totalOrder result is on cmp)
  logic [4:0]   f_tot_p;   // always 0 (totalOrder never signals)
  /* verilator lint_on UNUSEDSIGNAL */
  fp_minmax_pipe #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_minmax_pipe (
    .a(a), .b(b), .is_max(mode == fp_pkg::OP_MAX),
    .clk(clk), .rst_n(rst_n), .start(start_mm),
    .y(y_mm_p), .flags(f_mm_p), .out_valid(v_mm)
  );
  fp_cmp_pipe #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_cmp_pipe (
    .a(a), .b(b), .clk(clk), .rst_n(rst_n), .start(start_cmp),
    .y(y_cmp_p), .cmp(c_cmp_p), .flags(f_cmp_p), .out_valid(v_cmp)
  );
  fp_totalorder_pipe #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_totalorder_pipe (
    .a(a), .b(b), .clk(clk), .rst_n(rst_n), .start(start_tot),
    .y(y_tot_p), .cmp(c_tot_p), .flags(f_tot_p), .out_valid(v_tot)
  );

  // ---------------------------------- 1-cycle output-register datapaths
  // E8M0 (all non-ordering ops), DIVSQRT_IMPL = 0 div/sqrt, reserved
  // opcodes (y = 0, invalid): combinational datapaths sampled into
  // y_r/flags_r.
  logic [W-1:0] y_c;
  logic [4:0]   flags_c;

  generate
    if (GENERIC) begin : g_generic_comb
      logic [W-1:0] y_div_c, y_sqrt_c;
      logic [4:0]   f_div_c, f_sqrt_c;
      if (!SRT_DS && !ITER_DS) begin : g_comb_divsqrt
        fp_div #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_div (
          .a(a), .b(b), .rm(rm_eff), .y(y_div_c), .flags(f_div_c)
        );
        fp_sqrt #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_sqrt (
          .a(a), .rm(rm_eff), .y(y_sqrt_c), .flags(f_sqrt_c)
        );
      end else begin : g_no_comb_divsqrt
        assign {y_div_c, f_div_c, y_sqrt_c, f_sqrt_c} = '0;
      end
      always_comb begin
        y_c     = '0;
        flags_c = 5'd0;
        case (mode)
          fp_pkg::OP_DIV:  begin y_c = y_div_c;  flags_c = f_div_c;  end
          fp_pkg::OP_SQRT: begin y_c = y_sqrt_c; flags_c = f_sqrt_c; end
          default: ;
        endcase
      end
    end else begin : g_e8m0
      logic [W-1:0] y_add_e, y_mul_e, y_div_e, y_sqrt_e, y_fma_e, y_rnd_e;
      logic [4:0]   f_add_e, f_mul_e, f_div_e, f_sqrt_e, f_fma_e, f_rnd_e;
      fp_add_e8m0 #(.W_EXP(W_EXP)) u_fp_add (
        .a(a), .b(b), .rm(rm_eff), .op(mode), .y(y_add_e), .flags(f_add_e)
      );
      fp_mul_e8m0 #(.W_EXP(W_EXP)) u_fp_mul (
        .a(a), .b(b), .rm(rm_eff), .y(y_mul_e), .flags(f_mul_e)
      );
      fp_div_e8m0 #(.W_EXP(W_EXP)) u_fp_div (
        .a(a), .b(b), .rm(rm_eff), .y(y_div_e), .flags(f_div_e)
      );
      fp_sqrt_e8m0 #(.W_EXP(W_EXP)) u_fp_sqrt (
        .a(a), .rm(rm_eff), .y(y_sqrt_e), .flags(f_sqrt_e)
      );
      fp_fma_e8m0 #(.W_EXP(W_EXP)) u_fp_fma (
        .a(a), .b(b), .c(c), .rm(rm_eff), .y(y_fma_e), .flags(f_fma_e)
      );
      fp_roundint_e8m0 #(.W_EXP(W_EXP)) u_fp_roundint (
        .a(a), .rm(rm_eff), .y(y_rnd_e), .flags(f_rnd_e)
      );
      always_comb begin
        y_c     = '0;
        flags_c = 5'd0;
        case (mode)
          fp_pkg::OP_ADD,
          fp_pkg::OP_SUB:    begin y_c = y_add_e;  flags_c = f_add_e;  end
          fp_pkg::OP_MUL:    begin y_c = y_mul_e;  flags_c = f_mul_e;  end
          fp_pkg::OP_DIV:    begin y_c = y_div_e;  flags_c = f_div_e;  end
          fp_pkg::OP_SQRT:   begin y_c = y_sqrt_e; flags_c = f_sqrt_e; end
          fp_pkg::OP_FMA:    begin y_c = y_fma_e;  flags_c = f_fma_e;  end
          fp_pkg::OP_RNDINT: begin y_c = y_rnd_e;  flags_c = f_rnd_e;  end
          default: ;
        endcase
      end
    end
  endgenerate

  logic [W-1:0] y_r;
  logic [4:0]   flags_r;
  logic         v_reg;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      y_r     <= '0;
      flags_r <= 5'd0;
      v_reg   <= 1'b0;
    end else begin
      y_r     <= op_reserved ? '0 : y_c;
      flags_r <= op_reserved ? (5'd1 << fp_pkg::FLAG_INVALID) : flags_c;
      v_reg   <= start_reg;
    end
  end

  // ------------------------------------------------------ result port
  // At most one of the valids is set in any cycle (guaranteed by resv), so
  // the mux order is irrelevant.
  always_comb begin
    y     = y_r;
    flags = flags_r;
    cmp   = 2'd0;
    if (v_mul)  begin y = y_mul_p;  flags = f_mul_p;  end
    if (v_fma)  begin y = y_fma_p;  flags = f_fma_p;  end
    if (v_add)  begin y = y_add_p;  flags = f_add_p;  end
    if (v_rnd)  begin y = y_rnd_p;  flags = f_rnd_p;  end
    if (v_div)  begin y = y_div_p;  flags = f_div_p;  end
    if (v_sqrt) begin y = y_sqrt_p; flags = f_sqrt_p; end
    if (v_iter) begin y = y_iter_p; flags = f_iter_p; end
    if (v_mm)   begin y = y_mm_p;   flags = f_mm_p;   end
    if (v_cmp)  begin y = y_cmp_p;  flags = f_cmp_p;  cmp = c_cmp_p; end
    if (v_tot)  begin y = '0;       flags = 5'd0;     cmp = c_tot_p; end
  end
  assign out_valid = v_mul | v_fma | v_add | v_rnd | v_div | v_sqrt | v_iter
                   | v_mm | v_cmp | v_tot | v_reg;

`ifndef SYNTHESIS
  // The reservation vector must predict every result exactly (a wrong
  // latency constant fires this on the first vector), and the per-pipeline
  // valids must never collide.
  always_ff @(posedge clk) begin
    if (rst_n) begin
      assert (out_valid == resv[0])
        else $error("fp_unit: out_valid=%0b but resv[0]=%0b (latency table mismatch)",
                    out_valid, resv[0]);
      assert ($onehot0({v_mul, v_fma, v_add, v_rnd, v_div, v_sqrt, v_iter,
                        v_mm, v_cmp, v_tot, v_reg}))
        else $error("fp_unit: result-port collision");
    end
  end
`endif

endmodule
