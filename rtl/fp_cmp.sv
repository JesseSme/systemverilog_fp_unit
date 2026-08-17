// IEEE 754-2019 quiet comparison (5.11).
//
// Combinational, parameterized by the format: W_EXP exponent bits and W_MANT
// fraction bits (format-generic; no E8M0 split). Produces a 2-bit condition
// code on `cmp`: CMP_LT (a < b), CMP_EQ (a == b), CMP_GT (a > b) or CMP_UN
// (unordered, a NaN operand). The `y` output is unused (driven to 0).
//
// Semantics (bit-exact reference: tests/reference/ops.py):
//   * A quiet comparison signals invalid (7.2a) only for a signaling NaN
//     operand; a quiet NaN operand is unordered but does not signal.
//   * -0 compares equal to +0; NaN is unordered with everything.
//   * No rounding; the rm input is part of the common interface but unused.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SELRANGE */
// Int arithmetic is deliberately mixed with sized logic; every expression is
// bounded such that the truncation/extensions are exact. The mantissa slice
// is dead (guarded) for W_MANT = 0 but Verilator still lints the
// constant-false range.

module fp_cmp #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23
) (
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
  input  fp_pkg::rounding_t         rm,   // unused by this operation
  output logic [1+W_EXP+W_MANT-1:0] y,
  output logic [1:0]                cmp,
  output logic [4:0]                flags
);

  localparam int W       = 1 + W_EXP + W_MANT;   // total width
  localparam int MANT_W  = (W_MANT > 0) ? W_MANT : 1;  // internal mantissa width
  localparam int EXP_ALL = (1 << W_EXP) - 1;     // all-ones exponent field

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
  logic a_zero, b_zero;
  assign a_zero = (a_exp == '0) && (a_mant == '0);
  assign b_zero = (b_exp == '0) && (b_mant == '0);

  // --------------------------------------------------------------- ordering
  // Magnitude key: exponent field shifted above the fraction (W_EXP+W_MANT
  // bits); infinity is larger than any finite (all-ones key).
  localparam logic [W_EXP+W_MANT-1:0] MAG_INF = '1;
  logic [W_EXP+W_MANT-1:0] mag_a, mag_b;
  assign mag_a = a_inf ? MAG_INF : ((W_EXP+W_MANT)'(a_exp) << W_MANT) | (W_EXP+W_MANT)'(a_mant);
  assign mag_b = b_inf ? MAG_INF : ((W_EXP+W_MANT)'(b_exp) << W_MANT) | (W_EXP+W_MANT)'(b_mant);

  // a < b: different signs -> negative is smaller; same sign -> the sign
  // determines the magnitude direction. Unlike minimum/maximum (5.6.1) this
  // ordering treats -0 and +0 as equal, so the zero/zero pair is special-cased
  // in the result mux (both have magnitude key 0, and the sign-opposite branch
  // would wrongly order -0 below +0).
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
    y     = '0;
    flags = 5'd0;
    cmp   = fp_pkg::CMP_EQ;
    if (a_nan || b_nan) begin
      // 5.11: NaN compares unordered; 7.2a: a quiet comparison signals
      // invalid only for a signaling NaN operand.
      cmp = fp_pkg::CMP_UN;
      flags[fp_pkg::FLAG_INVALID] = a_snan || b_snan;
    end else if (a_zero && b_zero) begin
      cmp = fp_pkg::CMP_EQ;
    end else if (a_lt_b) begin
      cmp = fp_pkg::CMP_LT;
    end else if (b_lt_a) begin
      cmp = fp_pkg::CMP_GT;
    end else begin
      cmp = fp_pkg::CMP_EQ;
    end
  end

endmodule
