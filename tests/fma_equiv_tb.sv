// Copyright 2026 Jesse Smedberg
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Simulation top for tests/fma_equiv.py: the pipelined FMA (jsm_fp_fma_pipe)
// and the combinational reference (jsm_fp_fma) on the same inputs. The C++
// harness (tests/fma_equiv_main.cpp) samples the reference when it applies a
// vector and compares it with the pipeline output LAT cycles later.

module fma_equiv_tb #(
  parameter int W_EXP  = 4,
  parameter int W_MANT = 3
) (
  input  logic                      clk,
  input  logic                      rst_n,
  input  logic                      start,
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
  input  logic [1+W_EXP+W_MANT-1:0] c,
  input  logic [2:0]                rm,
  output logic [1+W_EXP+W_MANT-1:0] y_p,
  output logic [4:0]                f_p,
  output logic                      v_p,
  output logic [1+W_EXP+W_MANT-1:0] y_c,
  output logic [4:0]                f_c
);

  jsm_fp_fma_pipe #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_pipe (
    .a(a), .b(b), .c(c), .rm(jsm_fp_pkg::rounding_t'(rm)),
    .clk(clk), .rst_n(rst_n), .start(start),
    .y(y_p), .flags(f_p), .out_valid(v_p));

  jsm_fp_fma #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_ref (
    .a(a), .b(b), .c(c), .rm(jsm_fp_pkg::rounding_t'(rm)),
    .y(y_c), .flags(f_c));

endmodule
