// IEEE 754-2019 totalOrder predicate (5.10).
//
// Combinational, parameterized by the format: W_EXP exponent bits and W_MANT
// fraction bits (format-generic; no E8M0 split). Outputs cmp[0] = 1 iff a
// precedes-or-equals b in the total order, cmp[1] = 0; the `y` output is
// unused (driven to 0).
//
// Semantics (bit-exact reference: tests/reference/ops.py):
//   * totalOrder is a NON-STRICT order: totalOrder(x, x) is true for identical
//     encodings (it orders canonical encodings, "x precedes-or-equals y").
//   * Order: -qNaN < -sNaN < -inf < negative finite < -0 < +0 < positive
//     finite < +inf < +sNaN < +qNaN. NaN payloads order as unsigned integers
//     with the quiet bit the fraction MSB (a valid 754-2019 payload ordering;
//     it also satisfies the stricter 754-2008 rule).
//   * This is exactly the sign-magnitude integer order: for a negative value,
//     flip all bits except the sign, then compare as signed two's complement
//     (the classic no-FPU comparison trick). -0 maps to -1, +0 to 0, so
//     totalOrder(-0, +0) is true.
//   * totalOrder never signals an exception, even for a signaling NaN (5.10
//     is not a 5.11 comparison; no NaN result is produced, so 6.2.3 does not
//     apply). The rm input is part of the common interface but unused.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */
// Int arithmetic is deliberately mixed with sized logic; every expression is
// bounded such that the truncation/extensions are exact. rm is part of the
// common interface but this operation does not round.

module fp_totalorder #(
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

  localparam int W = 1 + W_EXP + W_MANT;   // total width
  // Sign bit, sized to W: `int` shifts would overflow for W >= 32 (binary64).
  localparam logic [W-1:0] SIGN = (W)'(1) << (W-1);

  // Sign-magnitude to signed-two's-complement key: flip all bits except the
  // sign for negative encodings. The sign bit (MSB) is preserved so a signed
  // comparison of the keys reproduces the total order.
  logic signed [W-1:0] key_a, key_b;
  always_comb begin
    key_a = a[W-1] ? ((~a) | SIGN) : (W)'(a);
    key_b = b[W-1] ? ((~b) | SIGN) : (W)'(b);
  end

  always_comb begin
    y     = '0;
    flags = 5'd0;
    cmp   = {1'b0, (key_a <= key_b)};
  end

endmodule
