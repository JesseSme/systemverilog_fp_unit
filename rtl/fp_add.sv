// IEEE 754-2019 addition / subtraction (5.4.1).
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
//     of the first NaN operand (a if a is NaN, else b). Signaling NaNs signal
//     invalid (7.2a).
//   * Infinity: inf + finite = inf; like-sign infinities sum to infinity;
//     magnitude subtraction of infinities (e.g. +inf + -inf) signals invalid
//     and returns a quiet NaN (7.2d).
//   * Zero: x + 0 = x exactly. An exact zero sum of like-sign addends keeps
//     that sign; of opposite-sign addends it is +0, or -0 under
//     roundTowardNegative (6.3).
//   * Overflow (7.4): signaled iff the correctly rounded result with unbounded
//     exponent range exceeds the largest finite number. RNE/RNA saturate to
//     infinity, RZ to the largest finite number, RP/RM to infinity or the
//     largest finite number by sign. Inexact is always signaled too.
//   * Underflow (7.5, tininess after rounding): signaled iff the rounded
//     (unbounded-range) result is a non-zero value strictly between +-2^emin
//     (i.e. subnormal) and the rounding is inexact.
//   * Inexact (7.6): signaled iff the rounded result differs from the exact
//     result.
//
// Datapath: unpack -> special cases -> align to the larger exponent with
// guard/round/sticky capture -> sign-magnitude add -> normalize -> round per
// attribute -> overflow/underflow handling -> re-encode.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
// Int arithmetic is deliberately mixed with sized logic; every expression is
// bounded such that the truncation/extensions are exact.

module fp_add #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23
) (
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
  input  fp_pkg::rounding_t         rm,
  input  fp_pkg::op_t               op,
  output logic [1+W_EXP+W_MANT-1:0] y,
  output logic [4:0]                flags
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
  localparam int NORM_W  = SUM_W + TARGET;       // normalized result width
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
  logic              a_sign, b_sign, b_sign_eff;
  logic [W_EXP-1:0]  a_exp, b_exp;
  logic [MANT_W-1:0] a_mant, b_mant;
  assign a_sign = a[W-1];
  assign a_exp  = a[W-2 -: W_EXP];
  assign b_sign = b[W-1];
  assign b_exp  = b[W-2 -: W_EXP];
  // The mantissa field is empty for W_MANT = 0 (E8M0); the width guard keeps
  // the extraction from producing a negative index. `if (W_MANT > 0)` is a
  // constant condition, so the dead branch is eliminated at elaboration.
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

  // ------------------------------------------------------- special cases (6.x)
  logic [W-1:0] y_special;
  logic [4:0]   flags_special;
  logic         special_case;
  always_comb begin
    y_special    = '0;
    flags_special = '0;
    special_case = 1'b0;
    if (a_nan || b_nan) begin
      // 6.2.3: quiet NaN, payload of the first NaN operand; 7.2a: sNaN -> invalid.
      // Unreachable for W_MANT = 0 (E8M0 has no NaN encodings).
      y_special = {1'b0, EXP_ALL[W_EXP-1:0], (a_nan ? a_mant : b_mant) | QUIET};
      flags_special[fp_pkg::FLAG_INVALID] = a_snan || b_snan;
      special_case = 1'b1;
    end else if (a_inf || b_inf) begin
      if (a_inf && b_inf) begin
        if (a_sign == b_sign_eff)
          y_special = {a_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        else begin
          // 7.2d: magnitude subtraction of infinities.
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
      // 6.3: an exact zero sum of like-sign addends keeps that sign; of
      // opposite-sign addends it is +0, or -0 under roundTowardNegative.
      y_special = {(a_sign == b_sign_eff) ? a_sign : (rm == fp_pkg::RM_RM),
                   {W_EXP{1'b0}}, {W_MANT{1'b0}}};
      special_case = 1'b1;
    end else if (a_zero) begin
      y_special = {b_sign_eff, b_exp, b_mant};  // 0 + b = b, 0 - b = -b
      special_case = 1'b1;
    end else if (b_zero) begin
      y_special = a;                            // a + 0 = a, a - 0 = a
      special_case = 1'b1;
    end
  end

  // ----------------------------------------------------- main datapath (both
  // operands finite, at least one non-zero).
  logic [S_W-1:0] s_a, s_b;  // significands with implicit bit (3.3)
  // Implicit bit at position W_MANT. The OR form (instead of a
  // concatenation with a zero-width fill) keeps the width exactly S_W even
  // for W_MANT = 0 (E8M0), where the significand is just the implicit bit.
  assign s_a = a_sub ? {1'b0, a_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, a_mant};
  assign s_b = b_sub ? {1'b0, b_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, b_mant};

  // Bit length of x (leading-one position + 1); 0 if x is zero. Last set bit
  // wins, i.e. the highest set bit (no break: yosys does not support `break`
  // in for loops).
  function automatic int unsigned bitlen(input logic [S_W-1:0] x);
    bitlen = 0;
    for (int i = 0; i < S_W; i++)
      if (x[i]) bitlen = i + 1;
  endfunction

  // Leading-one position of x; 0 if x is zero.
  function automatic int unsigned lpos(input logic [SUM_W-1:0] x);
    lpos = 0;
    for (int i = 0; i < SUM_W; i++)
      if (x[i]) lpos = i;
  endfunction

  // Leading-bit exponents: value = s * 2^e.
  // Note: a_exp/b_exp are unsigned fields; subtracting the (signed) bias
  // promotes them to signed 32-bit arithmetic, giving the correct unbiased
  // exponent even when the field MSB is set. $signed() must NOT be applied:
  // it would misinterpret fields >= 2^(W_EXP-1) as negative. Casts use
  // (W_EXP+3) bits to match `logic signed [W_EXP+2:0]`.
  logic signed [W_EXP+2:0] e_a, e_b;
  always_comb begin
    // bitlen is computed unconditionally (yosys would otherwise leave a
    // don't-care anyseq on the branch that does not call it, corrupting the
    // formal model when multiple instances are elaborated).
    int bl_a, bl_b;
    bl_a = int'(bitlen(s_a));
    bl_b = int'(bitlen(s_b));
    e_a = (W_EXP+3)'(a_exp - BIAS);
    if (a_sub) e_a = (W_EXP+3)'((1 - BIAS) - W_MANT + $signed(bl_a) - 1);
    e_b = (W_EXP+3)'(b_exp - BIAS);
    if (b_sub) e_b = (W_EXP+3)'((1 - BIAS) - W_MANT + $signed(bl_b) - 1);
  end
  logic signed [W_EXP+2:0] e_max;
  assign e_max = (e_a >= e_b) ? e_a : e_b;

  // Align the smaller-magnitude significand to the larger exponent: place its
  // MSB at bit TARGET, then shift right; bits below bit 3 are captured into
  // the sticky term.
  logic [FW-1:0] fp_a, fp_b;
  logic          shift_sticky_a, shift_sticky_b;
  logic          align_sticky;
  assign align_sticky = shift_sticky_a | shift_sticky_b;
  always_comb begin
    int rshift;
    logic [FW-1:0] placed;
    rshift = int'(e_max - e_a);
    // Widen before shifting: with S_W = 1 (W_MANT = 0) a narrow shift
    // would drop the only significand bit.
    placed = FW'($unsigned(s_a)) << (TARGET - bitlen(s_a) + 1);
    if (rshift >= FW) begin
      fp_a = '0;
      shift_sticky_a = |placed;
    end else begin
      fp_a = FW'(placed >> rshift);
      // OR of the low rshift bits of placed, as a mask reduction (no
      // accumulation loop: yosys's proc turns a self-referencing `|=` in a
      // loop into a spurious don't-care anyseq that corrupts the formal model).
      shift_sticky_a = |(placed & ((FW)'(1) << rshift) - 1);
    end
    rshift = int'(e_max - e_b);
    placed = FW'($unsigned(s_b)) << (TARGET - bitlen(s_b) + 1);
    if (rshift >= FW) begin
      fp_b = '0;
      shift_sticky_b = |placed;
    end else begin
      fp_b = placed >> rshift;
      shift_sticky_b = |(placed & ((FW)'(1) << rshift) - 1);
    end
  end

  // Sign-magnitude addition.
  // For an effective subtraction, the bits lost during alignment must be
  // SUBTRACTED (borrowed), not added: the exact result is mag - delta with
  // delta < 1 in GRS-LSB units. Subtracting 1 from the full fixed-point field
  // (significand + GRS) represents this exactly: the GRS bits become
  // (mag[2:0]-1) mod 8 and the sticky is absorbed into the borrow.
  logic         same_sign;
  logic [SUM_W-1:0] mag;
  logic         rsign;    // sign of the magnitude result
  logic         cancel;   // exact cancellation to zero (6.3)
  logic         diff_sticky;  // effective subtraction with lost bits
  assign same_sign = (a_sign == b_sign_eff);
  always_comb begin
    if (same_sign) begin
      mag    = {1'b0, fp_a} + {1'b0, fp_b};
      rsign  = a_sign;
      cancel = 1'b0;
      diff_sticky = 1'b0;
    end else if ({1'b0, fp_a} >= {1'b0, fp_b}) begin
      mag    = {1'b0, fp_a} - {1'b0, fp_b};
      rsign  = a_sign;
      cancel = (mag == '0);
      diff_sticky = shift_sticky_a | shift_sticky_b;
      if (diff_sticky) mag = mag - 1;
    end else begin
      mag    = {1'b0, fp_b} - {1'b0, fp_a};
      rsign  = b_sign_eff;
      cancel = (mag == '0);
      diff_sticky = shift_sticky_a | shift_sticky_b;
      if (diff_sticky) mag = mag - 1;
    end
  end

  // Exact zero result from cancellation: +0, or -0 under roundTowardNegative (6.3).
  logic [W-1:0] y_cancel;
  assign y_cancel = {(rm == fp_pkg::RM_RM), {W_EXP{1'b0}}, {W_MANT{1'b0}}};

  // Normalize: bring the leading one to bit TARGET; exponent of the result.
  int                    p0;
  logic [NORM_W-1:0]     norm;
  logic                  norm_sticky;
  logic signed [W_EXP+3:0] e_res;
  always_comb begin
    p0 = int'(lpos(mag));
    norm_sticky = align_sticky;  // sticky bits lost during operand alignment
    if (p0 > TARGET) begin
      // Carry out of the significand field: shift right one and bump exponent.
      norm = {(NORM_W-SUM_W+1)'(1'b0), mag} >> 1;
      norm_sticky |= mag[0];
      e_res = (W_EXP+4)'(e_max) + 1;
    end else if (p0 < TARGET) begin
      // Left-normalize: the field is wide enough that no bits are lost here;
      // the significand and GRS bits are simply rebinned (mag's low bits move
      // into the significand/GRS), so no sticky is generated.
      norm = {(NORM_W-SUM_W)'(1'b0), mag} << (TARGET - p0);
      e_res = (W_EXP+4)'(e_max) + (W_EXP+4)'($signed(p0) - TARGET);
    end else begin
      norm = {(NORM_W-SUM_W)'(1'b0), mag};
      e_res = (W_EXP+4)'(e_max);
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
        /* verilator lint_off UNUSEDSIGNAL */
        // The subnormal path right-shifts norm; bits above TARGET (the
        // leading-bit position) are always zero in this path and never read.
        logic [NORM_W-1:0]  shifted;
        /* verilator lint_on UNUSEDSIGNAL */
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
               // exceeds NORM_W the mask is all ones, i.e. every bit sticky).
               | |(norm & (((NORM_W)'(1) << (shift > 0 ? shift : 0)) - 1));
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
          // Rounded up to the smallest normal number.
          y_sub = {rsign, {W_EXP-1{1'b0}}, 1'b1, {W_MANT{1'b0}}};
          flags_sub = inexact_s ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
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
