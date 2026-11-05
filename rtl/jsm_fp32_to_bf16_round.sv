// Round a binary32 value to bfloat16 (roundTiesToEven, 4.3.1).
//
// Used after fp32 jsm_fp_unit operations to produce the single bf16 rounding that
// the PyTorch model performs per arithmetic operation. Combinational, no
// exception flags (this is a format conversion helper, not an jsm_fp_unit op).
//
// Semantics (bit-exact vs tests/reference/ops.py:f32_to_bf16_rne):
//   * finite x: RNE on the 16 dropped fraction bits (subnormals included;
//     the bf16 and binary32 exponent ranges are identical, so a subnormal
//     stays on the same grid). Rounding the largest finite magnitudes up
//     produces the correctly signed infinity (0x7F80 / 0xFF80) through the
//     ordinary carry into the exponent field.
//   * +-Inf: returned unchanged.
//   * NaN: returned as a QUIET NaN with the sign and the top 6 payload bits
//     of x: {sign, 8'hFF, 1'b1, x[21:16]}. A NaN never becomes infinity, even
//     if its payload lies only in the dropped low bits, and a signaling NaN
//     is quieted (6.2).

module jsm_fp32_to_bf16_round (
  input  logic [31:0] x,
  output logic [15:0] y
);

  logic [15:0] hi;
  logic        guard;
  logic        sticky;
  logic        lsb;
  logic        round_up;
  logic        is_inf_nan;
  logic        is_nan;

  assign hi         = x[31:16];
  assign guard      = x[15];
  assign sticky     = |x[14:0];
  assign lsb        = x[16];
  assign round_up   = guard && (sticky || lsb);
  assign is_inf_nan = (x[30:23] == 8'hFF);
  assign is_nan     = is_inf_nan && (x[22:0] != 23'd0);

  always_comb begin
    if (is_nan)
      y = {x[31], 8'hFF, 1'b1, x[21:16]};  // quiet NaN, sign + top payload kept
    else if (is_inf_nan)
      y = hi;                              // +-Inf unchanged
    else
      y = hi + {15'd0, round_up};          // finite: RNE (carry may reach Inf)
  end

endmodule
