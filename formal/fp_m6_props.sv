// Formal property checks for the M6 datapaths: quiet comparison (5.11),
// totalOrder (5.10) and roundToIntegral (5.9), cross-checked against the
// 5.6.1 minimum/maximum ordering.
//
// Proven with SymbiYosys (sby) BMC. The datapaths are combinational, so with
// the operand and rounding-mode inputs left free a depth-0 BMC run proves each
// property for EVERY (a, b, c, rm) of the format -- including the 2^32
// binary16 operand pairs that are infeasible to enumerate exhaustively.
//
// The properties are width-independent; they are checked at the binary16 and
// E4M3 formats (see the concrete *_b16 / *_e4m3 wrapper modules below and the
// .sby configs in this directory).

module fp_m6_props #(
  parameter int W_EXP  = 5,
  parameter int W_MANT = 10
) (
  input logic [1+W_EXP+W_MANT-1:0] a,
  input logic [1+W_EXP+W_MANT-1:0] b,
  input logic [1+W_EXP+W_MANT-1:0] c,   // only for the totalOrder transitivity chain
  input fp_pkg::rounding_t         rm
);

  localparam int W = 1 + W_EXP + W_MANT;
  localparam int EXP_ALL = (1 << W_EXP) - 1;
  localparam logic [W_MANT-1:0] QUIET = (W_MANT)'(1) << (W_MANT - 1);

  // ------------------------------------------------------------- classification
  logic [W_EXP-1:0]  a_exp, b_exp;
  logic [W_MANT-1:0] a_mant, b_mant;
  assign a_exp  = a[W-2 -: W_EXP];
  assign b_exp  = b[W-2 -: W_EXP];
  assign a_mant = a[W_MANT-1:0];
  assign b_mant = b[W_MANT-1:0];
  logic a_nan, a_snan, a_inf, a_zero;
  logic b_nan, b_snan, b_inf, b_zero;
  assign a_nan  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant != '0);
  assign a_snan = a_nan && !a_mant[W_MANT-1];
  assign a_inf  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant == '0);
  assign a_zero = (a_exp == '0) && (a_mant == '0);
  assign b_nan  = (b_exp == EXP_ALL[W_EXP-1:0]) && (b_mant != '0);
  assign b_snan = b_nan && !b_mant[W_MANT-1];
  assign b_inf  = (b_exp == EXP_ALL[W_EXP-1:0]) && (b_mant == '0);
  assign b_zero = (b_exp == '0) && (b_mant == '0);

  // ------------------------------------------------- quiet comparison (5.11)
  logic [W-1:0] cmp_y_ab, cmp_y_ba;
  logic [1:0]   cmp_ab, cmp_ba;
  logic [4:0]   cmp_f_ab, cmp_f_ba;
  fp_cmp #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_cmp_ab (
    .a(a), .b(b), .rm(rm), .y(cmp_y_ab), .cmp(cmp_ab), .flags(cmp_f_ab));
  fp_cmp #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_cmp_ba (
    .a(b), .b(a), .rm(rm), .y(cmp_y_ba), .cmp(cmp_ba), .flags(cmp_f_ba));

  // LT/GT are antisymmetric; EQ and UN are symmetric.
  assert property ((cmp_ab == fp_pkg::CMP_LT) == (cmp_ba == fp_pkg::CMP_GT));
  assert property ((cmp_ab == fp_pkg::CMP_EQ) == (cmp_ba == fp_pkg::CMP_EQ));
  assert property ((cmp_ab == fp_pkg::CMP_UN) == (cmp_ba == fp_pkg::CMP_UN));
  // A NaN operand compares unordered, and only that.
  assert property ((a_nan || b_nan) == (cmp_ab == fp_pkg::CMP_UN));
  // Zeros (both signs) compare equal.
  assert property (!(a_zero && b_zero) || (cmp_ab == fp_pkg::CMP_EQ));
  // A quiet comparison signals invalid exactly for a signaling NaN operand.
  assert property (cmp_f_ab[fp_pkg::FLAG_INVALID] == (a_snan || b_snan));
  assert property (cmp_f_ab == cmp_f_ba);

  // ------------------------------------------------------- totalOrder (5.10)
  logic [1:0] t_ab, t_ba, t_bc, t_ac, t_aa;
  logic [W-1:0] t_y [5];
  logic [4:0]   t_f [5];
  fp_totalorder #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_t_ab (
    .a(a), .b(b), .rm(rm), .y(t_y[0]), .cmp(t_ab), .flags(t_f[0]));
  fp_totalorder #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_t_ba (
    .a(b), .b(a), .rm(rm), .y(t_y[1]), .cmp(t_ba), .flags(t_f[1]));
  fp_totalorder #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_t_bc (
    .a(b), .b(c), .rm(rm), .y(t_y[2]), .cmp(t_bc), .flags(t_f[2]));
  fp_totalorder #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_t_ac (
    .a(a), .b(c), .rm(rm), .y(t_y[3]), .cmp(t_ac), .flags(t_f[3]));
  fp_totalorder #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_t_aa (
    .a(a), .b(a), .rm(rm), .y(t_y[4]), .cmp(t_aa), .flags(t_f[4]));

  // Reflexive: totalOrder(x, x) is true (non-strict order).
  assert property (t_aa[0]);
  // Total: at least one of a <= b, b <= a.
  assert property (t_ab[0] | t_ba[0]);
  // Antisymmetric up to the encoding (key is a bijection).
  assert property (!(t_ab[0] && t_ba[0]) || (a == b));
  // Transitive.
  assert property (!(t_ab[0] && t_bc[0]) || t_ac[0]);
  // -0 precedes +0 (the one place totalOrder disagrees with numeric order).
  assert property (!(a_zero && b_zero && a[W-1] && ~b[W-1]) || (t_ab[0] && ~t_ba[0]));
  // Agreement with the numeric comparison: LT implies a precedes b.
  assert property ((cmp_ab != fp_pkg::CMP_LT) || (t_ab[0] && ~t_ba[0]));

  // -------------------------------------------------- roundToIntegral (5.9)
  logic [W-1:0] r_y, r_y2;
  logic [4:0]   r_f, r_f2;
  fp_roundint #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_r (
    .a(a), .rm(rm), .y(r_y), .flags(r_f));
  fp_roundint #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_r2 (
    .a(r_y), .rm(rm), .y(r_y2), .flags(r_f2));

  // Idempotent: rnd(rnd(x)) == rnd(x).
  assert property (r_y == r_y2);
  // The result sign equals the operand sign (incl. NaN and zero results).
  assert property (r_y[W-1] == a[W-1]);
  // Zero and infinity are returned unchanged.
  assert property (!a_zero || (r_y == a));
  assert property (!a_inf || (r_y == a));
  // A NaN is quieted with the sign and payload preserved (5.9).
  assert property (!a_nan || (r_y == {a[W-1], EXP_ALL[W_EXP-1:0], a_mant | QUIET}));
  assert property (r_f[fp_pkg::FLAG_INVALID] == a_snan);
  // roundToIntegral never signals inexact (only roundToIntegralExact does).
  assert property (r_f[fp_pkg::FLAG_INEXACT] == 1'b0);

  // ------------------------------------------ min/max cross-check (5.6.1)
  logic [W-1:0] mm_y, mx_y;
  logic [4:0]   mm_f, mx_f;
  fp_minmax #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_mm (
    .a(a), .b(b), .is_max(1'b0), .rm(rm), .y(mm_y), .flags(mm_f));
  fp_minmax #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_mx (
    .a(a), .b(b), .is_max(1'b1), .rm(rm), .y(mx_y), .flags(mx_f));

  // For non-NaN operands the comparison agrees with min/max.
  assert property ((a_nan || b_nan || (cmp_ab != fp_pkg::CMP_LT)) ||
                   (mm_y == a && mx_y == b));
  assert property ((a_nan || b_nan || (cmp_ab != fp_pkg::CMP_GT)) ||
                   (mm_y == b && mx_y == a));

endmodule

// Concrete binary16 and E4M3 top-level wrappers (sby runs each separately).
module fp_m6_props_b16 (
  input logic [15:0] a, b, c,
  input fp_pkg::rounding_t rm
);
  fp_m6_props #(.W_EXP(5), .W_MANT(10)) u (a, b, c, rm);
endmodule

module fp_m6_props_e4m3 (
  input logic [7:0] a, b, c,
  input fp_pkg::rounding_t rm
);
  fp_m6_props #(.W_EXP(4), .W_MANT(3)) u (a, b, c, rm);
endmodule
