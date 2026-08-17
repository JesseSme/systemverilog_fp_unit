// IEEE 754-2025 E8M0 (microscaling shared-exponent format) roundToIntegral
// (5.9). Format: 1 sign bit + W_EXP exponent bits and NO significand bits, so
// every finite value is an exact power of two; there are no subnormals and no
// NaN encodings.
//
// Semantics (bit-exact reference: tests/reference/ops.py):
//  - Infinity and zero: returned unchanged, including the sign of zero.
//  - Finite 2^e with e >= 0 is already integral: returned unchanged.
//  - Finite 2^e with e < 0 lies in (0,1) and rounds to 0 or 1 per the
//    rounding-direction attribute, with the sign of x preserved for a zero
//    result (5.9): 0.5 is the only tie (RNE -> 0, RNA/RP (positive) -> 1,
//    RM (positive) -> 0, and for a negative operand RP -> -0, RM -> -1).
//    roundToIntegral does not signal inexact.
//  - No overflow: the rounded result is 0 or 2^0, and the only representable
//    integer 1 is within range (emax >= 0).
//
// This module exists because the generic fp_roundint datapath cannot be
// elaborated by Verilator 5.020 at W_MANT = 0 (gate-optimizer internal fault,
// same as the other arithmetic ops).

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
// Int arithmetic is deliberately mixed with sized logic; every expression is
// bounded such that the truncation/extensions are exact.

module fp_roundint_e8m0 #(
  parameter int W_EXP = 8
) (
  input  logic [W_EXP:0]    a,
  input  fp_pkg::rounding_t rm,
  output logic [W_EXP:0]    y,
  output logic [4:0]        flags
);

  localparam int BIAS    = (1 << (W_EXP-1)) - 1;  // exponent bias
  localparam int EXP_ALL = (1 << W_EXP) - 1;      // all-ones exponent field

  logic              a_sign;
  logic [W_EXP-1:0]  a_exp;
  assign a_sign = a[W_EXP];
  assign a_exp  = a[W_EXP-1:0];

  logic a_inf, a_zero;
  assign a_inf  = (a_exp == EXP_ALL[W_EXP-1:0]);
  assign a_zero = (a_exp == '0);

  logic signed [W_EXP+2:0] e;
  assign e = (W_EXP+3)'(a_exp - BIAS);

  logic           up;    // round up from 0 to 1
  always_comb begin
    up    = 1'b0;
    y     = a;
    if (a_inf || a_zero || $signed(e) >= 0) begin
      // Infinity, zero, or an already-integral power of two 2^e (e >= 0).
      y = a;
    end else begin
      // 2^e in (0,1). The only half-way value is 2^-1; anything smaller is
      // strictly below it, so the guard bit is (e == -1) and the sticky is 1
      // for everything else. The integer part is 0 (even), so RNE resolves
      // the 0.5 tie toward 0.
      if (rm == fp_pkg::RM_RNA && e == -1) up = 1'b1;
      if (rm == fp_pkg::RM_RP && ~a_sign)  up = 1'b1;
      if (rm == fp_pkg::RM_RM && a_sign)   up = 1'b1;
      y = up ? {a_sign, (W_EXP)'(BIAS)} : {a_sign, {W_EXP{1'b0}}};
    end
  end

  assign flags = 5'd0;

endmodule
