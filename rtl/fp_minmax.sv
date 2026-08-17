// IEEE 754-2019 minimum / maximum (5.6.1).
//
// Combinational, parameterized by the format: W_EXP exponent bits and W_MANT
// fraction bits. `is_max` selects maximum, otherwise minimum.
//
// Semantics (bit-exact reference: tests/reference/ops.py):
//   * A NaN operand (either) produces a quiet NaN (6.2.3) with the payload of
//     the first NaN operand; signaling NaNs signal invalid (7.2a).
//   * Otherwise the numerically smaller (min) or larger (max) operand is
//     returned exactly: -inf < finite < +inf, with minimum(-0,+0) = -0 and
//     maximum(-0,+0) = +0 (5.6.1). Equal non-zero operands (or equal
//     infinities) return either; we return the first operand.
//   * No rounding and no flags other than the sNaN invalid.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SELRANGE */
// Int arithmetic is deliberately mixed with sized logic; every expression is
// bounded such that the truncation/extensions are exact. `rm` is part of the
// common interface but this operation does not round. The mantissa slice is
// dead (guarded) for W_MANT = 0 but Verilator still lints the constant-false
// range.

module fp_minmax #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23
) (
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
  input  logic                      is_max,
  input  fp_pkg::rounding_t         rm,   // unused by this operation
  output logic [1+W_EXP+W_MANT-1:0] y,
  output logic [4:0]                flags
);

  localparam int W       = 1 + W_EXP + W_MANT;   // total width
  localparam int MANT_W  = (W_MANT > 0) ? W_MANT : 1;  // internal mantissa width
  localparam int EXP_ALL = (1 << W_EXP) - 1;     // all-ones exponent field
  // Quiet bit of a NaN payload. Sized to MANT_W: `int` arithmetic would
  // overflow for W_MANT >= 32 (e.g. binary64); for W_MANT = 0 (E8M0) the
  // NaN path is unreachable and this constant is never used.
  localparam logic [MANT_W-1:0] QUIET = (MANT_W)'(1) << (MANT_W - 1);

  // ------------------------------------------------------------- unpack (3.3)
  logic              a_sign, b_sign;
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

  logic a_nan, a_snan, a_inf;
  logic b_nan, b_snan, b_inf;
  assign a_nan  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant != '0);
  assign a_snan = a_nan && !a_mant[MANT_W-1];
  assign a_inf  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant == '0);
  assign b_nan  = (b_exp == EXP_ALL[W_EXP-1:0]) && (b_mant != '0);
  assign b_snan = b_nan && !b_mant[MANT_W-1];
  assign b_inf  = (b_exp == EXP_ALL[W_EXP-1:0]) && (b_mant == '0);

  // --------------------------------------------------------------- result
  // Magnitude key: exponent field shifted above the fraction (W_EXP+W_MANT
  // bits); infinity is larger than any finite, so it gets the all-ones key.
  // (For E8M0, W_MANT = 0, the key is just the exponent field and +inf is
  // EXP_ALL.) -inf therefore orders below +inf via the sign-aware comparison.
  localparam logic [W_EXP+W_MANT-1:0] MAG_INF = '1;
  logic [W_EXP+W_MANT-1:0] mag_a, mag_b;
  assign mag_a = a_inf ? MAG_INF : ((W_EXP+W_MANT)'(a_exp) << W_MANT) | (W_EXP+W_MANT)'(a_mant);
  assign mag_b = b_inf ? MAG_INF : ((W_EXP+W_MANT)'(b_exp) << W_MANT) | (W_EXP+W_MANT)'(b_mant);

  // a < b: different signs -> negative is smaller; same sign -> the sign
  // determines the magnitude direction (larger magnitude is smaller when both
  // negative). Treating -0 < +0 this way makes minimum(-0,+0) = -0 and
  // maximum(-0,+0) = +0 fall out automatically.
  logic a_lt_b, b_lt_a;
  always_comb begin
    if (a_sign != b_sign) begin
      a_lt_b = a_sign;
      b_lt_a = b_sign;
    end else if (a_sign) begin
      a_lt_b = (mag_a > mag_b);
      b_lt_a = (mag_b > mag_a);
    end else begin
      a_lt_b = (mag_a < mag_b);
      b_lt_a = (mag_b < mag_a);
    end
  end

  always_comb begin
    y     = a;
    flags = 5'd0;
    if (a_nan) begin
      // 6.2.3: quiet NaN, payload of the first NaN operand; 7.2a: sNaN -> invalid.
      y = {1'b0, EXP_ALL[W_EXP-1:0], a_mant | QUIET};
      flags[fp_pkg::FLAG_INVALID] = a_snan || b_snan;
    end else if (b_nan) begin
      y = {1'b0, EXP_ALL[W_EXP-1:0], b_mant | QUIET};
      flags[fp_pkg::FLAG_INVALID] = a_snan || b_snan;
    end else if (a_lt_b) begin
      // min picks the smaller, max the larger.
      y = is_max ? b : a;
    end else if (b_lt_a) begin
      y = is_max ? a : b;
    end
  end

endmodule
