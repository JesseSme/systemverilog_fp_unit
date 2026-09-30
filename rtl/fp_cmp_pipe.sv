// Pipelined IEEE 754-2019 quiet comparison (2 stages).
//
// Same semantics as fp_cmp.sv: 2-bit condition code on `cmp`, y driven to 0.
// Fixed latency: 2 cycles from `start` to `out_valid`.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SELRANGE */

module fp_cmp_pipe #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23
) (
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
  input  logic                      clk,
  input  logic                      rst_n,
  input  logic                      start,
  output logic [1+W_EXP+W_MANT-1:0] y,
  output logic [1:0]                cmp,
  output logic [4:0]                flags,
  output logic                      out_valid
);

  localparam int W       = 1 + W_EXP + W_MANT;
  localparam int MANT_W  = (W_MANT > 0) ? W_MANT : 1;
  localparam int EXP_ALL = (1 << W_EXP) - 1;

  logic              a_sign, b_sign;
  logic [W_EXP-1:0]  a_exp, b_exp;
  logic [MANT_W-1:0] a_mant, b_mant;
  assign a_sign = a[W-1];
  assign a_exp  = a[W-2 -: W_EXP];
  assign b_sign = b[W-1];
  assign b_exp  = b[W-2 -: W_EXP];
  always_comb begin
    a_mant = '0;
    b_mant = '0;
    if (W_MANT > 0) begin
      a_mant = a[W_MANT-1:0];
      b_mant = b[W_MANT-1:0];
    end
  end

  logic a_nan, a_snan, a_inf;
  logic b_nan, b_snan, b_inf;
  assign a_nan  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant != '0);
  assign a_snan = a_nan && !a_mant[MANT_W-1];
  assign a_inf  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant == '0);
  assign b_nan  = (b_exp == EXP_ALL[W_EXP-1:0]) && (b_mant != '0);
  assign b_snan = b_nan && !b_mant[MANT_W-1];
  assign b_inf  = (b_exp == EXP_ALL[W_EXP-1:0]) && (b_mant == '0);
  logic a_zero, b_zero;
  assign a_zero = (a_exp == '0) && (a_mant == '0);
  assign b_zero = (b_exp == '0) && (b_mant == '0);

  localparam logic [W_EXP+W_MANT-1:0] MAG_INF = '1;
  logic [W_EXP+W_MANT-1:0] mag_a, mag_b;
  assign mag_a = a_inf ? MAG_INF : ((W_EXP+W_MANT)'(a_exp) << W_MANT) | (W_EXP+W_MANT)'(a_mant);
  assign mag_b = b_inf ? MAG_INF : ((W_EXP+W_MANT)'(b_exp) << W_MANT) | (W_EXP+W_MANT)'(b_mant);

  logic a_lt_b, b_lt_a;
  always_comb begin
    if (a_sign != b_sign) begin
      a_lt_b = a_sign;
      b_lt_a = b_sign;
    end else if (a_sign) begin
      a_lt_b = (mag_a > mag_b);
      b_lt_a = (mag_b > mag_a);
    end else begin
      a_lt_b = (mag_a < mag_b);
      b_lt_a = (mag_b < mag_a);
    end
  end

  logic [W-1:0] y_c;
  logic [1:0]   cmp_c;
  logic [4:0]   flags_c;
  always_comb begin
    y_c     = '0;
    flags_c = 5'd0;
    cmp_c   = fp_pkg::CMP_EQ;
    if (a_nan || b_nan) begin
      cmp_c = fp_pkg::CMP_UN;
      flags_c[fp_pkg::FLAG_INVALID] = a_snan || b_snan;
    end else if (a_zero && b_zero) begin
      cmp_c = fp_pkg::CMP_EQ;
    end else if (a_lt_b) begin
      cmp_c = fp_pkg::CMP_LT;
    end else if (b_lt_a) begin
      cmp_c = fp_pkg::CMP_GT;
    end else begin
      cmp_c = fp_pkg::CMP_EQ;
    end
  end

  logic [W-1:0] y_s1;
  logic [1:0]   cmp_s1;
  logic [4:0]   flags_s1;
  logic         v1;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      y_s1     <= '0;
      cmp_s1   <= 2'd0;
      flags_s1 <= 5'd0;
      v1       <= 1'b0;
    end else begin
      y_s1     <= y_c;
      cmp_s1   <= cmp_c;
      flags_s1 <= flags_c;
      v1       <= start;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      y         <= '0;
      cmp       <= 2'd0;
      flags     <= 5'd0;
      out_valid <= 1'b0;
    end else begin
      y         <= y_s1;
      cmp       <= cmp_s1;
      flags     <= flags_s1;
      out_valid <= v1;
    end
  end

endmodule
