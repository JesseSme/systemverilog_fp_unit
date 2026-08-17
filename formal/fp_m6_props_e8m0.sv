// Formal property checks for the E8M0 (W_MANT = 0) M6 datapaths: the
// dedicated roundToIntegral (5.9) plus the format-generic quiet comparison
// (5.11) and totalOrder (5.10) at a microscaling width. E7M0 is used here.
//
// Proven with SymbiYosys (sby) BMC, depth 0 (combinational, free inputs), so
// each property holds for every (a, b, rm) of the format.

module fp_m6_props_e8m0 #(
  parameter int W_EXP = 7
) (
  input logic [W_EXP:0]    a,
  input logic [W_EXP:0]    b,
  input fp_pkg::rounding_t rm
);

  localparam int EXP_ALL = (1 << W_EXP) - 1;
  localparam int BIAS    = (1 << (W_EXP-1)) - 1;

  logic a_zero, a_inf, b_zero;
  assign a_zero = (a[W_EXP-1:0] == '0);
  assign a_inf  = (a[W_EXP-1:0] == EXP_ALL[W_EXP-1:0]);
  assign b_zero = (b[W_EXP-1:0] == '0);

  // ---------------------------------------------- roundToIntegral (5.9)
  logic [W_EXP:0] r_y, r_y2;
  logic [4:0]     r_f, r_f2;
  fp_roundint_e8m0 #(.W_EXP(W_EXP)) u_r  (.a(a), .rm(rm), .y(r_y), .flags(r_f));
  fp_roundint_e8m0 #(.W_EXP(W_EXP)) u_r2 (.a(r_y), .rm(rm), .y(r_y2), .flags(r_f2));

  // Idempotent.
  assert property (r_y == r_y2);
  // Sign preserved (incl. zero results).
  assert property (r_y[W_EXP] == a[W_EXP]);
  // Never signals (no inexact, no overflow in this format).
  assert property (r_f == 5'd0);
  // Zero and infinity unchanged.
  assert property (!a_zero || (r_y == a));
  assert property (!a_inf || (r_y == a));
  // Integral powers of two (2^e with e >= 0) are returned unchanged.
  assert property (!((a[W_EXP-1:0] >= BIAS[W_EXP-1:0]) || a_zero || a_inf) || (r_y == a));

  // ------------------------------------------ quiet comparison (5.11)
  logic [W_EXP:0] cmp_y_ab, cmp_y_ba;
  logic [1:0]     cmp_ab, cmp_ba;
  logic [4:0]     cmp_f_ab, cmp_f_ba;
  fp_cmp #(.W_EXP(W_EXP), .W_MANT(0)) u_cmp_ab (
    .a(a), .b(b), .rm(rm), .y(cmp_y_ab), .cmp(cmp_ab), .flags(cmp_f_ab));
  fp_cmp #(.W_EXP(W_EXP), .W_MANT(0)) u_cmp_ba (
    .a(b), .b(a), .rm(rm), .y(cmp_y_ba), .cmp(cmp_ba), .flags(cmp_f_ba));

  // No NaN encodings: never unordered, never invalid.
  assert property (cmp_ab != fp_pkg::CMP_UN);
  assert property (cmp_f_ab == 5'd0);
  // LT/GT antisymmetric, EQ symmetric.
  assert property ((cmp_ab == fp_pkg::CMP_LT) == (cmp_ba == fp_pkg::CMP_GT));
  assert property ((cmp_ab == fp_pkg::CMP_EQ) == (cmp_ba == fp_pkg::CMP_EQ));
  // Zeros (both signs) compare equal.
  assert property (!(a_zero && b_zero) || (cmp_ab == fp_pkg::CMP_EQ));

  // ------------------------------------------------ totalOrder (5.10)
  logic [1:0] t_ab, t_ba, t_aa;
  logic [W_EXP:0] t_y [3];
  logic [4:0]     t_f [3];
  fp_totalorder #(.W_EXP(W_EXP), .W_MANT(0)) u_t_ab (
    .a(a), .b(b), .rm(rm), .y(t_y[0]), .cmp(t_ab), .flags(t_f[0]));
  fp_totalorder #(.W_EXP(W_EXP), .W_MANT(0)) u_t_ba (
    .a(b), .b(a), .rm(rm), .y(t_y[1]), .cmp(t_ba), .flags(t_f[1]));
  fp_totalorder #(.W_EXP(W_EXP), .W_MANT(0)) u_t_aa (
    .a(a), .b(a), .rm(rm), .y(t_y[2]), .cmp(t_aa), .flags(t_f[2]));

  // Reflexive, total, antisymmetric-up-to-encoding.
  assert property (t_aa[0]);
  assert property (t_ab[0] | t_ba[0]);
  assert property (!(t_ab[0] && t_ba[0]) || (a == b));
  // -0 precedes +0.
  assert property (!(a_zero && b_zero && a[W_EXP] && ~b[W_EXP]) || (t_ab[0] && ~t_ba[0]));
  // LT implies totalOrder order.
  assert property ((cmp_ab != fp_pkg::CMP_LT) || (t_ab[0] && ~t_ba[0]));

endmodule

// Concrete E7M0 top-level wrapper.
module fp_m6_props_e7m0 (
  input logic [7:0] a, b,
  input fp_pkg::rounding_t rm
);
  fp_m6_props_e8m0 #(.W_EXP(7)) u (a, b, rm);
endmodule
