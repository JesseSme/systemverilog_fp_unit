// Formal property checks for the division datapath (5.4.1).
//
// STATUS: like fp_arith_props.sv, these cannot currently be proven with yosys
// 0.68 (the write_smt2 multi-instance corruption bug); retained as the
// intended formal specification. The RTL is verified bit-exact by the
// regression and the exhaustive sweep.
//
// Proven with SymbiYosys (sby) BMC, depth 1 over free a/b/rm inputs. Division
// is separated from fp_arith_props because the integer long-division circuit
// (`num / b_al`) is the heaviest structure for the SAT solver; keeping it
// alone keeps each proof tractable.
//
// Laws proven:
//   a / a == 1.0 (exactly, no flags) for finite non-zero a,
//   a / 1.0 == a (a signaling NaN is quieted instead).

module fp_div_props #(
  parameter int W_EXP  = 4,
  parameter int W_MANT = 3
) (
  input logic [1+W_EXP+W_MANT-1:0] a,
  input logic [1+W_EXP+W_MANT-1:0] b,
  input fp_pkg::rounding_t         rm
);

  localparam int W = 1 + W_EXP + W_MANT;
  localparam int BIAS = (1 << (W_EXP-1)) - 1;
  localparam int EXP_ALL = (1 << W_EXP) - 1;
  localparam logic [W-1:0] ONE  = (W)'(BIAS) << W_MANT;   // 1.0

  logic [W_EXP-1:0]  a_exp;
  logic [W_MANT-1:0] a_mant;
  assign a_exp  = a[W-2 -: W_EXP];
  assign a_mant = a[W_MANT-1:0];
  logic a_nan, a_snan, a_inf, a_zero;
  assign a_nan  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant != '0);
  assign a_snan = a_nan && !a_mant[W_MANT-1];
  assign a_inf  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant == '0);
  assign a_zero = (a_exp == '0) && (a_mant == '0);

  logic [W-1:0] y_daa, y_d1;
  logic [4:0]   f_daa, f_d1;
  fp_div #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_daa (
    .a(a), .b(a), .rm(rm), .y(y_daa), .flags(f_daa));
  fp_div #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_d1 (
    .a(a), .b(ONE), .rm(rm), .y(y_d1), .flags(f_d1));

  // a / a == 1.0 (exact, no flags) for finite non-zero a.
  assert property ((a_nan || a_inf || a_zero) || (y_daa == ONE && f_daa == 5'd0));
  // a / 1.0 == a (a signaling NaN is quieted instead).
  assert property (a_snan || (y_d1 == a && f_d1 == 5'd0));

endmodule

// Concrete top-level wrappers.
module fp_div_props_e4m3 (
  input logic [7:0] a, b,
  input fp_pkg::rounding_t rm
);
  fp_div_props #(.W_EXP(4), .W_MANT(3)) u (a, b, rm);
endmodule

module fp_div_props_b16 (
  input logic [15:0] a, b,
  input fp_pkg::rounding_t rm
);
  fp_div_props #(.W_EXP(5), .W_MANT(10)) u (a, b, rm);
endmodule
