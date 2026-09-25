// IEEE 754-2019 square root (5.4.1).
//
// Combinational, parameterized by the format: W_EXP exponent bits and W_MANT
// fraction bits (3.3, 3.7 "extendable precision"). Implements:
//   - all five rounding-direction attributes (4.3),
//   - the five exception flags (7.2-7.6): invalid, div-by-zero, overflow,
//     underflow, inexact (bit positions in fp_pkg).
//
// Semantics (bit-exact reference: tests/reference/ops.py):
//   * NaN operands produce a quiet NaN (6.2.3): sign 0, quiet bit set, payload
//     of the operand. Signaling NaNs signal invalid (7.2a).
//   * Infinity: sqrt(+inf) = +inf; sqrt(-inf) signals invalid (7.2g).
//   * Zero: sqrt(+-0) = +-0 (6.3).
//   * Negative numbers (finite or infinite) signal invalid (7.2g: square
//     root of a negative number) and return a quiet NaN.
//   * Overflow/underflow: the square root of a finite number is always within
//     the normal exponent range of the format (sqrt(2^emax) <= 2^(emax/2)),
//     so these can never be signaled; the flags exist for interface
//     consistency with the other datapaths.
//   * Inexact (7.6): signaled iff the rounded result differs from the exact
//     (generally irrational) result.
//
// Datapath: unpack -> special cases -> integer digit-by-digit square root of
// a scaled radicand -> round per attribute -> re-encode.
//
// Square-root math: a = s_a * 2^e_a (e_a is the leading-bit exponent). The
// result's leading exponent is e_res = floor(e_a/2). Scaling the radicand by
// X = s_a << (2*TARGET + (e_a mod 2) - bitlen(s_a) + 1) puts sqrt(X)'s MSB
// exactly at bit TARGET, so placed = floor(sqrt(X)) is the significand plus
// the guard/round bits and the sticky comes from whether X is a perfect
// square (the integer square-root remainder). rsign is always 0: the square
// root of a non-negative number is non-negative.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
// Int arithmetic is deliberately mixed with sized logic; every expression is
// bounded such that the truncation/extensions are exact.

module fp_sqrt #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23
) (
  input  logic [1+W_EXP+W_MANT-1:0] a,
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
  localparam int TARGET  = S_W + 2;              // MSB position of the root significand
  localparam int FW      = S_W + 3;              // root fixed-point width (sig + GRS)
  localparam int R_W     = 2 * S_W + 6;          // scaled radicand width (even)
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
  logic              a_sign;
  logic [W_EXP-1:0]  a_exp;
  logic [MANT_W-1:0] a_mant;
  assign a_sign = a[W-1];
  assign a_exp  = a[W-2 -: W_EXP];
  // The mantissa field is empty for W_MANT = 0 (E8M0); the width guard keeps
  // the extraction from producing a negative index. `if (W_MANT > 0)` is a
  // constant condition, so the dead branch is eliminated at elaboration.
  always_comb begin
    a_mant = '0;
    if (W_MANT > 0) begin
      a_mant = a[W_MANT-1:0];
    end
  end

  logic a_nan, a_snan, a_inf, a_zero, a_sub;
  assign a_nan  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant != '0);
  assign a_snan = a_nan && !a_mant[MANT_W-1];
  assign a_inf  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant == '0);
  assign a_zero = (a_exp == '0) && (a_mant == '0);
  assign a_sub  = (a_exp == '0) && (a_mant != '0);

  // ------------------------------------------------------- special cases (6.x)
  logic [W-1:0] y_special;
  logic [4:0]   flags_special;
  logic         special_case;
  always_comb begin
    y_special    = '0;
    flags_special = '0;
    special_case = 1'b0;
    if (a_nan) begin
      // 6.2.3: quiet NaN, payload of the operand; 7.2a: sNaN -> invalid.
      // Unreachable for W_MANT = 0 (E8M0 has no NaN encodings).
      y_special = {1'b0, EXP_ALL[W_EXP-1:0], a_mant | QUIET};
      flags_special[fp_pkg::FLAG_INVALID] = a_snan;
      special_case = 1'b1;
    end else if (a_inf) begin
      if (a_sign) begin
        // 7.2g: sqrt of negative infinity.
        y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
        flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
      end else begin
        y_special = {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      end
      special_case = 1'b1;
    end else if (a_zero) begin
      // 6.3: sqrt(+-0) = +-0.
      y_special = {a_sign, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
      special_case = 1'b1;
    end else if (a_sign) begin
      // 7.2g: sqrt of a negative finite number.
      y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
      flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
      special_case = 1'b1;
    end
  end

  // ----------------------------------------------------- main datapath (the
  // operand is a positive finite number).
  logic [S_W-1:0] s_a;  // significand with implicit bit (3.3)
  // Implicit bit at position W_MANT. The OR form (instead of a
  // concatenation with a zero-width fill) keeps the width exactly S_W even
  // for W_MANT = 0 (E8M0), where the significand is just the implicit bit.
  assign s_a = a_sub ? {1'b0, a_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, a_mant};

  // Bit length of x (leading-one position + 1); 0 if x is zero. Last set bit
  // wins, i.e. the highest set bit (no break: yosys does not support `break`
  // in for loops).
  function automatic int unsigned bitlen(input logic [S_W-1:0] x);
    bitlen = 0;
    for (int i = 0; i < S_W; i++)
      if (x[i]) bitlen = i + 1;
  endfunction

  // Leading-bit exponent: value = s_a * 2^e_a. Same formula as the other ops.
  logic signed [W_EXP+2:0] e_a;
  always_comb begin
    // bitlen is computed unconditionally (yosys would otherwise leave a
    // don't-care anyseq on the branch that does not call it, corrupting the
    // formal model when multiple instances are elaborated).
    int bl_a;
    bl_a = int'(bitlen(s_a));
    e_a = (W_EXP+3)'(a_exp - BIAS);
    if (a_sub) e_a = (W_EXP+3)'((1 - BIAS) - W_MANT + $signed(bl_a) - 1);
  end

  // Integer floor square root of the even-width radicand x, digit-by-digit
  // (restoring): process two bits of x per root bit, MSB-first. The final
  // remainder x - q^2 is returned through rem_out: it is exactly the sticky
  // term (x is a perfect square iff the remainder is zero), so the caller
  // does not need to square the root again.
  function automatic logic [FW-1:0] isqrt(input logic [R_W-1:0] x,
                                          output logic [R_W-1:0] rem_out);
    logic [R_W-1:0] rem;
    logic [FW-1:0]  q;
    logic [R_W-1:0] t;
    rem = '0;
    q   = '0;
    for (int i = FW-1; i >= 0; i--) begin
      rem = (rem << 2) | {x[2*i+1], x[2*i]};
      t   = ((R_W)'(q) << 2) | 1;
      if (rem >= t) begin
        rem = rem - t;
        q   = (q << 1) | 1'b1;
      end else begin
        q   = q << 1;
      end
    end
    rem_out = rem;
    isqrt = q;
  endfunction

  // Scaled radicand X (sqrt(X)'s MSB at TARGET) and its floor square root.
  // The isqrt remainder is the sticky: X - placed^2 > 0 iff X has no exact
  // root (used only as a single sticky bit, so the exact magnitude is not
  // needed).
  logic [R_W-1:0] X;
  logic [FW-1:0]  placed;
  logic           norm_sticky;
  logic signed [W_EXP+3:0] e_res;
  always_comb begin
    int S;
    logic [R_W-1:0] rem;
    S = 2*TARGET + int'(e_a[0]) - int'(bitlen(s_a)) + 1;
    X = (R_W)'(s_a) << S;
    placed = isqrt(X, rem);
    norm_sticky = |rem;
  end
  assign e_res = e_a >>> 1;  // floor(e_a / 2)

  logic rsign;  // sqrt of a non-negative number is non-negative
  assign rsign = 1'b0;

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
      // Overflow (7.4): unreachable for sqrt (sqrt(2^emax) <= 2^(emax/2)),
      // kept for structural consistency with the other datapaths.
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
          // carries past 2^emin (same rule as fp_mul/fp_div).
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
