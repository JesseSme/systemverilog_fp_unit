// Copyright 2026 Jesse Smedberg
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Formal equivalence of a pipelined datapath against its combinational
// reference (plan P4.3): the same a/b/rm/op stream drives jsm_fp_add_pipe (or
// jsm_fp_mul_pipe) and jsm_fp_add (jsm_fp_mul); the reference result is delayed by the
// pipeline latency and must equal the pipeline's output whenever out_valid
// is high, and out_valid must track the delayed start exactly.
//
// All inputs are free every cycle (start can be asserted every cycle), so a
// BMC of depth LAT + 2 covers every operand combination entering the pipe in
// the first cycle after reset and checks it at the output, with the other
// stages holding arbitrary in-flight operations.
//
//   OP_SEL = 0: jsm_fp_add_pipe vs jsm_fp_add (ADD and SUB through `op`)
//   OP_SEL = 1: jsm_fp_mul_pipe vs jsm_fp_mul

module fp_pipe_equiv #(
  parameter int W_EXP  = 5,
  parameter int W_MANT = 10,
  parameter int OP_SEL = 0
) (
  input logic                      clk,
  input logic                      rst_n,
  input logic                      start,
  input logic [1+W_EXP+W_MANT-1:0] a,
  input logic [1+W_EXP+W_MANT-1:0] b,
  input jsm_fp_pkg::rounding_t         rm,
  input logic                      sub
);

  localparam int W   = 1 + W_EXP + W_MANT;
  localparam int LAT = (OP_SEL == 0) ? jsm_fp_pkg::LAT_ADD : jsm_fp_pkg::lat_mul(W_MANT);

  // the datapaths are only defined for the five rounding modes
  always_comb assume (rm <= jsm_fp_pkg::RM_RM);

  // reset in the first cycle
  logic init = 1'b1;
  always_ff @(posedge clk) init <= 1'b0;
  always_comb if (init) assume (!rst_n);

  jsm_fp_pkg::op_t op;
  assign op = sub ? jsm_fp_pkg::OP_SUB : jsm_fp_pkg::OP_ADD;

  logic [W-1:0] y_p, y_c;
  logic [4:0]   f_p, f_c;
  logic         v_p;

  if (OP_SEL == 0) begin : g_add
    jsm_fp_add_pipe #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_pipe (
      .a(a), .b(b), .rm(rm), .op(op), .clk(clk), .rst_n(rst_n), .start(start),
      .y(y_p), .flags(f_p), .out_valid(v_p));
    jsm_fp_add #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_ref (
      .a(a), .b(b), .rm(rm), .op(op), .y(y_c), .flags(f_c));
  end else begin : g_mul
    jsm_fp_mul_pipe #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_pipe (
      .a(a), .b(b), .rm(rm), .clk(clk), .rst_n(rst_n), .start(start),
      .y(y_p), .flags(f_p), .out_valid(v_p));
    jsm_fp_mul #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_ref (
      .a(a), .b(b), .rm(rm), .y(y_c), .flags(f_c));
  end

  // reference delay line
  logic [W-1:0] y_d [0:LAT-1];
  logic [4:0]   f_d [0:LAT-1];
  logic         v_d [0:LAT-1];
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < LAT; i++) v_d[i] <= 1'b0;
    end else begin
      v_d[0] <= start;
      for (int i = 1; i < LAT; i++) v_d[i] <= v_d[i-1];
    end
    y_d[0] <= y_c;
    f_d[0] <= f_c;
    for (int i = 1; i < LAT; i++) begin
      y_d[i] <= y_d[i-1];
      f_d[i] <= f_d[i-1];
    end
  end

  always_comb begin
    if (!init) begin
      assert (v_p == v_d[LAT-1]);
      if (v_p) begin
        assert (y_p == y_d[LAT-1]);
        assert (f_p == f_d[LAT-1]);
      end
    end
  end

endmodule

module fp_pipe_equiv_add_e4m3 (input logic clk, rst_n, start, sub,
                               input logic [7:0] a, b, input jsm_fp_pkg::rounding_t rm);
  fp_pipe_equiv #(.W_EXP(4), .W_MANT(3), .OP_SEL(0)) u (.*);
endmodule

module fp_pipe_equiv_mul_e4m3 (input logic clk, rst_n, start, sub,
                               input logic [7:0] a, b, input jsm_fp_pkg::rounding_t rm);
  fp_pipe_equiv #(.W_EXP(4), .W_MANT(3), .OP_SEL(1)) u (.*);
endmodule

module fp_pipe_equiv_add_b16 (input logic clk, rst_n, start, sub,
                              input logic [15:0] a, b, input jsm_fp_pkg::rounding_t rm);
  fp_pipe_equiv #(.W_EXP(5), .W_MANT(10), .OP_SEL(0)) u (.*);
endmodule

module fp_pipe_equiv_mul_b16 (input logic clk, rst_n, start, sub,
                              input logic [15:0] a, b, input jsm_fp_pkg::rounding_t rm);
  fp_pipe_equiv #(.W_EXP(5), .W_MANT(10), .OP_SEL(1)) u (.*);
endmodule

module fp_pipe_equiv_add_bf16 (input logic clk, rst_n, start, sub,
                               input logic [15:0] a, b, input jsm_fp_pkg::rounding_t rm);
  fp_pipe_equiv #(.W_EXP(8), .W_MANT(7), .OP_SEL(0)) u (.*);
endmodule

module fp_pipe_equiv_mul_bf16 (input logic clk, rst_n, start, sub,
                               input logic [15:0] a, b, input jsm_fp_pkg::rounding_t rm);
  fp_pipe_equiv #(.W_EXP(8), .W_MANT(7), .OP_SEL(1)) u (.*);
endmodule
