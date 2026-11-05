// Copyright 2026 Jesse Smedberg
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Verilog-2001 top of the AXI4-Stream floating-point unit (jsm_fp_unit_axis).
//
// Full backpressure on both streams; results leave in request order with the
// request's TUSER and TLAST. TDATA layouts (OPB = 1 + W_EXP + W_MANT rounded
// up to a multiple of 8):
//   S_AXIS TDATA (3*OPB + 8 bits): [OPB-1:0] a, [2*OPB-1:OPB] b,
//     [3*OPB-1:2*OPB] c, [3*OPB+3:3*OPB] opcode, [3*OPB+6:3*OPB+4] rounding
//     mode, [3*OPB+7] 0
//   M_AXIS TDATA (OPB + 8 bits): [OPB-1:0] y, [OPB+4:OPB] flags
//     {invalid, divByZero, overflow, underflow, inexact}, [OPB+6:OPB+5] cmp,
//     [OPB+7] 0
// See docs/user_guide.md. Add the SystemVerilog core (rtl/filelist.f) and
// rtl/jsm_fp_unit_axis.sv to the project.
//
// Parameters:
//   W_EXP, W_MANT  format
//   DIVSQRT_IMPL   1 SRT (5.6 ns), 3 SRT 4.0 ns form, 2 iterative, 0 comb.
//   OPS_EN         operation enable mask, bit i = opcode i
//   TUSER_W        TUSER width (>= 1)
//   DEPTH          reorder-buffer entries, 0 = automatic (full throughput)

module jsm_fp_unit_axis_top #(
  parameter integer W_EXP        = 8,
  parameter integer W_MANT       = 23,
  parameter integer DIVSQRT_IMPL = 1,
  parameter integer OPS_EN       = 65535,         // 0xFFFF: all operations
  parameter integer TUSER_W      = 1,
  parameter integer DEPTH        = 0
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIS:M_AXIS, ASSOCIATED_RESET aresetn" *)
  input  wire                                       aclk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                                       aresetn,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TVALID" *)
  input  wire                                       s_axis_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TREADY" *)
  output wire                                       s_axis_tready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TDATA" *)
  input  wire [3*(((W_EXP+W_MANT+8)/8)*8)+7:0]      s_axis_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TUSER" *)
  input  wire [TUSER_W-1:0]                         s_axis_tuser,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TLAST" *)
  input  wire                                       s_axis_tlast,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TVALID" *)
  output wire                                       m_axis_tvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TREADY" *)
  input  wire                                       m_axis_tready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
  output wire [(((W_EXP+W_MANT+8)/8)*8)+7:0]        m_axis_tdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TUSER" *)
  output wire [TUSER_W-1:0]                         m_axis_tuser,
  (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TLAST" *)
  output wire                                       m_axis_tlast
);

  jsm_fp_unit_axis #(
    .W_EXP(W_EXP), .W_MANT(W_MANT), .DIVSQRT_IMPL(DIVSQRT_IMPL),
    .OPS_EN(OPS_EN), .TUSER_W(TUSER_W), .DEPTH(DEPTH)
  ) u_fp_unit_axis (
    .aclk(aclk), .aresetn(aresetn),
    .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
    .s_axis_tdata(s_axis_tdata), .s_axis_tuser(s_axis_tuser), .s_axis_tlast(s_axis_tlast),
    .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready),
    .m_axis_tdata(m_axis_tdata), .m_axis_tuser(m_axis_tuser), .m_axis_tlast(m_axis_tlast)
  );

endmodule
