// Formal property checks for the arithmetic datapaths: addition/subtraction
// (5.4.1), multiplication (5.4.1), fused multiply-add (5.4.1) and square
// root (5.4.1), at a parameterized width.
//
// STATUS: these properties are the intended formal specification for the
// arithmetic ops, but they CANNOT currently be proven with the oss-cad-suite
// yosys 0.68: its write_smt2 step produces a corrupt SMT model when several
// instances of the parameterized datapath modules coexist (a spurious
// counterexample such as add(7.5, -0.117) and add(-0.117, 7.5) getting
// different flags, contradicting the exhaustive-verified RTL). Retained for
// a future yosys; the RTL itself is verified bit-exact by the regression and
// the exhaustive sweep.
//
// Proven with SymbiYosys (sby) BMC, depth 1 over free a/b/c/rm inputs: every
// property would then hold for ALL operand pairs of the format, including the
// 2^32 binary16 (a, b) pairs that the exhaustive 8-bit sweep cannot reach.
//
// The properties are algebraic laws that the IEEE semantics guarantee:
//   add/mul are commutative (exactly, including flags),
//   a + 0 == a and a * 1 == a (a signaling NaN is quieted instead),
//   a + (-a) == +-0 per roundTowardNegative (6.3) for finite a,
//   a * 0 == +-0 with a's sign for finite a (6.3),
//   OP_SUB is OP_ADD with b's sign flipped,
//   fma(a, b, 0) == mul(a, b) and fma(a, 1, c) == add(a, c),
//   fma is commutative in a, b unless both operands are NaN,
//   sqrt never produces a negative result (except sqrt(-0) == -0).

module fp_arith_props #(
  parameter int W_EXP  = 5,
  parameter int W_MANT = 10
) (
  input logic [1+W_EXP+W_MANT-1:0] a,
  input logic [1+W_EXP+W_MANT-1:0] b,
  input logic [1+W_EXP+W_MANT-1:0] c,
  input fp_pkg::rounding_t         rm
);

  localparam int W = 1 + W_EXP + W_MANT;
  localparam int BIAS = (1 << (W_EXP-1)) - 1;
  localparam int EXP_ALL = (1 << W_EXP) - 1;
  localparam logic [W-1:0] ONE  = (W)'(BIAS) << W_MANT;         // 1.0
  localparam logic [W-1:0] ZERO = '0;                            // +0
  localparam logic [W-1:0] SIGN = (W)'(1) << (W-1);              // sign bit
  localparam logic [W-1:0] NZERO = {1'b1, {W-1{1'b0}}};          // -0
  localparam logic [W-1:0] NEG0RM = (W)'({1'b1, {W-1{1'b0}}});   // -0 (RM result)

  // ------------------------------------------------------------- classification
  logic [W_EXP-1:0]  a_exp, b_exp;
  logic [W_MANT-1:0] a_mant, b_mant;
  assign a_exp  = a[W-2 -: W_EXP];
  assign b_exp  = b[W-2 -: W_EXP];
  assign a_mant = a[W_MANT-1:0];
  assign b_mant = b[W_MANT-1:0];
  logic a_nan, a_snan, a_inf, a_zero, a_negzero;
  logic b_nan, b_snan, b_inf, b_zero;
  assign a_nan     = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant != '0);
  assign a_snan    = a_nan && !a_mant[W_MANT-1];
  assign a_inf     = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant == '0);
  assign a_zero    = (a_exp == '0) && (a_mant == '0);
  assign a_negzero = a[W-1] && a_zero;
  assign b_nan     = (b_exp == EXP_ALL[W_EXP-1:0]) && (b_mant != '0);
  assign b_snan    = b_nan && !b_mant[W_MANT-1];
  assign b_inf     = (b_exp == EXP_ALL[W_EXP-1:0]) && (b_mant == '0);
  assign b_zero    = (b_exp == '0) && (b_mant == '0);

  // ----------------------------------------------------- addition (5.4.1)
  logic [W-1:0] y_ab, y_ba, y0, yc, y_sub, y_nb, y_ac;
  logic [4:0]   f_ab, f_ba, f0, fc, f_sub, f_nb, f_ac;
  fp_add #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_ab (
    .a(a), .b(b), .rm(rm), .op(fp_pkg::OP_ADD), .y(y_ab), .flags(f_ab));
  fp_add #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_ba (
    .a(b), .b(a), .rm(rm), .op(fp_pkg::OP_ADD), .y(y_ba), .flags(f_ba));
  fp_add #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_a0 (
    .a(a), .b(ZERO), .rm(rm), .op(fp_pkg::OP_ADD), .y(y0), .flags(f0));
  fp_add #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_an (
    .a(a), .b(a ^ SIGN), .rm(rm), .op(fp_pkg::OP_ADD), .y(yc), .flags(fc));
  fp_add #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_sub (
    .a(a), .b(b), .rm(rm), .op(fp_pkg::OP_SUB), .y(y_sub), .flags(f_sub));
  fp_add #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_nb (
    .a(a), .b(b ^ SIGN), .rm(rm), .op(fp_pkg::OP_ADD), .y(y_nb), .flags(f_nb));
  fp_add #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_ac (
    .a(a), .b(c), .rm(rm), .op(fp_pkg::OP_ADD), .y(y_ac), .flags(f_ac));

  // Commutative (exactly, including flags).
  assert property (y_ab == y_ba);
  assert property (f_ab == f_ba);
  // a + +0 == a (a signaling NaN is quieted instead).
  assert property (a_snan || (y0 == a && f0 == 5'd0));
  // a + (-a) == +-0 per roundTowardNegative (6.3) for finite a.
  assert property ((a_nan || a_inf) ||
                   (yc == ((rm == fp_pkg::RM_RM) ? NZERO : ZERO) && fc == 5'd0));
  // OP_SUB is OP_ADD with b's effective sign flipped.
  assert property (y_sub == y_nb && f_sub == f_nb);

  // ------------------------------------------------- multiplication (5.4.1)
  logic [W-1:0] y_mab, y_mba, y_m1, y_m0;
  logic [4:0]   f_mab, f_mba, f_m1, f_m0;
  fp_mul #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_mab (
    .a(a), .b(b), .rm(rm), .y(y_mab), .flags(f_mab));
  fp_mul #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_mba (
    .a(b), .b(a), .rm(rm), .y(y_mba), .flags(f_mba));
  fp_mul #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_m1 (
    .a(a), .b(ONE), .rm(rm), .y(y_m1), .flags(f_m1));
  fp_mul #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_m0 (
    .a(a), .b(ZERO), .rm(rm), .y(y_m0), .flags(f_m0));

  // Commutative (exactly, including flags).
  assert property (y_mab == y_mba && f_mab == f_mba);
  // a * 1.0 == a (a signaling NaN is quieted instead).
  assert property (a_snan || (y_m1 == a && f_m1 == 5'd0));
  // a * +0 == +-0 with a's sign for finite a (6.3).
  assert property ((a_nan || a_inf) ||
                   (y_m0 == {a[W-1], {W-1{1'b0}}} && f_m0 == 5'd0));

  // --------------------------------------------- fused multiply-add (5.4.1)
  logic [W-1:0] y_f0, y_f1, y_fab, y_fba;
  logic [4:0]   f_f0, f_f1, f_fab, f_fba;
  fp_fma #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_f0 (
    .a(a), .b(b), .c(ZERO), .rm(rm), .y(y_f0), .flags(f_f0));
  fp_fma #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_f1 (
    .a(a), .b(ONE), .c(c), .rm(rm), .y(y_f1), .flags(f_f1));
  fp_fma #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fab (
    .a(a), .b(b), .c(c), .rm(rm), .y(y_fab), .flags(f_fab));
  fp_fma #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fba (
    .a(b), .b(a), .c(c), .rm(rm), .y(y_fba), .flags(f_fba));

  // fma(a, b, +0) == mul(a, b).
  assert property (y_f0 == y_mab && f_f0 == f_mab);
  // fma(a, 1.0, c) == add(a, c).
  assert property (y_f1 == y_ac && f_f1 == f_ac);
  // Commutative in a, b unless both operands are NaN (payload of the first).
  assert property ((a_nan && b_nan) || (y_fab == y_fba && f_fab == f_fba));

  // ----------------------------------------------------- square root (5.4.1)
  logic [W-1:0] y_s;
  logic [4:0]   f_s;
  fp_sqrt #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_sqrt (
    .a(a), .rm(rm), .y(y_s), .flags(f_s));

  // sqrt never yields a negative result, except sqrt(-0) == -0 (6.3).
  assert property (a_negzero || (y_s[W-1] == 1'b0));

endmodule

// Concrete top-level wrappers (sby runs each separately).
module fp_arith_props_b16 (
  input logic [15:0] a, b, c,
  input fp_pkg::rounding_t rm
);
  fp_arith_props #(.W_EXP(5), .W_MANT(10)) u (a, b, c, rm);
endmodule

module fp_arith_props_e4m3 (
  input logic [7:0] a, b, c,
  input fp_pkg::rounding_t rm
);
  fp_arith_props #(.W_EXP(4), .W_MANT(3)) u (a, b, c, rm);
endmodule
