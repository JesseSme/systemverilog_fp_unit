// Pipelined IEEE 754-2019 addition / subtraction (3 stages).
//
// Semantics are bit-identical to fp_add.sv (same special cases, alignment,
// GRS rounding, subnormal path, overflow/underflow rules); the datapath is
// split into three registered stages:
//
//   S1  unpack, classification, special cases, significands, exponents and
//       the per-operand alignment shift amounts (signed: positive = left)
//   S2  align (one bidirectional shift per operand) + sticky capture, then
//       sign-magnitude add / subtract (the alignment sticky is folded into
//       the subtractor carry-in)
//   S3  normalize (leading-one search + shift), subnormal placement (single
//       shift of the pre-normalization sum), GRS rounding (normal +
//       subnormal), overflow/underflow, encode
//
// Fixed latency: 3 cycles from `start` to `out_valid` for every input.
//
// The alignment in S2 is a single bidirectional shift per operand instead of
// the former place-left + align-right pair: the operand's significand MSB has
// to land at TARGET - (e_max - e), so the net shift of s is
// net = TARGET + 1 - bl + e - e_max (positive: left, no bits dropped;
// negative: right, the dropped bits are the alignment sticky). Both shift
// amounts are computed in S1 and registered. The magnitude add/sub computes
// the two difference directions in parallel and selects by the borrow, so the
// stage carries one carry chain, not a compare chain followed by a subtract.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
// Int arithmetic is deliberately mixed with sized logic; every expression is
// bounded such that the truncation/extensions are exact.

module fp_add_pipe #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23
) (
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
  input  fp_pkg::rounding_t         rm,
  input  fp_pkg::op_t               op,
  input  logic                      clk,
  input  logic                      rst_n,
  input  logic                      start,
  output logic [1+W_EXP+W_MANT-1:0] y,
  output logic [4:0]                flags,
  output logic                      out_valid
);

  localparam int W       = 1 + W_EXP + W_MANT;   // total width
  localparam int BIAS    = (1 << (W_EXP-1)) - 1; // exponent bias (3.3)
  localparam int EMAX    = BIAS;                 // largest exponent
  localparam int EMIN    = 1 - BIAS;             // smallest normal exponent
  localparam int S_W     = W_MANT + 1;           // significand width incl. implicit bit
  localparam int MANT_W  = (W_MANT > 0) ? W_MANT : 1;  // internal mantissa width
  localparam int TARGET  = S_W + 2;              // MSB position of aligned significand
  localparam int FW      = S_W + 3;              // aligned fixed-point width
  localparam int SUM_W   = FW + 1;               // aligned sum width (carry bit)
  localparam int NORM_W  = TARGET + 1;           // normalized result width (bits 0..TARGET)
  localparam int EXP_ALL = (1 << W_EXP) - 1;     // all-ones exponent field
  localparam int EXP_MAXF = (1 << W_EXP) - 2;    // exponent field of the largest finite
  localparam logic [MANT_W-1:0] QUIET = (MANT_W)'(1) << (MANT_W - 1);
  localparam logic signed [W_EXP+4:0] EMAX_S = (W_EXP+4)'(EMAX);
  localparam logic signed [W_EXP+4:0] EMIN_S = (W_EXP+4)'(EMIN);
  localparam int NET_W = W_EXP + 5;              // signed alignment-shift width
  localparam int SHL_W = $clog2(TARGET + 1);     // left alignment-shift width
  localparam int SHR_W = $clog2(S_W + 1);        // right alignment-shift width
  localparam int SUB_W = $clog2(SUM_W + 1);      // subnormal placement-shift width

  // ============================================================ stage 1
  // unpack (3.3)
  logic              a_sign, b_sign, b_sign_eff;
  logic [W_EXP-1:0]  a_exp, b_exp;
  logic [MANT_W-1:0] a_mant, b_mant;
  assign a_sign = a[W-1];
  assign a_exp  = a[W-2 -: W_EXP];
  assign b_sign = b[W-1];
  assign b_exp  = b[W-2 -: W_EXP];
  always_comb begin
    a_mant = '0;
    b_mant = '0;
    if (W_MANT > 0) begin
      a_mant = a[W_MANT-1:0];
      b_mant = b[W_MANT-1:0];
    end
  end
  assign b_sign_eff = b_sign ^ (op == fp_pkg::OP_SUB);

  logic a_nan, a_snan, a_inf, a_zero, a_sub;
  logic b_nan, b_snan, b_inf, b_zero, b_sub;
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

  // special cases (6.x)
  logic [W-1:0] y_special;
  logic [4:0]   flags_special;
  logic         special_case;
  always_comb begin
    y_special    = '0;
    flags_special = '0;
    special_case = 1'b0;
    if (a_nan || b_nan) begin
      y_special = {1'b0, EXP_ALL[W_EXP-1:0], (a_nan ? a_mant : b_mant) | QUIET};
      flags_special[fp_pkg::FLAG_INVALID] = a_snan || b_snan;
      special_case = 1'b1;
    end else if (a_inf || b_inf) begin
      if (a_inf && b_inf) begin
        if (a_sign == b_sign_eff)
          y_special = {a_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        else begin
          y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
          flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
        end
      end else if (a_inf) begin
        y_special = {a_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      end else begin
        y_special = {b_sign_eff, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      end
      special_case = 1'b1;
    end else if (a_zero && b_zero) begin
      y_special = {(a_sign == b_sign_eff) ? a_sign : (rm == fp_pkg::RM_RM),
                   {W_EXP{1'b0}}, {W_MANT{1'b0}}};
      special_case = 1'b1;
    end else if (a_zero) begin
      y_special = {b_sign_eff, b_exp, b_mant};
      special_case = 1'b1;
    end else if (b_zero) begin
      y_special = a;
      special_case = 1'b1;
    end
  end

  logic [S_W-1:0] s_a, s_b;
  assign s_a = a_sub ? {1'b0, a_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, a_mant};
  assign s_b = b_sub ? {1'b0, b_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, b_mant};

  function automatic int unsigned bitlen(input logic [S_W-1:0] x);
    bitlen = 0;
    for (int i = 0; i < S_W; i++)
      if (x[i]) bitlen = i + 1;
  endfunction

  // Leading-bit exponents (value = s * 2^e) and the signed net alignment
  // shifts (positive: left shift; negative: right shift with sticky). The
  // subnormal bit length is taken from the mantissa bits directly, so the
  // leading-one scan runs in parallel with the classification instead of
  // behind the significand mux. The net shifts are converted here (in S1)
  // into clamped, direction-split shift amounts, so S2's shifter sees short
  // registered selects instead of a wide signed amount plus clamp logic.
  logic signed [W_EXP+2:0] e_a, e_b, e_max;
  logic signed [NET_W-1:0] net_a, net_b;
  logic [SHL_W-1:0] shl_a, shl_b;
  logic [SHR_W-1:0] shr_a, shr_b;
  logic             left_a, left_b;
  always_comb begin
    int bl_a, bl_b;
    bl_a = a_sub ? int'(bitlen({1'b0, a_mant})) : S_W;
    bl_b = b_sub ? int'(bitlen({1'b0, b_mant})) : S_W;
    e_a = (W_EXP+3)'(a_exp - BIAS);
    if (a_sub) e_a = (W_EXP+3)'((1 - BIAS) - W_MANT + $signed(bl_a) - 1);
    e_b = (W_EXP+3)'(b_exp - BIAS);
    if (b_sub) e_b = (W_EXP+3)'((1 - BIAS) - W_MANT + $signed(bl_b) - 1);
    e_max = (e_a >= e_b) ? e_a : e_b;
    net_a = (NET_W)'(TARGET + 1 - bl_a) + (NET_W)'(e_a) - (NET_W)'(e_max);
    net_b = (NET_W)'(TARGET + 1 - bl_b) + (NET_W)'(e_b) - (NET_W)'(e_max);
    left_a = (net_a >= 0);
    shl_a  = left_a ? (SHL_W)'(net_a) : '0;
    shr_a  = left_a ? '0 : ((-net_a > S_W) ? (SHR_W)'(S_W) : (SHR_W)'(-net_a));
    left_b = (net_b >= 0);
    shl_b  = left_b ? (SHL_W)'(net_b) : '0;
    shr_b  = left_b ? '0 : ((-net_b > S_W) ? (SHR_W)'(S_W) : (SHR_W)'(-net_b));
  end

  // stage 1 registers
  logic [W-1:0]   y_special_s1;
  logic [4:0]     flags_special_s1;
  logic           special_s1;
  logic           a_sign_s1, b_sign_eff_s1;
  logic [S_W-1:0] s_a_s1, s_b_s1;
  logic [SHL_W-1:0] shl_a_s1, shl_b_s1;
  logic [SHR_W-1:0] shr_a_s1, shr_b_s1;
  logic           left_a_s1, left_b_s1;
  logic signed [W_EXP+2:0] e_max_s1;
  logic [2:0]     rm_s1;
  logic           v1;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      y_special_s1    <= '0;
      flags_special_s1 <= 5'd0;
      special_s1      <= 1'b0;
      a_sign_s1       <= 1'b0;
      b_sign_eff_s1   <= 1'b0;
      s_a_s1          <= '0;
      s_b_s1          <= '0;
      shl_a_s1        <= '0;
      shl_b_s1        <= '0;
      shr_a_s1        <= '0;
      shr_b_s1        <= '0;
      left_a_s1       <= 1'b0;
      left_b_s1       <= 1'b0;
      e_max_s1        <= '0;
      rm_s1           <= 3'd0;
      v1              <= 1'b0;
    end else begin
      y_special_s1    <= y_special;
      flags_special_s1 <= flags_special;
      special_s1      <= special_case;
      a_sign_s1       <= a_sign;
      b_sign_eff_s1   <= b_sign_eff;
      s_a_s1          <= s_a;
      s_b_s1          <= s_b;
      shl_a_s1        <= shl_a;
      shl_b_s1        <= shl_b;
      shr_a_s1        <= shr_a;
      shr_b_s1        <= shr_b;
      left_a_s1       <= left_a;
      left_b_s1       <= left_b;
      e_max_s1        <= e_max;
      rm_s1           <= rm;
      v1              <= start;
    end
  end

  // ============================================================ stage 2
  // align (single bidirectional shift per operand) + sticky capture
  logic [FW-1:0] fp_a_s2, fp_b_s2;
  logic          sticky_s2;
  logic [SHR_W-1:0] sst_a_s2, sst_b_s2;
  always_comb begin
    // sticky shift amounts (S_W - shr, or 0 when the whole word is dropped)
    sst_a_s2 = (shr_a_s1 >= S_W) ? '0 : (SHR_W)'(S_W) - shr_a_s1;
    sst_b_s2 = (shr_b_s1 >= S_W) ? '0 : (SHR_W)'(S_W) - shr_b_s1;
    // operand a
    if (left_a_s1) begin
      fp_a_s2   = FW'($unsigned(s_a_s1)) << shl_a_s1;
      sticky_s2 = 1'b0;
    end else begin
      fp_a_s2   = FW'($unsigned(s_a_s1)) >> shr_a_s1;
      sticky_s2 = |(s_a_s1 << sst_a_s2);
    end
    // operand b
    if (left_b_s1) begin
      fp_b_s2 = FW'($unsigned(s_b_s1)) << shl_b_s1;
    end else begin
      fp_b_s2   = FW'($unsigned(s_b_s1)) >> shr_b_s1;
      sticky_s2 = sticky_s2 | |(s_b_s1 << sst_b_s2);
    end
  end

  // sign-magnitude add / subtract. The two difference directions are computed
  // in parallel and selected by the borrow (the sign bit of a-b), so the stage
  // holds one carry chain after the shifter. The alignment sticky is folded
  // into the subtractor carry-in (a - b - sticky), matching fp_add's
  // "decrement the magnitude when bits were dropped" rule.
  logic               same_sign_s2;
  logic [SUM_W-1:0]   sum_s2, diff_ab_s2, diff_ba_s2;
  logic               neg_ab_s2;
  assign same_sign_s2 = (a_sign_s1 == b_sign_eff_s1);
  always_comb begin
    sum_s2     = {1'b0, fp_a_s2} + {1'b0, fp_b_s2};
    diff_ab_s2 = {1'b0, fp_a_s2} - {1'b0, fp_b_s2} - {{SUM_W-1{1'b0}}, sticky_s2};
    diff_ba_s2 = {1'b0, fp_b_s2} - {1'b0, fp_a_s2} - {{SUM_W-1{1'b0}}, sticky_s2};
  end
  assign neg_ab_s2 = diff_ab_s2[SUM_W-1];

  logic [SUM_W-1:0] mag_s2;
  logic             rsign_s2, cancel_s2;
  always_comb begin
    if (same_sign_s2) begin
      mag_s2    = sum_s2;
      rsign_s2  = a_sign_s1;
      cancel_s2 = 1'b0;
    end else if (neg_ab_s2) begin
      mag_s2    = diff_ba_s2;
      rsign_s2  = b_sign_eff_s1;
      cancel_s2 = (fp_a_s2 == fp_b_s2);
    end else begin
      mag_s2    = diff_ab_s2;
      rsign_s2  = a_sign_s1;
      cancel_s2 = (fp_a_s2 == fp_b_s2);
    end
  end

  // subnormal placement shift amounts (registered; the S3 subnormal path then
  // starts from short registered selects instead of computing e_max - EMIN)
  logic             sub_left_s2_d;
  logic [SUB_W-1:0] sub_shl_s2_d;
  logic [SUB_W-1:0] sub_shr_s2_d;
  logic [SUB_W-1:0] sub_sst_s2_d;
  always_comb begin
    int signed sshift;
    sshift = int'(e_max_s1) - EMIN;
    sub_left_s2_d = (sshift >= 0);
    sub_shl_s2_d  = (sshift > SUM_W) ? (SUB_W)'(SUM_W) : (SUB_W)'(sshift);
    sub_shr_s2_d  = (sshift >= 0) ? '0 : ((-sshift > SUM_W) ? (SUB_W)'(SUM_W) : (SUB_W)'(-sshift));
    sub_sst_s2_d  = (sub_shr_s2_d >= SUM_W) ? '0 : (SUB_W)'(SUM_W) - sub_shr_s2_d;
  end
  logic             sub_left_s2;
  logic [SUB_W-1:0] sub_shl_s2;
  logic [SUB_W-1:0] sub_shr_s2;
  logic [SUB_W-1:0] sub_sst_s2;

  // stage 2 registers
  logic [SUM_W-1:0] mag_s2r;
  logic             rsign_s2r, sticky_s2r;
  logic signed [W_EXP+2:0] e_max_s2;
  logic [2:0]       rm_s2;
  logic             v2;
  // pre-selected special/cancel bypass (keeps the S3 output mux two-way)
  logic [W-1:0]     y_bypass_s2;
  logic [4:0]       flags_bypass_s2;
  logic             bypass_s2;
  logic [W-1:0]     y_cancel_s2;
  assign y_cancel_s2 = {(rm_s1 == fp_pkg::RM_RM), {W_EXP{1'b0}}, {W_MANT{1'b0}}};

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mag_s2r          <= '0;
      rsign_s2r        <= 1'b0;
      sticky_s2r       <= 1'b0;
      e_max_s2         <= '0;
      rm_s2            <= 3'd0;
      v2               <= 1'b0;
      y_bypass_s2      <= '0;
      flags_bypass_s2  <= 5'd0;
      bypass_s2        <= 1'b0;
      sub_left_s2      <= 1'b0;
      sub_shl_s2       <= '0;
      sub_shr_s2       <= '0;
      sub_sst_s2       <= '0;
    end else begin
      mag_s2r          <= mag_s2;
      rsign_s2r        <= rsign_s2;
      sticky_s2r       <= sticky_s2;
      e_max_s2         <= e_max_s1;
      rm_s2            <= rm_s1;
      v2               <= v1;
      bypass_s2        <= special_s1 | cancel_s2;
      y_bypass_s2      <= special_s1 ? y_special_s1 : y_cancel_s2;
      flags_bypass_s2  <= special_s1 ? flags_special_s1 : 5'd0;
      sub_left_s2      <= sub_left_s2_d;
      sub_shl_s2       <= sub_shl_s2_d;
      sub_shr_s2       <= sub_shr_s2_d;
      sub_sst_s2       <= sub_sst_s2_d;
    end
  end

  // ============================================================ stage 3
  // normalize: leading-one position of the magnitude
  function automatic int unsigned lpos(input logic [SUM_W-1:0] x);
    lpos = 0;
    for (int i = 0; i < SUM_W; i++)
      if (x[i]) lpos = i;
  endfunction

  int                   p0_s3;
  logic [NORM_W-1:0]    norm_s3;
  logic                 norm_sticky_s3;
  logic signed [W_EXP+3:0] e_res_s3;
  always_comb begin
    p0_s3 = int'(lpos(mag_s2r));
    norm_sticky_s3 = sticky_s2r;  // sticky bits lost during operand alignment
    if (p0_s3 > TARGET) begin
      norm_s3 = (NORM_W)'(mag_s2r >> 1);
      norm_sticky_s3 = norm_sticky_s3 | mag_s2r[0];
      e_res_s3 = (W_EXP+4)'(e_max_s2) + 1;
    end else if (p0_s3 < TARGET) begin
      norm_s3 = (NORM_W)'(mag_s2r) << (TARGET - p0_s3);
      e_res_s3 = (W_EXP+4)'(e_max_s2) + (W_EXP+4)'($signed(p0_s3) - TARGET);
    end else begin
      norm_s3 = (NORM_W)'(mag_s2r);
      e_res_s3 = (W_EXP+4)'(e_max_s2);
    end
  end

  // subnormal placement: the total shift applied to the pre-normalization sum
  // by the subnormal path is (TARGET - p0) + (EMIN - e_res) = e_max - EMIN,
  // independent of the leading-one position, so the subnormal candidate is
  // shifted directly from mag_s2r. sshift >= 0 shifts left (nothing dropped);
  // sshift < 0 shifts right with the dropped bits accumulated into the sticky.
  logic [NORM_W-1:0] sub_s3;
  logic              sub_sticky_s3;
  always_comb begin
    if (sub_left_s2) begin
      sub_s3        = (NORM_W)'((mag_s2r) << sub_shl_s2);
      sub_sticky_s3 = sticky_s2r;
    end else begin
      sub_s3        = (NORM_W)'((mag_s2r) >> sub_shr_s2);
      sub_sticky_s3 = sticky_s2r | |(mag_s2r << sub_sst_s2);
    end
  end

  // rounding (normal + subnormal) and result encoding. The rounding increment
  // and the exponent/overflow candidates are computed in parallel with the GRS
  // decision (carry-select), so neither the GRS logic nor the exponent adder
  // sits in the increment's serial path.
  logic [S_W-1:0] sig;
  logic           g, r, s_bit, lsb, inexact, round_up;
  logic [S_W-1:0] sig_p1;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [S_W-1:0] sig_rnd;
  /* verilator lint_on UNUSEDSIGNAL */
  logic           carry;
  logic [W-1:0]   y_normal;
  logic [4:0]     flags_normal;
  always_comb begin
    logic [W_EXP-1:0] exp_fld0, exp_fld1;
    logic             ovf0, ovf1, ovf;
    logic [W-1:0]     y_ovf;
    sig     = norm_s3[TARGET -: S_W];
    g       = norm_s3[2];
    r       = norm_s3[1];
    s_bit   = norm_s3[0] | norm_sticky_s3;
    lsb     = sig[0];
    inexact = g | r | s_bit;
    case (rm_s2)
      fp_pkg::RM_RNE: round_up = g & (r | s_bit) | (g & ~r & ~s_bit & lsb);
      fp_pkg::RM_RNA: round_up = g;
      fp_pkg::RM_RZ:  round_up = 1'b0;
      fp_pkg::RM_RP:  round_up = ~rsign_s2r & inexact;
      fp_pkg::RM_RM:  round_up = rsign_s2r & inexact;
      default:        round_up = 1'b0;
    endcase
    sig_p1 = sig + { {S_W-1{1'b0}}, 1'b1 };
    sig_rnd = round_up ? sig_p1 : sig;
    carry = round_up && (sig_p1 == '0);
    // exponent/overflow candidates for both carry values (parallel logic)
    exp_fld0 = e_res_s3[W_EXP-1:0] + BIAS[W_EXP-1:0];
    exp_fld1 = e_res_s3[W_EXP-1:0] + BIAS[W_EXP-1:0] + (W_EXP)'(1);
    ovf0 = $signed(e_res_s3) > EMAX_S;
    ovf1 = $signed(e_res_s3) + 1 > EMAX_S;
    ovf  = carry ? ovf1 : ovf0;
    case (rm_s2)
      fp_pkg::RM_RNE,
      fp_pkg::RM_RNA: y_ovf = {rsign_s2r, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      fp_pkg::RM_RZ:  y_ovf = {rsign_s2r, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
      fp_pkg::RM_RP:  y_ovf = rsign_s2r ? {1'b1, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}}
                                        : {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      fp_pkg::RM_RM:  y_ovf = rsign_s2r ? {1'b1, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}}
                                        : {1'b0, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
      default:        y_ovf = {rsign_s2r, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
    endcase
    y_normal = ovf ? y_ovf
             : {rsign_s2r, (carry ? exp_fld1 : exp_fld0), sig_rnd[MANT_W-1:0]};
    flags_normal = ovf ? ((1 << fp_pkg::FLAG_OVERFLOW) | (1 << fp_pkg::FLAG_INEXACT))
                       : (inexact ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0);
  end

  logic [W-1:0] y_sub;
  logic [4:0]   flags_sub;
  generate
    if (W_MANT > 0) begin : g_subnormal
      always_comb begin
        logic [S_W-1:0]     sig_s;
        logic               gs, rs, ss, inexact_s, up_s;
        logic [S_W-1:0]     sig_s_p1, sig_s2;
        sig_s  = sub_s3[TARGET -: S_W];
        gs     = sub_s3[2];
        rs     = sub_s3[1];
        ss     = sub_s3[0] | sub_sticky_s3;
        inexact_s = gs | rs | ss;
        case (rm_s2)
          fp_pkg::RM_RNE: up_s = gs & (rs | ss) | (gs & ~rs & ~ss & sig_s[0]);
          fp_pkg::RM_RNA: up_s = gs;
          fp_pkg::RM_RZ:  up_s = 1'b0;
          fp_pkg::RM_RP:  up_s = ~rsign_s2r & inexact_s;
          fp_pkg::RM_RM:  up_s = rsign_s2r & inexact_s;
          default:        up_s = 1'b0;
        endcase
        sig_s_p1 = sig_s + { {S_W-1{1'b0}}, 1'b1 };
        sig_s2   = up_s ? sig_s_p1 : sig_s;
        if (sig_s2 == {1'b1, {W_MANT{1'b0}}}) begin
          if (EMIN > EMAX &&
              ((gs && rs) || (rm_s2 == fp_pkg::RM_RP && ~rsign_s2r && gs)
                         || (rm_s2 == fp_pkg::RM_RM && rsign_s2r && gs))) begin
            case (rm_s2)
              fp_pkg::RM_RNE,
              fp_pkg::RM_RNA: y_sub = {rsign_s2r, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
              fp_pkg::RM_RZ:  y_sub = {rsign_s2r, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
              fp_pkg::RM_RP:  y_sub = rsign_s2r ? {1'b1, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}}
                                                : {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
              fp_pkg::RM_RM:  y_sub = rsign_s2r ? {1'b1, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}}
                                                : {1'b0, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
              default:        y_sub = {rsign_s2r, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
            endcase
            flags_sub = (1 << fp_pkg::FLAG_OVERFLOW) | (1 << fp_pkg::FLAG_INEXACT);
          end else begin
            y_sub = {rsign_s2r, {W_EXP-1{1'b0}}, 1'b1, {W_MANT{1'b0}}};
            flags_sub = inexact_s ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
          end
        end else if (sig_s2 == '0) begin
          y_sub = {rsign_s2r, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
          flags_sub = inexact_s ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
        end else begin
          y_sub = {rsign_s2r, {W_EXP{1'b0}}, sig_s2[MANT_W-1:0]};
          flags_sub = 5'd0;
          if (inexact_s) begin
            flags_sub[fp_pkg::FLAG_UNDERFLOW] = 1'b1;
            flags_sub[fp_pkg::FLAG_INEXACT]   = 1'b1;
          end
        end
      end
    end else begin : g_no_subnormal
      assign y_sub     = {rsign_s2r, {W_EXP{1'b0}}};
      assign flags_sub = 5'd0;
    end
  endgenerate

  logic [W-1:0] y_comb;
  logic [4:0]   flags_comb;
  always_comb begin
    if (bypass_s2) begin
      y_comb     = y_bypass_s2;
      flags_comb = flags_bypass_s2;
    end else if ($signed(e_res_s3) >= EMIN_S) begin
      y_comb     = y_normal;
      flags_comb = flags_normal;
    end else begin
      y_comb     = y_sub;
      flags_comb = flags_sub;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      y         <= '0;
      flags     <= 5'd0;
      out_valid <= 1'b0;
    end else begin
      y         <= y_comb;
      flags     <= flags_comb;
      out_valid <= v2;
    end
  end

endmodule
