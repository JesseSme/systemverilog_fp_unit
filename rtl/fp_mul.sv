// IEEE 754-2019 multiplication (5.4.1).
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
//   * Infinity: inf x finite = inf; the sign of a product of infinities is the
//     XOR of the operand signs (6.3). inf x 0 signals invalid (7.2e) and
//     returns a quiet NaN.
//   * Zero: 0 x finite = 0; the sign of a product of zeros is the XOR of the
//     operand signs (6.3); the roundTowardNegative sign quirk of addition does
//     not apply to products.
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
// Datapath: unpack -> special cases -> exact 2p-bit significand product ->
// place its MSB at bit TARGET (dropping low bits into a sticky term) ->
// round per attribute -> overflow/underflow handling -> re-encode.
//
// Exact product value = P * 2^(e_a + e_b - bitlen(P) + 1), where P = s_a*s_b
// is the 2*S_W-bit unsigned product of the two significands and e_a/e_b are
// the leading-bit exponents (computed exactly as in fp_add). The result needs
// only the top S_W + 2 bits of P (significand + GRS); everything below is
// captured into a sticky bit, so the product is truncated to FW bits with the
// MSB parked at TARGET.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
// Int arithmetic is deliberately mixed with sized logic; every expression is
// bounded such that the truncation/extensions are exact.

module fp_mul #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23
) (
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
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
  localparam int TARGET  = S_W + 2;              // MSB position of the placed product
  localparam int FW      = S_W + 3;              // fixed-point width (sig + GRS)
  localparam int P_W     = 2 * S_W;              // exact product width
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
  logic              a_sign, b_sign;
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
      // Sign of an infinity product is the XOR of the operand signs (6.3).
      if (a_inf && b_inf) begin
        y_special = {a_sign ^ b_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      end else if (a_inf) begin
        if (b_zero) begin
          // 7.2e: infinity x zero signals invalid.
          y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
          flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
        end else begin
          y_special = {a_sign ^ b_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        end
      end else begin
        if (a_zero) begin
          // 7.2e: zero x infinity signals invalid.
          y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
          flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
        end else begin
          y_special = {a_sign ^ b_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        end
      end
      special_case = 1'b1;
    end else if (a_zero || b_zero) begin
      // 6.3: a product of zeros has the XOR of the operand signs; unlike
      // addition there is no roundTowardNegative sign quirk for products.
      y_special = {a_sign ^ b_sign, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
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

  // Bit length of the exact product.
  function automatic int unsigned pbitlen(input logic [P_W-1:0] x);
    pbitlen = 0;
    for (int i = 0; i < P_W; i++)
      if (x[i]) pbitlen = i + 1;
  endfunction

  // Exact 2*S_W-bit significand product. Both operands are non-zero here (the
  // zero cases are special-cased above), so P >= 1 and the leading-one
  // position is well defined.
  logic [P_W-1:0] P;
  assign P = (P_W)'(s_a) * (P_W)'(s_b);

  // Place the product: bring its MSB to bit TARGET inside the FW-bit field.
  // If P is wider than FW (always the case for two normal significands),
  // keep only the top FW bits and OR the dropped ones into norm_sticky; if P
  // is narrower (subnormal operands), left-shift it up (no bits lost).
  logic [FW-1:0] placed;
  logic          norm_sticky;
  always_comb begin
    int B;
    B = int'(pbitlen(P));
    norm_sticky = 1'b0;
    if (B == 0) begin
      // Defensive: P = 0 cannot occur here (zero operands are special cases).
      placed = '0;
      norm_sticky = 1'b0;
    end else if (B <= FW) begin
      placed = FW'(P) << (FW - B);
      norm_sticky = 1'b0;
    end else begin
      placed = FW'(P >> (B - FW));
      // OR of the dropped low bits, as a mask reduction (no accumulation loop:
      // yosys's proc turns a self-referencing `|=` in a loop into a spurious
      // don't-care anyseq that corrupts the formal model).
      norm_sticky = |(P & (((P_W)'(1) << (B - FW)) - 1));
    end
  end

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

  // Result exponent (leading-bit exponent of the product). The leading-bit
  // exponents add, plus one when the significand product carries out of its
  // own grid: bitlen(P) == bitlen(s_a) + bitlen(s_b) (e.g. two normal
  // significands whose product is >= 2^(2*S_W-1)). With that carry, e.g.
  // a = 1.66 x 2^1 and b = 1.96 x 2^9 give P's MSB one bit above 2^(e_a+e_b).
  logic signed [W_EXP+3:0] e_res;
  assign e_res = (W_EXP+4)'(e_a) + (W_EXP+4)'(e_b)
               + (W_EXP+4)'(pbitlen(P) == bitlen(s_a) + bitlen(s_b));

  logic rsign;  // sign of the product = XOR of the operand signs (6.3)
  assign rsign = a_sign ^ b_sign;

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
    sig     = placed[TARGET -: S_W];
    g       = placed[2];
    r       = placed[1];
    s_bit   = placed[0] | norm_sticky;
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
        if (shift > 0) shifted = placed >> shift;
        else           shifted = '0;
        sig_s  = shifted[TARGET -: S_W];
        gs     = shifted[2];
        rs     = shifted[1];
        ss     = shifted[0] | norm_sticky
               // OR of the low shift bits of placed (mask reduction; when
               // shift exceeds FW the mask is all ones, i.e. every bit sticky).
               | |(placed & (((FW)'(1) << (shift > 0 ? shift : 0)) - 1));
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
          // carries past 2^emin. On the subnormal grid (sig_s all ones) that
          // carry needs the fraction >= 3/4 ulp (guard+round) for RNE/RNA,
          // but only a non-zero remainder (guard) for RP/RM (which round up
          // for any inexact, toward +inf for positive / -inf for negative).
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
    end else if ($signed(e_res) >= EMIN_S) begin
      y     = y_normal;
      flags = flags_normal;
    end else begin
      y     = y_sub;
      flags = flags_sub;
    end
  end

endmodule
