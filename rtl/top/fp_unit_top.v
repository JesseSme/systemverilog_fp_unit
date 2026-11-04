// Verilog-2001 top-level wrapper of the floating-point unit (fp_unit).
//
// Plain Verilog ports and integer parameters only, so this file can be the
// top of a Vivado project, a block-design module reference, or a component
// instantiated from VHDL (see fp_unit_vhd.vhd). It instantiates
// fp_unit_flat.sv, which casts to fp_unit's SystemVerilog port types; add
// the SystemVerilog core files (rtl/filelist.f) plus rtl/top/fp_unit_flat.sv
// to the project as well.
//
// Interface summary (docs/fp_unit_core.md has the full description):
//   * A request is accepted on a rising clk edge with in_valid && in_ready.
//     Hold mode/rm/a/b/c/in_tag while in_valid && !in_ready. in_ready depends
//     on mode only (combinationally), never on in_valid.
//   * Every accepted request produces exactly one out_valid pulse, after the
//     operation's fixed latency; out_tag returns its in_tag. Results can
//     complete out of request order (a short op can overtake a long one).
//   * rst_n is synchronous and active low.
//
// Parameters:
//   W_EXP, W_MANT  format: 1 sign + W_EXP exponent + W_MANT fraction bits
//                  (e.g. 8/23 binary32, 11/52 binary64, 5/10 binary16,
//                  8/7 bfloat16, 4/3 E4M3, 5/2 E5M2, 8/0 E8M0; verified
//                  formats are listed in docs/fp_unit_core.md)
//   DIVSQRT_IMPL   1 SRT pipelines (default, 5.6 ns on VU9P-2L),
//                  3 SRT pipelines in the 4.0 ns form (more cycles),
//                  2 iterative engine (4.0 ns, one div/sqrt in flight),
//                  0 combinational reference (slow; for reference only)
//   TAG_W          request tag width (>= 1)
//   OPS_EN         operation enable mask, bit i = opcode i; a disabled
//                  operation is not built and returns y = 0 with invalid

module fp_unit_top #(
  parameter integer W_EXP        = 8,
  parameter integer W_MANT       = 23,
  parameter integer DIVSQRT_IMPL = 1,
  parameter integer TAG_W        = 1,
  parameter integer OPS_EN       = 32'h0000FFFF
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_RESET rst_n" *)
  input  wire                    clk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                    rst_n,
  input  wire                    in_valid,
  output wire                    in_ready,
  input  wire [3:0]              mode,     // opcode (fp_pkg::op_t)
  input  wire [2:0]              rm,       // rounding mode (fp_pkg::rounding_t)
  input  wire [W_EXP+W_MANT:0]   a,
  input  wire [W_EXP+W_MANT:0]   b,
  input  wire [W_EXP+W_MANT:0]   c,        // FMA addend
  input  wire [TAG_W-1:0]        in_tag,
  output wire [W_EXP+W_MANT:0]   y,
  output wire [1:0]              cmp,      // compare condition / totalOrder bit
  output wire [4:0]              flags,    // {invalid, div0, overflow, underflow, inexact}
  output wire                    out_valid,
  output wire [TAG_W-1:0]        out_tag
);

  fp_unit_flat #(
    .W_EXP(W_EXP), .W_MANT(W_MANT), .DIVSQRT_IMPL(DIVSQRT_IMPL),
    .TAG_W(TAG_W), .OPS_EN(OPS_EN)
  ) u_fp_unit_flat (
    .clk(clk), .rst_n(rst_n),
    .in_valid(in_valid), .in_ready(in_ready),
    .mode(mode), .rm(rm),
    .a(a), .b(b), .c(c), .in_tag(in_tag),
    .y(y), .cmp(cmp), .flags(flags),
    .out_valid(out_valid), .out_tag(out_tag)
  );

endmodule
