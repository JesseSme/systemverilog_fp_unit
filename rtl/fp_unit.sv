// IEEE 754-2019 floating-point unit top level.
//
// Combinational, parameterized by the format: W_EXP exponent bits and W_MANT
// fraction bits (3.3, 3.7 "extendable precision"). Decodes the operation
// select and drives the per-operation datapaths (added incrementally per the
// project plan; add/sub, mul, div, sqrt, fma, min/max, and M6 comparisons /
// roundToIntegral / totalOrder all implemented). OP_MUL selects the multiply
// datapaths (fp_mul/fp_mul_e8m0), OP_DIV the divide datapaths
// (fp_div/fp_div_e8m0), OP_SQRT the square-root datapaths
// (fp_sqrt/fp_sqrt_e8m0), OP_FMA the fused multiply-add datapaths
// (fp_fma/fp_fma_e8m0), OP_MIN/OP_MAX the min/max datapath (fp_minmax,
// format-generic), OP_CMP the comparison datapath (fp_cmp, format-generic),
// OP_TOTALORDER the totalOrder datapath (fp_totalorder, format-generic) and
// OP_RNDINT the roundToIntegral datapaths (fp_roundint/fp_roundint_e8m0);
// OP_ADD/OP_SUB select the add datapaths (fp_add/fp_add_e8m0). `c` is only
// used by OP_FMA.
//
// The `cmp` output carries the 2-bit comparison condition code for OP_CMP
// (fp_pkg::CMP_*) and, for OP_TOTALORDER, cmp[0] = totalOrder(a, b) (a
// precedes-or-equals b); every other op drives cmp = 0.
//
// W_MANT = 0 selects the dedicated E8M0 (1 + W_EXP + 0 bits, microscaling
// shared-exponent format): the generic datapaths cannot be elaborated at that
// width by Verilator 5.020, and the p = 1 tie rules are implemented
// explicitly in the *_e8m0 modules.

module fp_unit #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23
) (
  input  fp_pkg::op_t        mode,
  input  fp_pkg::rounding_t  rm,
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
  input  logic [1+W_EXP+W_MANT-1:0] c,
  output logic [1+W_EXP+W_MANT-1:0] y,
  output logic [1:0]               cmp,
  output logic [4:0]               flags
);

  logic [1+W_EXP+W_MANT-1:0] y_add;
  logic [4:0]                flags_add;
  logic [1+W_EXP+W_MANT-1:0] y_mul;
  logic [4:0]                flags_mul;
  logic [1+W_EXP+W_MANT-1:0] y_div;
  logic [4:0]                flags_div;
  logic [1+W_EXP+W_MANT-1:0] y_sqrt;
  logic [4:0]                flags_sqrt;
  logic [1+W_EXP+W_MANT-1:0] y_fma;
  logic [4:0]                flags_fma;
  logic [1+W_EXP+W_MANT-1:0] y_mm;
  logic [4:0]                flags_mm;
  logic [1+W_EXP+W_MANT-1:0] y_rnd;
  logic [4:0]                flags_rnd;
  logic [1+W_EXP+W_MANT-1:0] y_cmp;
  logic [4:0]                flags_cmp;
  logic [1:0]                cmp_cmp;
  logic [1+W_EXP+W_MANT-1:0] y_tot;
  logic [4:0]                flags_tot;
  logic [1:0]                cmp_tot;

  generate
    if (W_MANT > 0) begin : g_generic
      fp_add #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_add (
        .a(a), .b(b), .rm(rm), .op(mode),
        .y(y_add), .flags(flags_add)
      );
      fp_mul #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_mul (
        .a(a), .b(b), .rm(rm),
        .y(y_mul), .flags(flags_mul)
      );
      fp_div #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_div (
        .a(a), .b(b), .rm(rm),
        .y(y_div), .flags(flags_div)
      );
      fp_sqrt #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_sqrt (
        .a(a), .rm(rm),
        .y(y_sqrt), .flags(flags_sqrt)
      );
      fp_fma #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_fma (
        .a(a), .b(b), .c(c), .rm(rm),
        .y(y_fma), .flags(flags_fma)
      );
      fp_minmax #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_minmax (
        .a(a), .b(b), .is_max(mode == fp_pkg::OP_MAX), .rm(rm),
        .y(y_mm), .flags(flags_mm)
      );
      fp_roundint #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_roundint (
        .a(a), .rm(rm),
        .y(y_rnd), .flags(flags_rnd)
      );
    end else begin : g_e8m0
      fp_add_e8m0 #(.W_EXP(W_EXP)) u_fp_add (
        .a(a), .b(b), .rm(rm), .op(mode),
        .y(y_add), .flags(flags_add)
      );
      fp_mul_e8m0 #(.W_EXP(W_EXP)) u_fp_mul (
        .a(a), .b(b), .rm(rm),
        .y(y_mul), .flags(flags_mul)
      );
      fp_div_e8m0 #(.W_EXP(W_EXP)) u_fp_div (
        .a(a), .b(b), .rm(rm),
        .y(y_div), .flags(flags_div)
      );
      fp_sqrt_e8m0 #(.W_EXP(W_EXP)) u_fp_sqrt (
        .a(a), .rm(rm),
        .y(y_sqrt), .flags(flags_sqrt)
      );
      fp_fma_e8m0 #(.W_EXP(W_EXP)) u_fp_fma (
        .a(a), .b(b), .c(c), .rm(rm),
        .y(y_fma), .flags(flags_fma)
      );
      fp_minmax #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_minmax (
        .a(a), .b(b), .is_max(mode == fp_pkg::OP_MAX), .rm(rm),
        .y(y_mm), .flags(flags_mm)
      );
      fp_roundint_e8m0 #(.W_EXP(W_EXP)) u_fp_roundint (
        .a(a), .rm(rm),
        .y(y_rnd), .flags(flags_rnd)
      );
    end
  endgenerate

  // Format-generic comparison / totalOrder datapaths (same as fp_minmax,
  // valid at every width including W_MANT = 0).
  fp_cmp #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_cmp (
    .a(a), .b(b), .rm(rm),
    .y(y_cmp), .cmp(cmp_cmp), .flags(flags_cmp)
  );
  fp_totalorder #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_fp_totalorder (
    .a(a), .b(b), .rm(rm),
    .y(y_tot), .cmp(cmp_tot), .flags(flags_tot)
  );

  always_comb begin
    if (mode == fp_pkg::OP_MUL) begin
      y     = y_mul;
      flags = flags_mul;
    end else if (mode == fp_pkg::OP_DIV) begin
      y     = y_div;
      flags = flags_div;
    end else if (mode == fp_pkg::OP_SQRT) begin
      y     = y_sqrt;
      flags = flags_sqrt;
    end else if (mode == fp_pkg::OP_FMA) begin
      y     = y_fma;
      flags = flags_fma;
    end else if (mode == fp_pkg::OP_MIN || mode == fp_pkg::OP_MAX) begin
      y     = y_mm;
      flags = flags_mm;
    end else if (mode == fp_pkg::OP_RNDINT) begin
      y     = y_rnd;
      flags = flags_rnd;
    end else if (mode == fp_pkg::OP_CMP) begin
      y     = y_cmp;
      flags = flags_cmp;
    end else if (mode == fp_pkg::OP_TOTALORDER) begin
      y     = y_tot;
      flags = flags_tot;
    end else begin
      y     = y_add;
      flags = flags_add;
    end
  end

  always_comb begin
    if (mode == fp_pkg::OP_CMP)
      cmp = cmp_cmp;
    else if (mode == fp_pkg::OP_TOTALORDER)
      cmp = cmp_tot;
    else
      cmp = 2'd0;
  end

endmodule
