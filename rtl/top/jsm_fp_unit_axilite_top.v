// Copyright 2026 Jesse Smedberg
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Verilog-2001 top-level wrapper of the AXI4-Lite floating-point unit
// (jsm_fp_unit_axilite).
//
// Plain Verilog ports and integer parameters only, so this file can be the
// top of a Vivado project, a block-design module reference (the S_AXI
// interface, its clock and its reset are declared with X_INTERFACE
// attributes, so IP integrator connects them as one AXI4-Lite slave), or a
// component instantiated from VHDL (see jsm_fp_unit_axilite_vhd.vhd). Add the
// SystemVerilog core files (rtl/filelist.f) and rtl/jsm_fp_unit_axilite.sv to
// the project as well.
//
// Register map (32-bit registers, offsets for formats up to 32 bits wide;
// docs/user_guide.md gives the general layout for wider formats):
//   0x00 CTRL     [0] GO (rising edge starts), [1] CLR (holds VALID clear)
//   0x04 OPCODE   [3:0] opcode, [6:4] rounding mode
//   0x08 DATA_A   0x0C DATA_B   0x10 DATA_C (FMA addend)
//   0x14 STATUS   [4:0] flags, [8] BUSY, [9] VALID, [31:16] {W_MANT, W_EXP}
//   0x18 RESULT   0x1C RES_CMP [1:0]
//
// Parameters:
//   W_EXP, W_MANT  format (see jsm_fp_unit_top.v)
//   ADDR_WIDTH     AXI address width (>= 5 for W <= 32, >= 6 for W <= 64;
//                  checked at elaboration)
//   DIVSQRT_IMPL   see jsm_fp_unit_top.v

module jsm_fp_unit_axilite_top #(
  parameter integer W_EXP        = 8,
  parameter integer W_MANT       = 23,
  parameter integer ADDR_WIDTH   = 6,
  parameter integer DIVSQRT_IMPL = 1
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET s_axi_aresetn" *)
  input  wire                  s_axi_aclk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                  s_axi_aresetn,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
  (* X_INTERFACE_PARAMETER = "PROTOCOL AXI4LITE, DATA_WIDTH 32" *)
  input  wire [ADDR_WIDTH-1:0] s_axi_awaddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
  input  wire                  s_axi_awvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
  output wire                  s_axi_awready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
  input  wire [31:0]           s_axi_wdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
  input  wire [3:0]            s_axi_wstrb,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
  input  wire                  s_axi_wvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
  output wire                  s_axi_wready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
  output wire [1:0]            s_axi_bresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
  output wire                  s_axi_bvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
  input  wire                  s_axi_bready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
  input  wire [ADDR_WIDTH-1:0] s_axi_araddr,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
  input  wire                  s_axi_arvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
  output wire                  s_axi_arready,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
  output wire [31:0]           s_axi_rdata,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
  output wire [1:0]            s_axi_rresp,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
  output wire                  s_axi_rvalid,
  (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
  input  wire                  s_axi_rready
);

  jsm_fp_unit_axilite #(
    .W_EXP(W_EXP), .W_MANT(W_MANT), .ADDR_WIDTH(ADDR_WIDTH),
    .DIVSQRT_IMPL(DIVSQRT_IMPL)
  ) u_fp_unit_axilite (
    .s_axi_aclk(s_axi_aclk), .s_axi_aresetn(s_axi_aresetn),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready)
  );

endmodule
