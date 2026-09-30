// Pipelined IEEE 754-2019 fused multiply-add: (a x b) + c, single rounding.
//
// Same semantics as fp_fma.sv (special cases, exact-sum accumulator, single
// GRS rounding, subnormal/overflow rules). The exact significand product
// comes from the LUT-only fp_mul_core (latency 3), then the wide exact sum
// and normalization are pipelined:
//
//   cycle 0        unpack/classify/special; core start with s_a, s_b
//   cycles 1-3     core reduction tree
//   stage F1 (reg after cycle 3)   E, top, shift amounts
//   stage F2 (reg after cycle 4)   place product and c in the accumulator
//   stage F3 (reg after cycle 5)   3p+6-bit sign-magnitude add/sub
//   stage F4 (reg after cycle 6)   normalize (leading-one + shift)
//   stage F5 (reg after cycle 7)   GRS round, overflow/subnormal, encode
//
// Fixed latency: 8 cycles from `start` to `out_valid`.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */

module fp_fma_pipe #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23
) (
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
  input  logic [1+W_EXP+W_MANT-1:0] c,
  input  fp_pkg::rounding_t         rm,
  input  logic                      clk,
  input  logic                      rst_n,
  input  logic                      start,
  output logic [1+W_EXP+W_MANT-1:0] y,
  output logic [4:0]                flags,
  output logic                      out_valid
);

  localparam int W       = 1 + W_EXP + W_MANT;
  localparam int BIAS    = (1 << (W_EXP-1)) - 1;
  localparam int EMAX    = BIAS;
  localparam int EMIN    = 1 - BIAS;
  localparam int S_W     = W_MANT + 1;
  localparam int MANT_W  = (W_MANT > 0) ? W_MANT : 1;
  localparam int TARGET  = S_W + 2;
  localparam int FW      = S_W + 3;
  localparam int P_W     = 2 * S_W;
  localparam int ACC_W   = 3 * S_W + 6;
  localparam int PTOP    = ACC_W - 1;
  localparam int EXP_ALL = (1 << W_EXP) - 1;
  localparam int EXP_MAXF = (1 << W_EXP) - 2;
  localparam logic [MANT_W-1:0] QUIET = (MANT_W)'(1) << (MANT_W - 1);
  localparam logic signed [W_EXP+4:0] EMAX_S = (W_EXP+4)'(EMAX);
  localparam logic signed [W_EXP+4:0] EMIN_S = (W_EXP+4)'(EMIN);
  localparam int BL_W = $clog2(S_W + 1);
  localparam int SH_W = W_EXP + 6;  // signed shift-amount width (covers the full exponent range)

  // ============================================================ cycle 0
  logic              a_sign, b_sign, c_sign;
  logic [W_EXP-1:0]  a_exp, b_exp, c_exp;
  logic [MANT_W-1:0] a_mant, b_mant, c_mant;
  assign a_sign = a[W-1];
  assign a_exp  = a[W-2 -: W_EXP];
  assign b_sign = b[W-1];
  assign b_exp  = b[W-2 -: W_EXP];
  assign c_sign = c[W-1];
  assign c_exp  = c[W-2 -: W_EXP];
  always_comb begin
    a_mant = '0;
    b_mant = '0;
    c_mant = '0;
    if (W_MANT > 0) begin
      a_mant = a[W_MANT-1:0];
      b_mant = b[W_MANT-1:0];
      c_mant = c[W_MANT-1:0];
    end
  end

  logic a_nan, a_snan, a_inf, a_zero, a_sub;
  logic b_nan, b_snan, b_inf, b_zero, b_sub;
  logic c_nan, c_snan, c_inf, c_zero, c_sub;
  assign a_nan  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant != '0);
  assign a_snan = a_nan && !a_mant[MANT_W-1];
  assign a_inf  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant == '0);
  assign a_zero = (a_exp == '0) && (a_mant == '0);
  assign a_sub  = (a_exp == '0) && (a_mant != '0);
  assign b_nan  = (b_exp == EXP_ALL[W_EXP-1:0]) && (b_mant != '0);
  assign b_snan = b_nan && !b_mant[MANT_W-1];
  assign b_inf  = (b_exp == EXP_ALL[W_EXP-1:0]) && (b_mant == '0);
  assign b_zero = (b_exp == '0) && (b_mant == '0);
  assign b_sub  = (b_exp == '0) && (b_mant != '0);
  assign c_nan  = (c_exp == EXP_ALL[W_EXP-1:0]) && (c_mant != '0);
  assign c_snan = c_nan && !c_mant[MANT_W-1];
  assign c_inf  = (c_exp == EXP_ALL[W_EXP-1:0]) && (c_mant == '0);
  assign c_zero = (c_exp == '0) && (c_mant == '0);
  assign c_sub  = (c_exp == '0) && (c_mant != '0);

  logic [W-1:0] y_special;
  logic [4:0]   flags_special;
  logic         special_case;
  logic         prod_sign;
  assign prod_sign = a_sign ^ b_sign;
  always_comb begin
    y_special    = '0;
    flags_special = '0;
    special_case = 1'b0;
    if (a_nan || b_nan || c_nan) begin
      y_special = {1'b0, EXP_ALL[W_EXP-1:0],
                   (a_nan ? a_mant : (b_nan ? b_mant : c_mant)) | QUIET};
      flags_special[fp_pkg::FLAG_INVALID] = a_snan || b_snan || c_snan;
      special_case = 1'b1;
    end else if ((a_inf && b_zero) || (a_zero && b_inf)) begin
      y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
      flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
      special_case = 1'b1;
    end else if (a_inf || b_inf) begin
      if (c_inf && (c_sign != prod_sign)) begin
        y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
        flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
      end else begin
        y_special = {prod_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      end
      special_case = 1'b1;
    end else if (c_inf) begin
      y_special = {c_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      special_case = 1'b1;
    end else if (a_zero || b_zero) begin
      if (c_zero) begin
        y_special = {(prod_sign == c_sign) ? prod_sign : (rm == fp_pkg::RM_RM),
                     {W_EXP{1'b0}}, {W_MANT{1'b0}}};
      end else begin
        y_special = c;
      end
      special_case = 1'b1;
    end
  end

  logic [S_W-1:0] s_a, s_b, s_c;
  assign s_a = a_sub ? {1'b0, a_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, a_mant};
  assign s_b = b_sub ? {1'b0, b_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, b_mant};
  assign s_c = c_sub ? {1'b0, c_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, c_mant};

  function automatic int unsigned bitlen(input logic [S_W-1:0] x);
    bitlen = 0;
    for (int i = 0; i < S_W; i++)
      if (x[i]) bitlen = i + 1;
  endfunction

  logic signed [W_EXP+2:0] e_a, e_b, e_c;
  always_comb begin
    int bl_a, bl_b, bl_c;
    bl_a = int'(bitlen(s_a));
    bl_b = int'(bitlen(s_b));
    bl_c = int'(bitlen(s_c));
    e_a = (W_EXP+3)'(a_exp - BIAS);
    if (a_sub) e_a = (W_EXP+3)'((1 - BIAS) - W_MANT + $signed(bl_a) - 1);
    e_b = (W_EXP+3)'(b_exp - BIAS);
    if (b_sub) e_b = (W_EXP+3)'((1 - BIAS) - W_MANT + $signed(bl_b) - 1);
    e_c = (W_EXP+3)'(c_exp - BIAS);
    if (c_sub) e_c = (W_EXP+3)'((1 - BIAS) - W_MANT + $signed(bl_c) - 1);
  end

  logic [P_W-1:0] P;
  logic           core_valid;
  fp_mul_core #(.W(S_W)) u_core (
    .clk(clk), .rst_n(rst_n), .start(start),
    .a(s_a), .b(s_b), .p(P), .out_valid(core_valid)
  );

  // context registers (valid from cycle 1; consumed from stage F1 on)
  logic [W-1:0]   y_special_s1;
  logic [4:0]     flags_special_s1;
  logic           special_s1;
  logic           prod_sign_s1, c_sign_s1, c_zero_s1;
  logic [S_W-1:0] s_c_s1;
  logic signed [W_EXP+2:0] e_a_s1, e_b_s1, e_c_s1;
  logic [BL_W-1:0] bl_a_s1, bl_b_s1, bl_c_s1;
  logic [2:0]     rm_s1;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      y_special_s1     <= '0;
      flags_special_s1 <= 5'd0;
      special_s1       <= 1'b0;
      prod_sign_s1     <= 1'b0;
      c_sign_s1        <= 1'b0;
      c_zero_s1        <= 1'b0;
      s_c_s1           <= '0;
      e_a_s1           <= '0;
      e_b_s1           <= '0;
      e_c_s1           <= '0;
      bl_a_s1          <= '0;
      bl_b_s1          <= '0;
      bl_c_s1          <= '0;
      rm_s1            <= 3'd0;
    end else begin
      y_special_s1     <= y_special;
      flags_special_s1 <= flags_special;
      special_s1       <= special_case;
      prod_sign_s1     <= prod_sign;
      c_sign_s1        <= c_sign;
      c_zero_s1        <= c_zero;
      s_c_s1           <= s_c;
      e_a_s1           <= e_a;
      e_b_s1           <= e_b;
      e_c_s1           <= e_c;
      bl_a_s1          <= BL_W'(bitlen(s_a));
      bl_b_s1          <= BL_W'(bitlen(s_b));
      bl_c_s1          <= BL_W'(bitlen(s_c));
      rm_s1            <= rm;
    end
  end

  // ============================================================ stage F1
  function automatic int unsigned pbitlen(input logic [P_W-1:0] x);
    pbitlen = 0;
    for (int i = 0; i < P_W; i++)
      if (x[i]) pbitlen = i + 1;
  endfunction

  logic signed [W_EXP+3:0] E_f1, top_f1;
  logic signed [SH_W-1:0]  shift_p_f1, shift_c_f1;
  always_comb begin
    logic signed [W_EXP+3:0] prod_top;
    E_f1 = (W_EXP+4)'(e_a_s1) + (W_EXP+4)'(e_b_s1)
         - (W_EXP+4)'(bl_a_s1) - (W_EXP+4)'(bl_b_s1)
         + (W_EXP+4)'(2);
    prod_top = E_f1 + (W_EXP+4)'($signed(pbitlen(P))) - (W_EXP+4)'(1);
    top_f1 = (c_zero_s1 || prod_top >= (W_EXP+4)'(e_c_s1)) ? prod_top
                                                           : (W_EXP+4)'(e_c_s1);
    shift_p_f1 = SH_W'(int'(PTOP) - int'(top_f1) + int'(E_f1));
    shift_c_f1 = SH_W'(int'(PTOP) - int'(top_f1) + int'(e_c_s1)
                        - int'(bl_c_s1) + 1);
  end

  logic [P_W-1:0]          P_f1;
  logic signed [W_EXP+3:0] top_f1r;
  logic signed [SH_W-1:0]  shift_p_f1r, shift_c_f1r;
  logic [S_W-1:0]          s_c_f1;
  logic                    prod_sign_f1, c_sign_f1, c_zero_f1;
  logic [2:0]              rm_f1;
  logic [W-1:0]            y_special_f1;
  logic [4:0]              flags_special_f1;
  logic                    special_f1;
  logic                    f1_valid;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      P_f1             <= '0;
      top_f1r          <= '0;
      shift_p_f1r      <= '0;
      shift_c_f1r      <= '0;
      s_c_f1           <= '0;
      prod_sign_f1     <= 1'b0;
      c_sign_f1        <= 1'b0;
      c_zero_f1        <= 1'b0;
      rm_f1            <= 3'd0;
      y_special_f1     <= '0;
      flags_special_f1 <= 5'd0;
      special_f1       <= 1'b0;
      f1_valid         <= 1'b0;
    end else begin
      P_f1             <= P;
      top_f1r          <= top_f1;
      shift_p_f1r      <= shift_p_f1;
      shift_c_f1r      <= shift_c_f1;
      s_c_f1           <= s_c_s1;
      prod_sign_f1     <= prod_sign_s1;
      c_sign_f1        <= c_sign_s1;
      c_zero_f1        <= c_zero_s1;
      rm_f1            <= rm_s1;
      y_special_f1     <= y_special_s1;
      flags_special_f1 <= flags_special_s1;
      special_f1       <= special_s1;
      f1_valid         <= core_valid;
    end
  end

  // ============================================================ stage F2
  logic [ACC_W-1:0] placed_p_f2, placed_c_f2;
  logic             sticky_p_f2, sticky_c_f2;
  always_comb begin
    int sp, sc;
    sp = int'(shift_p_f1r);
    sc = int'(shift_c_f1r);
    // product
    if (sp >= 0) begin
      placed_p_f2 = (sp >= ACC_W) ? '0 : (ACC_W)'(P_f1) << sp;
      sticky_p_f2 = 1'b0;
    end else begin
      placed_p_f2 = (sp <= -P_W) ? '0 : (ACC_W)'(P_f1 >> (-sp));
      sticky_p_f2 = (sp <= -P_W) ? (|P_f1)
                                 : |(P_f1 & (((P_W)'(1) << (-sp)) - 1));
    end
    // c addend
    if (c_zero_f1) begin
      placed_c_f2 = '0;
      sticky_c_f2 = 1'b0;
    end else if (sc >= 0) begin
      placed_c_f2 = (sc >= ACC_W) ? '0 : (ACC_W)'(s_c_f1) << sc;
      sticky_c_f2 = 1'b0;
    end else begin
      placed_c_f2 = (sc <= -S_W) ? '0 : (ACC_W)'(s_c_f1 >> (-sc));
      sticky_c_f2 = (sc <= -S_W) ? (|s_c_f1)
                                 : |(s_c_f1 & (((S_W)'(1) << (-sc)) - 1));
    end
  end

  logic [ACC_W-1:0] placed_p_f2r, placed_c_f2r;
  logic             sticky_p_f2r, sticky_c_f2r;
  logic signed [W_EXP+3:0] top_f2;
  logic             prod_sign_f2, c_sign_f2;
  logic [2:0]       rm_f2;
  logic [W-1:0]     y_special_f2;
  logic [4:0]       flags_special_f2;
  logic             special_f2;
  logic             f2_valid;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      placed_p_f2r     <= '0;
      placed_c_f2r     <= '0;
      sticky_p_f2r     <= 1'b0;
      sticky_c_f2r     <= 1'b0;
      top_f2           <= '0;
      prod_sign_f2     <= 1'b0;
      c_sign_f2        <= 1'b0;
      rm_f2            <= 3'd0;
      y_special_f2     <= '0;
      flags_special_f2 <= 5'd0;
      special_f2       <= 1'b0;
      f2_valid         <= 1'b0;
    end else begin
      placed_p_f2r     <= placed_p_f2;
      placed_c_f2r     <= placed_c_f2;
      sticky_p_f2r     <= sticky_p_f2;
      sticky_c_f2r     <= sticky_c_f2;
      top_f2           <= top_f1r;
      prod_sign_f2     <= prod_sign_f1;
      c_sign_f2        <= c_sign_f1;
      rm_f2            <= rm_f1;
      y_special_f2     <= y_special_f1;
      flags_special_f2 <= flags_special_f1;
      special_f2       <= special_f1;
      f2_valid         <= f1_valid;
    end
  end

  // ============================================================ stage F3
  logic         same_sign_f3;
  logic [ACC_W:0] acc_f3;
  logic         rsign_f3, cancel_f3;
  assign same_sign_f3 = (prod_sign_f2 == c_sign_f2);
  always_comb begin
    if (same_sign_f3) begin
      acc_f3    = {1'b0, placed_p_f2r} + {1'b0, placed_c_f2r};
      rsign_f3  = prod_sign_f2;
      cancel_f3 = 1'b0;
    end else if (placed_p_f2r >= placed_c_f2r) begin
      acc_f3    = {1'b0, placed_p_f2r} - {1'b0, placed_c_f2r};
      rsign_f3  = prod_sign_f2;
      cancel_f3 = (acc_f3 == '0);
      if (sticky_p_f2r | sticky_c_f2r) acc_f3 = acc_f3 - 1;
    end else begin
      acc_f3    = {1'b0, placed_c_f2r} - {1'b0, placed_p_f2r};
      rsign_f3  = c_sign_f2;
      cancel_f3 = (acc_f3 == '0);
      if (sticky_p_f2r | sticky_c_f2r) acc_f3 = acc_f3 - 1;
    end
  end

  logic [ACC_W:0] acc_f3r;
  logic           rsign_f3r, cancel_f3r;
  logic             sticky_p_f3r, sticky_c_f3r;
  logic signed [W_EXP+3:0] top_f3;
  logic [2:0]       rm_f3;
  logic [W-1:0]     y_special_f3;
  logic [4:0]       flags_special_f3;
  logic             special_f3;
  logic             f3_valid;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      acc_f3r          <= '0;
      rsign_f3r        <= 1'b0;
      cancel_f3r       <= 1'b0;
      sticky_p_f3r     <= 1'b0;
      sticky_c_f3r     <= 1'b0;
      top_f3           <= '0;
      rm_f3            <= 3'd0;
      y_special_f3     <= '0;
      flags_special_f3 <= 5'd0;
      special_f3       <= 1'b0;
      f3_valid         <= 1'b0;
    end else begin
      acc_f3r          <= acc_f3;
      rsign_f3r        <= rsign_f3;
      cancel_f3r       <= cancel_f3;
      sticky_p_f3r     <= sticky_p_f2r;
      sticky_c_f3r     <= sticky_c_f2r;
      top_f3           <= top_f2;
      rm_f3            <= rm_f2;
      y_special_f3     <= y_special_f2;
      flags_special_f3 <= flags_special_f2;
      special_f3       <= special_f2;
      f3_valid         <= f2_valid;
    end
  end

  // ============================================================ stage F4
  int                  p0_f4;
  logic [FW-1:0]       norm_f4;
  logic                norm_sticky_f4;
  logic signed [W_EXP+3:0] e_res_f4;
  always_comb begin
    p0_f4 = 0;
    norm_sticky_f4 = 1'b0;
    for (int i = 0; i <= ACC_W; i++)
      if (acc_f3r[i]) p0_f4 = i;
    if (p0_f4 > TARGET) begin
      norm_f4 = acc_f3r >> (p0_f4 - TARGET);
      norm_sticky_f4 = sticky_p_f3r | sticky_c_f3r
                     | |(acc_f3r & (((ACC_W+1)'(1) << (p0_f4 - TARGET)) - 1));
    end else if (p0_f4 < TARGET) begin
      norm_f4 = acc_f3r << (TARGET - p0_f4);
      norm_sticky_f4 = sticky_p_f3r | sticky_c_f3r;
    end else begin
      norm_f4 = acc_f3r;
      norm_sticky_f4 = sticky_p_f3r | sticky_c_f3r;
    end
    e_res_f4 = top_f3 + (W_EXP+4)'($signed(p0_f4) - PTOP);
  end

  logic [FW-1:0]   norm_f4r;
  logic            norm_sticky_f4r;
  logic signed [W_EXP+3:0] e_res_f4r;
  logic            rsign_f4;
  logic            cancel_f4;
  logic            special_f4;
  logic [W-1:0]    y_special_f4;
  logic [4:0]      flags_special_f4;
  logic [2:0]      rm_f4;
  logic            f4_valid;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      norm_f4r         <= '0;
      norm_sticky_f4r  <= 1'b0;
      e_res_f4r        <= '0;
      rsign_f4         <= 1'b0;
      cancel_f4        <= 1'b0;
      special_f4       <= 1'b0;
      y_special_f4     <= '0;
      flags_special_f4 <= 5'd0;
      rm_f4            <= 3'd0;
      f4_valid         <= 1'b0;
    end else begin
      norm_f4r         <= norm_f4;
      norm_sticky_f4r  <= norm_sticky_f4;
      e_res_f4r        <= e_res_f4;
      rsign_f4         <= rsign_f3r;
      cancel_f4        <= cancel_f3r;
      special_f4       <= special_f3;
      y_special_f4     <= y_special_f3;
      flags_special_f4 <= flags_special_f3;
      rm_f4            <= rm_f3;
      f4_valid         <= f3_valid;
    end
  end

  // ============================================================ stage F5
  logic [S_W-1:0] sig;
  logic           g, r, s_bit, lsb, inexact, round_up, carry;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [S_W-1:0] sig_rnd;
  /* verilator lint_on UNUSEDSIGNAL */
  logic signed [W_EXP+3:0] e_rnd;
  logic [W-1:0]   y_normal;
  logic [4:0]     flags_normal;
  logic [2:0]     rm_f5;
  assign rm_f5 = rm_f4;
  always_comb begin
    logic [W_EXP-1:0] exp_fld;
    sig     = norm_f4r[TARGET -: S_W];
    g       = norm_f4r[2];
    r       = norm_f4r[1];
    s_bit   = norm_f4r[0] | norm_sticky_f4r;
    lsb     = sig[0];
    inexact = g | r | s_bit;
    case (rm_f5)
      fp_pkg::RM_RNE: round_up = g & (r | s_bit) | (g & ~r & ~s_bit & lsb);
      fp_pkg::RM_RNA: round_up = g;
      fp_pkg::RM_RZ:  round_up = 1'b0;
      fp_pkg::RM_RP:  round_up = ~rsign_f4 & inexact;
      fp_pkg::RM_RM:  round_up = rsign_f4 & inexact;
      default:        round_up = 1'b0;
    endcase
    carry = round_up && (sig == {S_W{1'b1}});
    if (carry) begin
      sig_rnd = {1'b1, {W_MANT{1'b0}}};
      e_rnd   = e_res_f4r + 1;
    end else begin
      sig_rnd = sig + { {S_W-1{1'b0}}, round_up };
      e_rnd   = e_res_f4r;
    end
    exp_fld = e_rnd[W_EXP-1:0] + BIAS[W_EXP-1:0];
    if ($signed(e_rnd) > EMAX_S) begin
      case (rm_f5)
        fp_pkg::RM_RNE,
        fp_pkg::RM_RNA: y_normal = {rsign_f4, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        fp_pkg::RM_RZ:  y_normal = {rsign_f4, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
        fp_pkg::RM_RP:  y_normal = rsign_f4 ? {1'b1, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}}
                                            : {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        fp_pkg::RM_RM:  y_normal = rsign_f4 ? {1'b1, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}}
                                            : {1'b0, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
        default:        y_normal = {rsign_f4, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      endcase
      flags_normal = (1 << fp_pkg::FLAG_OVERFLOW) | (1 << fp_pkg::FLAG_INEXACT);
    end else begin
      y_normal = {rsign_f4, exp_fld, sig_rnd[MANT_W-1:0]};
      flags_normal = inexact ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
    end
  end

  logic [W-1:0] y_sub;
  logic [4:0]   flags_sub;
  generate
    if (W_MANT > 0) begin : g_subnormal
      always_comb begin
        int signed          shift;
        logic [FW-1:0]      shifted;
        logic [S_W-1:0]     sig_s;
        logic               gs, rs, ss, inexact_s, up_s;
        logic [S_W-1:0]     sig_s2;
        shift = int'(EMIN - int'(e_res_f4r));
        if (shift > 0) shifted = norm_f4r >> shift;
        else           shifted = '0;
        sig_s  = shifted[TARGET -: S_W];
        gs     = shifted[2];
        rs     = shifted[1];
        ss     = shifted[0] | norm_sticky_f4r
               | |(norm_f4r & (((FW)'(1) << (shift > 0 ? shift : 0)) - 1));
        inexact_s = gs | rs | ss;
        case (rm_f5)
          fp_pkg::RM_RNE: up_s = gs & (rs | ss) | (gs & ~rs & ~ss & sig_s[0]);
          fp_pkg::RM_RNA: up_s = gs;
          fp_pkg::RM_RZ:  up_s = 1'b0;
          fp_pkg::RM_RP:  up_s = ~rsign_f4 & inexact_s;
          fp_pkg::RM_RM:  up_s = rsign_f4 & inexact_s;
          default:        up_s = 1'b0;
        endcase
        sig_s2 = sig_s + { {S_W-1{1'b0}}, up_s };
        if (sig_s2 == {1'b1, {W_MANT{1'b0}}}) begin
          if (EMIN > EMAX &&
              ((gs && rs) || (rm_f5 == fp_pkg::RM_RP && ~rsign_f4 && gs)
                          || (rm_f5 == fp_pkg::RM_RM && rsign_f4 && gs))) begin
            case (rm_f5)
              fp_pkg::RM_RNE,
              fp_pkg::RM_RNA: y_sub = {rsign_f4, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
              fp_pkg::RM_RZ:  y_sub = {rsign_f4, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
              fp_pkg::RM_RP:  y_sub = rsign_f4 ? {1'b1, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}}
                                               : {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
              fp_pkg::RM_RM:  y_sub = rsign_f4 ? {1'b1, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}}
                                               : {1'b0, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
              default:        y_sub = {rsign_f4, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
            endcase
            flags_sub = (1 << fp_pkg::FLAG_OVERFLOW) | (1 << fp_pkg::FLAG_INEXACT);
          end else begin
            y_sub = {rsign_f4, {W_EXP-1{1'b0}}, 1'b1, {W_MANT{1'b0}}};
            flags_sub = inexact_s ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
          end
        end else if (sig_s2 == '0) begin
          y_sub = {rsign_f4, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
          flags_sub = inexact_s ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
        end else begin
          y_sub = {rsign_f4, {W_EXP{1'b0}}, sig_s2[MANT_W-1:0]};
          flags_sub = 5'd0;
          if (inexact_s) begin
            flags_sub[fp_pkg::FLAG_UNDERFLOW] = 1'b1;
            flags_sub[fp_pkg::FLAG_INEXACT]   = 1'b1;
          end
        end
      end
    end else begin : g_no_subnormal
      assign y_sub     = {rsign_f4, {W_EXP{1'b0}}};
      assign flags_sub = 5'd0;
    end
  endgenerate

  logic [W-1:0] y_cancel;
  assign y_cancel = {(rm_f5 == fp_pkg::RM_RM), {W_EXP{1'b0}}, {W_MANT{1'b0}}};

  // The round/encode stage is split into two: F5a evaluates the normal and
  // subnormal paths plus the special/cancel candidates, F5b only muxes the
  // already-registered candidates (short final path).
  logic [W-1:0] y_normal_r5, y_sub_r5, y_special_r5, y_cancel_r5;
  logic [4:0]   flags_normal_r5, flags_sub_r5, flags_special_r5;
  logic         special_r5, cancel_r5;
  logic signed [W_EXP+3:0] e_res_r5;
  logic         v5;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      y_normal_r5      <= '0;
      y_sub_r5         <= '0;
      y_special_r5     <= '0;
      y_cancel_r5      <= '0;
      flags_normal_r5  <= 5'd0;
      flags_sub_r5     <= 5'd0;
      flags_special_r5 <= 5'd0;
      special_r5       <= 1'b0;
      cancel_r5        <= 1'b0;
      e_res_r5         <= '0;
      v5               <= 1'b0;
    end else begin
      y_normal_r5      <= y_normal;
      y_sub_r5         <= y_sub;
      y_special_r5     <= y_special_f4;
      y_cancel_r5      <= y_cancel;
      flags_normal_r5  <= flags_normal;
      flags_sub_r5     <= flags_sub;
      flags_special_r5 <= flags_special_f4;
      special_r5       <= special_f4;
      cancel_r5        <= cancel_f4;
      e_res_r5         <= e_res_f4r;
      v5               <= f4_valid;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      y         <= '0;
      flags     <= 5'd0;
      out_valid <= 1'b0;
    end else begin
      if (special_r5) begin
        y     <= y_special_r5;
        flags <= flags_special_r5;
      end else if (cancel_r5) begin
        y     <= y_cancel_r5;
        flags <= 5'd0;
      end else if ($signed(e_res_r5) >= EMIN_S) begin
        y     <= y_normal_r5;
        flags <= flags_normal_r5;
      end else begin
        y     <= y_sub_r5;
        flags <= flags_sub_r5;
      end
      out_valid <= v5;
    end
  end

endmodule
