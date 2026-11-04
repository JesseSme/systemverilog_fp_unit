// fp_unit with a plain-vector interface (no SystemVerilog types on the
// ports or parameters), for instantiation from Verilog-2001 and, through
// fp_unit_top.v, from VHDL.
//
// fp_unit's `mode` and `rm` ports are the enum types fp_pkg::op_t and
// fp_pkg::rounding_t, and OPS_EN is a `logic [15:0]` parameter. A Verilog
// or VHDL parent cannot connect those portably, so this shim takes plain
// vectors and integer parameters and casts them. It adds no logic.
//
// Parameters (all integer):
//   W_EXP, W_MANT  format: 1 sign + W_EXP exponent + W_MANT fraction bits
//   DIVSQRT_IMPL   1 SRT pipelines (5.6 ns), 3 SRT 4.0 ns form,
//                  2 iterative engine, 0 combinational reference
//   TAG_W          request tag width (>= 1)
//   OPS_EN         operation enable mask, bit i = opcode i (0..65535)

module fp_unit_flat #(
  parameter int W_EXP        = 8,
  parameter int W_MANT       = 23,
  parameter int DIVSQRT_IMPL = 1,
  parameter int TAG_W        = 1,
  parameter int OPS_EN       = 32'h0000FFFF
) (
  input  logic                      clk,
  input  logic                      rst_n,
  input  logic                      in_valid,
  output logic                      in_ready,
  input  logic [3:0]                mode,
  input  logic [2:0]                rm,
  input  logic [W_EXP+W_MANT:0]     a,
  input  logic [W_EXP+W_MANT:0]     b,
  input  logic [W_EXP+W_MANT:0]     c,
  input  logic [TAG_W-1:0]          in_tag,
  output logic [W_EXP+W_MANT:0]     y,
  output logic [1:0]                cmp,
  output logic [4:0]                flags,
  output logic                      out_valid,
  output logic [TAG_W-1:0]          out_tag
);

  localparam logic [15:0] OPS_EN_V = OPS_EN[15:0];

  fp_unit #(
    .W_EXP(W_EXP), .W_MANT(W_MANT), .DIVSQRT_IMPL(DIVSQRT_IMPL),
    .TAG_W(TAG_W), .OPS_EN(OPS_EN_V)
  ) u_fp_unit (
    .clk(clk), .rst_n(rst_n),
    .in_valid(in_valid), .in_ready(in_ready),
    .mode(fp_pkg::op_t'(mode)), .rm(fp_pkg::rounding_t'(rm)),
    .a(a), .b(b), .c(c), .in_tag(in_tag),
    .y(y), .cmp(cmp), .flags(flags),
    .out_valid(out_valid), .out_tag(out_tag)
  );

endmodule
