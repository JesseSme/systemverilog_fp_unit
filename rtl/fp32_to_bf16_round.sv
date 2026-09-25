// Round a binary32 value to bfloat16 (roundTiesToEven).
//
// Used after fp32 fp_unit operations to produce the single bf16 rounding that
// the PyTorch model performs per arithmetic operation. NaN/Inf pass through
// unchanged; exponent overflow on rounding produces the correct signed Inf.

module fp32_to_bf16_round (
  input  logic [31:0] x,
  output logic [15:0] y
);

  logic [15:0] hi;
  logic        guard;
  logic        sticky;
  logic        lsb;
  logic        round_up;
  logic [16:0] rounded;

  assign hi       = x[31:16];
  assign guard    = x[15];
  assign sticky   = |x[14:0];
  assign lsb      = x[16];
  assign round_up = guard && (sticky || lsb);
  assign rounded  = {1'b0, hi} + {16'b0, round_up};

  always_comb begin
    if (x[30:23] == 8'hFF)
      y = hi;                     // NaN / Inf: keep as-is
    else if (rounded[16])
      y = {x[31], 8'hFF, 7'h00};  // overflow -> signed Inf
    else
      y = rounded[15:0];
  end

endmodule
