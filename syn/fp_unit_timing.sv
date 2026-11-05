// Copyright 2026 Jesse Smedberg
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Out-of-context timing wrapper for jsm_fp_unit (Vivado implementation runs).
//
// Registers every jsm_fp_unit input once and every output once, so the timed
// paths are register-to-register inside the design (no unconstrained
// input/output port paths in an OOC run). rst_n is passed straight through
// (jsm_fp_unit uses it synchronously). Used by syn/vivado-impl.tcl.

module fp_unit_timing #(
  parameter int W_EXP        = 8,
  parameter int W_MANT       = 23,
  parameter int DIVSQRT_IMPL = 1,
  parameter int TAG_W        = 1
) (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    in_valid,
  output logic                    in_ready,
  input  jsm_fp_pkg::op_t             mode,
  input  jsm_fp_pkg::rounding_t       rm,
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
  input  logic [1+W_EXP+W_MANT-1:0] c,
  input  logic [TAG_W-1:0]        in_tag,
  output logic [1+W_EXP+W_MANT-1:0] y,
  output logic [1:0]               cmp,
  output logic [4:0]               flags,
  output logic                    out_valid,
  output logic [TAG_W-1:0]        out_tag
);

  localparam int W = 1 + W_EXP + W_MANT;

  logic              in_valid_q;
  jsm_fp_pkg::op_t       mode_q;
  jsm_fp_pkg::rounding_t rm_q;
  logic [W-1:0]      a_q, b_q, c_q;
  logic [TAG_W-1:0]  in_tag_q;

  logic              in_ready_d, out_valid_d;
  logic [W-1:0]      y_d;
  logic [1:0]        cmp_d;
  logic [4:0]        flags_d;
  logic [TAG_W-1:0]  out_tag_d;

  always_ff @(posedge clk) begin
    in_valid_q <= in_valid;
    mode_q     <= mode;
    rm_q       <= rm;
    a_q        <= a;
    b_q        <= b;
    c_q        <= c;
    in_tag_q   <= in_tag;
    in_ready   <= in_ready_d;
    y          <= y_d;
    cmp        <= cmp_d;
    flags      <= flags_d;
    out_valid  <= out_valid_d;
    out_tag    <= out_tag_d;
  end

  jsm_fp_unit #(.W_EXP(W_EXP), .W_MANT(W_MANT), .DIVSQRT_IMPL(DIVSQRT_IMPL), .TAG_W(TAG_W)) u_fp_unit (
    .clk(clk), .rst_n(rst_n),
    .in_valid(in_valid_q), .in_ready(in_ready_d),
    .mode(mode_q), .rm(rm_q), .a(a_q), .b(b_q), .c(c_q), .in_tag(in_tag_q),
    .y(y_d), .cmp(cmp_d), .flags(flags_d), .out_valid(out_valid_d), .out_tag(out_tag_d)
  );

endmodule
