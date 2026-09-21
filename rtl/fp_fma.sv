// IEEE 754-2019 fused multiply-add (5.4.1): (a x b) + c with a single
// rounding.
//
// Combinational, parameterized by the format: W_EXP exponent bits and W_MANT
// fraction bits (3.3, 3.7 "extendable precision"). Implements:
//   - all five rounding-direction attributes (4.3),
//   - full subnormal support (3.3),
//   - the five exception flags (7.2-7.6): invalid, div-by-zero, overflow,
//     underflow, inexact (bit positions in fp_pkg).
//
// Semantics (bit-exact reference: tests/reference/ops.py):
//   * NaN operands produce a quiet NaN (6.2.3): sign 0, quiet bit set, payload
//     of the first NaN operand. Signaling NaNs signal invalid (7.2a).
//   * inf x 0 (either order) signals invalid (7.2e) regardless of c.
//   * A product of infinities (inf x inf) is an infinity of XOR sign; adding
//     an infinity of the opposite sign (inf + -inf) signals invalid (7.2d).
//   * inf x finite + c = inf; finite product + inf = inf; product x 0 + c = c;
//     product + 0 = product. Zero signs follow 6.3; an exact zero sum of
//     opposite-signed zeros gives +0, or -0 under roundTowardNegative.
//   * Exact cancellation (a x b + c = 0) gives +0, or -0 under RM (6.3).
//   * Overflow (7.4): flagged iff the correctly rounded result with unbounded
//     exponent range exceeds the largest finite number; saturation per
//     attribute with inexact always signaled.
//   * Underflow (7.5, tininess after rounding): a non-zero subnormal rounded
//     result that is inexact.
//   * Inexact (7.6): signaled iff the rounded result differs from the exact
//     result.
//
// Datapath: unpack -> special cases -> exact 2p-bit product -> wide
// accumulator (3p+6 bits) holding the exact sum a x b + c anchored at the
// larger leading exponent -> normalize -> single GRS rounding -> overflow /
// underflow handling -> re-encode.
//
// Exact-sum math: the product is P = s_a*s_b (2*S_W bits) with value P*2^E
// (E = e_a+e_b-bitlen_a-bitlen_b+2) and c = s_c*2^(e_c-bitlen_c+1). Both are
// placed in an accumulator of width ACC_W = 3*S_W+6 with the larger leading
// exponent `top` mapped to the top bit PTOP (so both shifts are non-negative);
// operand bits that would fall below bit 0 are captured into a sticky term,
// which is exact because at most one operand can extend below the top operand
// and a single sub-bit-0 tail can never carry into bit 0. The sign-magnitude
// add (with the sticky subtracted on effective subtraction, as in fp_add), a
// normalize that brings the leading bit to TARGET, and the shared GRS rounding
// complete the single rounding of the exact sum.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
// Int arithmetic is deliberately mixed with sized logic; every expression is
// bounded such that the truncation/extensions are exact.

module fp_fma #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23
) (
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
  input  logic [1+W_EXP+W_MANT-1:0] c,
  input  fp_pkg::rounding_t         rm,
  output logic [1+W_EXP+W_MANT-1:0] y,
  output logic [4:0]                flags
);

  localparam int W       = 1 + W_EXP + W_MANT;   // total width
  localparam int BIAS    = (1 << (W_EXP-1)) - 1; // exponent bias (3.3)
  localparam int EMAX    = BIAS;                 // largest exponent
  localparam int EMIN    = 1 - BIAS;             // smallest normal exponent
  localparam int S_W     = W_MANT + 1;           // significand width incl. implicit bit
  localparam int MANT_W  = (W_MANT > 0) ? W_MANT : 1;  // internal mantissa width
  localparam int TARGET  = S_W + 2;              // MSB position of the normalized sum
  localparam int FW      = S_W + 3;              // normalized fixed-point width (sig + GRS)
  localparam int P_W     = 2 * S_W;              // exact product width
  localparam int ACC_W   = 3 * S_W + 6;          // accumulator width (exact-sum window)
  localparam int PTOP    = ACC_W - 1;            // accumulator top bit position
  localparam int EXP_ALL = (1 << W_EXP) - 1;     // all-ones exponent field
  localparam int EXP_MAXF = (1 << W_EXP) - 2;    // exponent field of the largest finite
  // Quiet bit of a NaN payload. Sized to MANT_W: `int` arithmetic would
  // overflow for W_MANT >= 32 (e.g. binary64); for W_MANT = 0 (E8M0) the
  // NaN path is unreachable and this constant is never used.
  localparam logic [MANT_W-1:0] QUIET = (MANT_W)'(1) << (MANT_W - 1);
  // Signed versions of the exponent bounds for width-clean comparisons.
  localparam logic signed [W_EXP+4:0] EMAX_S = (W_EXP+4)'(EMAX);
  localparam logic signed [W_EXP+4:0] EMIN_S = (W_EXP+4)'(EMIN);

  // ------------------------------------------------------------- unpack (3.3)
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

  // ------------------------------------------------------- special cases (6.x)
  logic [W-1:0] y_special;
  logic [4:0]   flags_special;
  logic         special_case;
  logic prod_sign;  // sign of the product = XOR of a and b signs (6.3)
  assign prod_sign = a_sign ^ b_sign;
  always_comb begin
    y_special    = '0;
    flags_special = '0;
    special_case = 1'b0;
    if (a_nan || b_nan || c_nan) begin
      // 6.2.3: quiet NaN, payload of the first NaN operand; 7.2a: sNaN -> invalid.
      y_special = {1'b0, EXP_ALL[W_EXP-1:0],
                   (a_nan ? a_mant : (b_nan ? b_mant : c_mant)) | QUIET};
      flags_special[fp_pkg::FLAG_INVALID] = a_snan || b_snan || c_snan;
      special_case = 1'b1;
    end else if ((a_inf && b_zero) || (a_zero && b_inf)) begin
      // 7.2e: infinity x zero signals invalid, regardless of c.
      y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
      flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
      special_case = 1'b1;
    end else if (a_inf || b_inf) begin
      // Product is an infinity of sign prod_sign.
      if (c_inf && (c_sign != prod_sign)) begin
        // 7.2d: magnitude subtraction of infinities (inf + -inf).
        y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
        flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
      end else begin
        y_special = {prod_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      end
      special_case = 1'b1;
    end else if (c_inf) begin
      // Finite product + infinity.
      y_special = {c_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      special_case = 1'b1;
    end else if (a_zero || b_zero) begin
      // Product is a zero of sign prod_sign. (a, b both non-zero, c finite:
      // the product+0 fast path is handled by the datapath below.)
      if (c_zero) begin
        // 6.3: exact zero sum of like-sign addends keeps that sign; of
        // opposite-sign addends it is +0, or -0 under roundTowardNegative.
        y_special = {(prod_sign == c_sign) ? prod_sign : (rm == fp_pkg::RM_RM),
                     {W_EXP{1'b0}}, {W_MANT{1'b0}}};
      end else begin
        y_special = c;  // 0 + c = c
      end
      special_case = 1'b1;
    end
    // (a, b non-zero, c an exact zero) is NOT special: the datapath runs with
    // c as a zero addend so the product gets its single rounding.
  end

  // ----------------------------------------------------- main datapath (a, b
  // finite non-zero, c finite — c may be an exact zero).
  logic [S_W-1:0] s_a, s_b, s_c;  // significands with implicit bit (3.3)
  assign s_a = a_sub ? {1'b0, a_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, a_mant};
  assign s_b = b_sub ? {1'b0, b_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, b_mant};
  assign s_c = c_sub ? {1'b0, c_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, c_mant};

  // Bit length of x (leading-one position + 1); 0 if x is zero. Last set bit
  // wins, i.e. the highest set bit (no break: yosys does not support `break`
  // in for loops).
  function automatic int unsigned bitlen(input logic [S_W-1:0] x);
    bitlen = 0;
    for (int i = 0; i < S_W; i++)
      if (x[i]) bitlen = i + 1;
  endfunction

  // Bit length of the exact product.
  function automatic int unsigned pbitlen(input logic [P_W-1:0] x);
    pbitlen = 0;
    for (int i = 0; i < P_W; i++)
      if (x[i]) pbitlen = i + 1;
  endfunction

  // Leading-bit exponents: value = s * 2^e. Same formula as fp_mul/fp_add.
  logic signed [W_EXP+2:0] e_a, e_b, e_c;
  always_comb begin
    // bitlen is computed unconditionally (yosys would otherwise leave a
    // don't-care anyseq on the branch that does not call it, corrupting the
    // formal model when multiple instances are elaborated).
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

  // Exact 2*S_W-bit product and its exponent (value = P * 2^E).
  logic [P_W-1:0] P;
  assign P = (P_W)'(s_a) * (P_W)'(s_b);
  logic signed [W_EXP+3:0] E;
  assign E = (W_EXP+4)'(e_a) + (W_EXP+4)'(e_b) - (W_EXP+4)'($signed(bitlen(s_a)))
           - (W_EXP+4)'($signed(bitlen(s_b))) + (W_EXP+4)'(2);

  // Place the product and c in the accumulator with the larger leading
  // exponent `top` at PTOP. When c is an exact zero the top is the product's
  // (a zero addend contributes nothing to place).
  logic signed [W_EXP+3:0] prod_top;
  assign prod_top = E + (W_EXP+4)'(pbitlen(P)) - 1;
  logic signed [W_EXP+3:0] top;
  assign top = (c_zero || prod_top >= (W_EXP+4)'(e_c)) ? prod_top : (W_EXP+4)'(e_c);

  logic [ACC_W-1:0] placed_p, placed_c;
  logic             sticky_p, sticky_c;
  always_comb begin
    int shift_p, shift_c;
    shift_p = int'(PTOP - top + E);
    // c's MSB (bit bitlen_c-1 of s_c) must land at PTOP - (top - e_c), so the
    // LSB shift is one bitlen_c-1 lower (the product's LSB-shift formula is
    // the same with its own bit length folded into top).
    shift_c = int'(PTOP - top + e_c - $signed(bitlen(s_c)) + 1);
    // Place the product; bits below accumulator bit 0 become sticky.
    if (shift_p >= 0) begin
      placed_p = (ACC_W)'(P) << shift_p;
      sticky_p = 1'b0;
    end else begin
      placed_p = (ACC_W)'(P >> (-shift_p));
      // OR of the low -shift_p bits of P (mask reduction, no accumulation
      // loop: yosys's proc turns `|=` self-reference into spurious anyseqs).
      sticky_p = |(P & (((P_W)'(1) << (-shift_p)) - 1));
    end
    // Place c (zero if c is an exact zero: its significand is not used).
    if (c_zero) begin
      placed_c = '0;
      sticky_c = 1'b0;
    end else if (shift_c >= 0) begin
      placed_c = (ACC_W)'(s_c) << shift_c;
      sticky_c = 1'b0;
    end else begin
      placed_c = (ACC_W)'(s_c >> (-shift_c));
      sticky_c = |(s_c & (((S_W)'(1) << (-shift_c)) - 1));
    end
  end

  // Sign-magnitude add of the exact sum (the sticky tail of an effective
  // subtraction is subtracted, as in fp_add).
  logic         same_sign;
  logic [ACC_W:0] acc;
  logic         rsign;    // sign of the magnitude result
  logic         cancel;   // exact cancellation to zero (6.3)
  logic         diff_sticky;
  assign same_sign = (prod_sign == c_sign);
  always_comb begin
    if (same_sign) begin
      acc = {1'b0, placed_p} + {1'b0, placed_c};
      rsign = prod_sign;
      cancel = 1'b0;
      diff_sticky = 1'b0;
    end else if (placed_p >= placed_c) begin
      acc = {1'b0, placed_p} - {1'b0, placed_c};
      rsign = prod_sign;
      cancel = (acc == '0);
      diff_sticky = sticky_p | sticky_c;
      if (diff_sticky) acc = acc - 1;
    end else begin
      acc = {1'b0, placed_c} - {1'b0, placed_p};
      rsign = c_sign;
      cancel = (acc == '0);
      diff_sticky = sticky_p | sticky_c;
      if (diff_sticky) acc = acc - 1;
    end
  end

  // Exact zero result from cancellation: +0, or -0 under roundTowardNegative (6.3).
  logic [W-1:0] y_cancel;
  assign y_cancel = {(rm == fp_pkg::RM_RM), {W_EXP{1'b0}}, {W_MANT{1'b0}}};

  // Normalize: bring the leading one to bit TARGET; exponent of the result.
  int                    p0;
  logic [FW-1:0]         norm;
  logic                  norm_sticky;
  logic signed [W_EXP+3:0] e_res;
  always_comb begin
    p0 = 0;
    // Last set bit wins, i.e. the highest set bit (no break: yosys does not
    // support `break` in for loops).
    for (int i = 0; i <= ACC_W; i++)
      if (acc[i]) p0 = i;
    // e_res does not depend on which normalize branch is taken: assign it
    // once, unconditionally (yosys's proc can otherwise turn branch-local
    // assignments into don't-care anyseqs).
    e_res = (W_EXP+4)'(top) + (W_EXP+4)'($signed(p0) - PTOP);
    if (p0 > TARGET) begin
      norm = acc >> (p0 - TARGET);
      // OR of the low (p0-TARGET) bits of acc (mask reduction; p0 - TARGET is
      // at least 1 here). norm_sticky is assigned in every branch (yosys's
      // proc turns a pre-assignment that is only ORed into inside a branch
      // into a don't-care anyseq).
      norm_sticky = sticky_p | sticky_c
                  | |(acc & (((ACC_W+1)'(1) << (p0 - TARGET)) - 1));
    end else if (p0 < TARGET) begin
      norm = acc << (TARGET - p0);
      norm_sticky = sticky_p | sticky_c;
    end else begin
      norm = acc;
      norm_sticky = sticky_p | sticky_c;
    end
  end

  // ------------------------------------------- rounding, normal path (4.3).
  logic [S_W-1:0] sig;
  logic           g, r, s_bit, lsb, inexact, round_up, carry;
  /* verilator lint_off UNUSEDSIGNAL */
  // sig_rnd[S_W-1] is the implicit (leading) bit, always 1 after
  // normalization; only the W_MANT explicit bits are emitted in y_normal.
  logic [S_W-1:0] sig_rnd;
  /* verilator lint_on UNUSEDSIGNAL */
  logic signed [W_EXP+3:0] e_rnd;
  logic [W-1:0]   y_normal;
  logic [4:0]     flags_normal;
  always_comb begin
    logic [W_EXP-1:0] exp_fld;
    sig     = norm[TARGET -: S_W];
    g       = norm[2];
    r       = norm[1];
    s_bit   = norm[0] | norm_sticky;
    lsb     = sig[0];
    inexact = g | r | s_bit;
    case (rm)
      fp_pkg::RM_RNE: round_up = g & (r | s_bit) | (g & ~r & ~s_bit & lsb);
      fp_pkg::RM_RNA: round_up = g;
      fp_pkg::RM_RZ:  round_up = 1'b0;
      fp_pkg::RM_RP:  round_up = ~rsign & inexact;
      fp_pkg::RM_RM:  round_up = rsign & inexact;
      default:        round_up = 1'b0;
    endcase
    carry = round_up && (sig == {S_W{1'b1}});
    if (carry) begin
      sig_rnd = {1'b1, {W_MANT{1'b0}}};  // renormalized after the carry
      e_rnd   = e_res + 1;
    end else begin
      sig_rnd = sig + { {S_W-1{1'b0}}, round_up };
      e_rnd   = e_res;
    end
    exp_fld = e_rnd[W_EXP-1:0] + BIAS[W_EXP-1:0];
    if ($signed(e_rnd) > EMAX_S) begin
      // Overflow (7.4): default result by rounding attribute; inexact always.
      case (rm)
        fp_pkg::RM_RNE,
        fp_pkg::RM_RNA: y_normal = {rsign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        fp_pkg::RM_RZ:  y_normal = {rsign, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
        fp_pkg::RM_RP:  y_normal = rsign ? {1'b1, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}}
                                        : {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        fp_pkg::RM_RM:  y_normal = rsign ? {1'b1, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}}
                                        : {1'b0, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
        default:        y_normal = {rsign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      endcase
      flags_normal = (1 << fp_pkg::FLAG_OVERFLOW) | (1 << fp_pkg::FLAG_INEXACT);
    end else begin
      y_normal = {rsign, exp_fld, sig_rnd[MANT_W-1:0]};
      flags_normal = inexact ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
    end
  end

  // ----------------------------------------------------- rounding, subnormal
  // path: e_res < EMIN. Round on the subnormal grid (ulp = 2^(emin-W_MANT)).
  // For W_MANT = 0 (E8M0) the subnormal path is unreachable (no subnormal
  // encodings exist); the generate guard also avoids a Verilator 5.020 gate
  // optimization bug that faults on this block at W_MANT = 0.
  logic [W-1:0] y_sub;
  logic [4:0]   flags_sub;
  generate
    if (W_MANT > 0) begin : g_subnormal
      always_comb begin
        // This block is combinational and evaluates for every input, but its
        // outputs are only selected when e_res < EMIN. shift must be signed:
        // when the result is normal (e_res >= EMIN) it is negative, and an
        // unsigned wrap would make the sticky loop below iterate ~2^32 times.
        int signed          shift;
        logic [FW-1:0]      shifted;
        logic [S_W-1:0]     sig_s;
        logic               gs, rs, ss, inexact_s, up_s;
        logic [S_W-1:0]     sig_s2;
        shift = int'(EMIN - int'(e_res));
        if (shift > 0) shifted = norm >> shift;
        else           shifted = '0;
        sig_s  = shifted[TARGET -: S_W];
        gs     = shifted[2];
        rs     = shifted[1];
        ss     = shifted[0] | norm_sticky
               // OR of the low shift bits of norm (mask reduction; when shift
               // exceeds FW the mask is all ones, i.e. every bit sticky).
               | |(norm & (((FW)'(1) << (shift > 0 ? shift : 0)) - 1));
        inexact_s = gs | rs | ss;
        case (rm)
          fp_pkg::RM_RNE: up_s = gs & (rs | ss) | (gs & ~rs & ~ss & sig_s[0]);
          fp_pkg::RM_RNA: up_s = gs;
          fp_pkg::RM_RZ:  up_s = 1'b0;
          fp_pkg::RM_RP:  up_s = ~rsign & inexact_s;
          fp_pkg::RM_RM:  up_s = rsign & inexact_s;
          default:        up_s = 1'b0;
        endcase
        sig_s2 = sig_s + { {S_W-1{1'b0}}, up_s };
        if (sig_s2 == {1'b1, {W_MANT{1'b0}}}) begin
          // Rounded up to the smallest normal number. For a degenerate
          // exponent range (W_EXP = 1, EMIN > EMAX) the smallest normal
          // 2^emin already exceeds the largest finite number, so this is
          // overflow per 7.4 whenever the p-bit (unbounded-range) rounding
          // carries past 2^emin (same rule as the other datapaths).
          if (EMIN > EMAX &&
              ((gs && rs) || (rm == fp_pkg::RM_RP && ~rsign && gs)
                         || (rm == fp_pkg::RM_RM && rsign && gs))) begin
            case (rm)
              fp_pkg::RM_RNE,
              fp_pkg::RM_RNA: y_sub = {rsign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
              fp_pkg::RM_RZ:  y_sub = {rsign, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
              fp_pkg::RM_RP:  y_sub = rsign ? {1'b1, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}}
                                            : {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
              fp_pkg::RM_RM:  y_sub = rsign ? {1'b1, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}}
                                            : {1'b0, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
              default:        y_sub = {rsign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
            endcase
            flags_sub = (1 << fp_pkg::FLAG_OVERFLOW) | (1 << fp_pkg::FLAG_INEXACT);
          end else begin
            y_sub = {rsign, {W_EXP-1{1'b0}}, 1'b1, {W_MANT{1'b0}}};
            flags_sub = inexact_s ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
          end
        end else if (sig_s2 == '0) begin
          // Rounded to zero; keeps the sign of the exact result.
          y_sub = {rsign, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
          flags_sub = inexact_s ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
        end else begin
          y_sub = {rsign, {W_EXP{1'b0}}, sig_s2[MANT_W-1:0]};
          flags_sub = 5'd0;
          // 7.5 (tininess after rounding): tiny non-zero rounded result, inexact.
          if (inexact_s) begin
            flags_sub[fp_pkg::FLAG_UNDERFLOW] = 1'b1;
            flags_sub[fp_pkg::FLAG_INEXACT]   = 1'b1;
          end
        end
      end
    end else begin : g_no_subnormal
      // Unreachable: no subnormal encodings exist for W_MANT = 0.
      assign y_sub     = {rsign, {W_EXP{1'b0}}};
      assign flags_sub = 5'd0;
    end
  endgenerate

  // --------------------------------------------------------------- result
  always_comb begin
    if (special_case) begin
      y     = y_special;
      flags = flags_special;
    end else if (cancel) begin
      y     = y_cancel;
      flags = 5'd0;
    end else if ($signed(e_res) >= EMIN_S) begin
      y     = y_normal;
      flags = flags_normal;
    end else begin
      y     = y_sub;
      flags = flags_sub;
    end
  end

endmodule
