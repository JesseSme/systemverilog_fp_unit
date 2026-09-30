// Pipelined IEEE 754-2019 roundToIntegral (3 stages).
//
// Same semantics as fp_roundint.sv. Stages:
//   S1  unpack, classification, special cases, M/e0 decomposition
//   S2  fractional-bit (GRS) extraction at the binary point + rounding increment
//   S3  re-encode the rounded integer (normal/subnormal/overflow) + result mux
//
// Fixed latency: 3 cycles from `start` to `out_valid`.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SELRANGE */

module fp_roundint_pipe #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23
) (
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  fp_pkg::rounding_t         rm,
  input  logic                      clk,
  input  logic                      rst_n,
  input  logic                      start,
  output logic [1+W_EXP+W_MANT-1:0] y,
  output logic [4:0]                flags,
  output logic                      out_valid
);

  localparam int W       = 1 + W_EXP + W_MANT;
  localparam int BIAS    = (1 << (W_EXP-1)) - 1;
  localparam int EMAX    = BIAS;
  localparam int EMIN    = 1 - BIAS;
  localparam int S_W     = W_MANT + 1;
  localparam int MANT_W  = (W_MANT > 0) ? W_MANT : 1;
  localparam int EXP_ALL = (1 << W_EXP) - 1;
  localparam int EXP_MAXF = (1 << W_EXP) - 2;
  localparam logic [MANT_W-1:0] QUIET = (MANT_W)'(1) << (MANT_W - 1);

  // ============================================================ stage S1
  logic              a_sign;
  logic [W_EXP-1:0]  a_exp;
  logic [MANT_W-1:0] a_mant;
  assign a_sign = a[W-1];
  assign a_exp  = a[W-2 -: W_EXP];
  always_comb begin
    a_mant = '0;
    if (W_MANT > 0)
      a_mant = a[W_MANT-1:0];
  end

  logic a_nan, a_snan, a_inf, a_zero, a_sub;
  assign a_nan  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant != '0);
  assign a_snan = a_nan && !a_mant[MANT_W-1];
  assign a_inf  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant == '0);
  assign a_zero = (a_exp == '0) && (a_mant == '0);
  assign a_sub  = (a_exp == '0) && (a_mant != '0);

  logic [W-1:0] y_special;
  logic [4:0]   flags_special;
  logic         special_case;
  always_comb begin
    y_special    = '0;
    flags_special = '0;
    special_case = 1'b0;
    if (a_nan) begin
      y_special = {a_sign, EXP_ALL[W_EXP-1:0], a_mant | QUIET};
      flags_special[fp_pkg::FLAG_INVALID] = a_snan;
      special_case = 1'b1;
    end else if (a_inf || a_zero) begin
      y_special = a;
      special_case = 1'b1;
    end
  end

  logic [S_W-1:0]      M;
  logic signed [W_EXP+3:0] e0;
  always_comb begin
    if (a_sub) begin
      M  = {1'b0, a_mant};
      e0 = (W_EXP+4)'(EMIN - W_MANT);
    end else begin
      M  = ((S_W)'(1'b1) << W_MANT) | {1'b0, a_mant};
      e0 = (W_EXP+4)'(a_exp - BIAS - W_MANT);
    end
  end

  logic [W-1:0]            a_s1;
  logic                    a_sign_s1;
  logic [S_W-1:0]          M_s1;
  logic signed [W_EXP+3:0] e0_s1;
  logic [2:0]              rm_s1;
  logic [W-1:0]            y_special_s1;
  logic [4:0]              flags_special_s1;
  logic                    special_s1;
  logic                    v1;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      a_s1             <= '0;
      a_sign_s1        <= 1'b0;
      M_s1             <= '0;
      e0_s1            <= '0;
      rm_s1            <= 3'd0;
      y_special_s1     <= '0;
      flags_special_s1 <= 5'd0;
      special_s1       <= 1'b0;
      v1               <= 1'b0;
    end else begin
      a_s1             <= a;
      a_sign_s1        <= a_sign;
      M_s1             <= M;
      e0_s1            <= e0;
      rm_s1            <= rm;
      y_special_s1     <= y_special;
      flags_special_s1 <= flags_special;
      special_s1       <= special_case;
      v1               <= start;
    end
  end

  // ============================================================ stage S2
  logic [S_W-1:0] int_part_s2;
  always_comb begin
    int             k;
    logic [S_W-1:0] int_part;
    logic           g, r, s_bit, inexact, up;
    int_part = '0;
    k = 0;
    g = 1'b0; r = 1'b0; s_bit = 1'b0; inexact = 1'b0; up = 1'b0;
    int_part_s2 = '0;
    if ($signed(e0_s1) < 0) begin
      k = int'(-e0_s1);
      if (k > S_W) begin
        s_bit = |M_s1;
      end else begin
        int_part = M_s1 >> k;
        g = M_s1[k-1];
        if (k >= 2) r = M_s1[k-2];
        s_bit = |(M_s1 & (((S_W)'(1) << (k >= 3 ? k - 2 : 0)) - 1));
      end
      inexact = g | r | s_bit;
      case (rm_s1)
        fp_pkg::RM_RNE: up = g & (r | s_bit) | (g & ~r & ~s_bit & int_part[0]);
        fp_pkg::RM_RNA: up = g;
        fp_pkg::RM_RZ:  up = 1'b0;
        fp_pkg::RM_RP:  up = ~a_sign_s1 & inexact;
        fp_pkg::RM_RM:  up = a_sign_s1 & inexact;
        default:        up = 1'b0;
      endcase
      int_part = int_part + { {S_W-1{1'b0}}, up };
    end
    int_part_s2 = int_part;
  end

  logic [S_W-1:0]          int_part_s2r;
  logic [W-1:0]            a_s2;
  logic                    a_sign_s2;
  logic signed [W_EXP+3:0] e0_s2;
  logic [2:0]              rm_s2;
  logic [W-1:0]            y_special_s2;
  logic [4:0]              flags_special_s2;
  logic                    special_s2;
  logic                    v2;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      int_part_s2r     <= '0;
      a_s2             <= '0;
      a_sign_s2        <= 1'b0;
      e0_s2            <= '0;
      rm_s2            <= 3'd0;
      y_special_s2     <= '0;
      flags_special_s2 <= 5'd0;
      special_s2       <= 1'b0;
      v2               <= 1'b0;
    end else begin
      int_part_s2r     <= int_part_s2;
      a_s2             <= a_s1;
      a_sign_s2        <= a_sign_s1;
      e0_s2            <= e0_s1;
      rm_s2            <= rm_s1;
      y_special_s2     <= y_special_s1;
      flags_special_s2 <= flags_special_s1;
      special_s2       <= special_s1;
      v2               <= v1;
    end
  end

  // ============================================================ stage S3
  logic [W-1:0] y_fin_s3;
  logic [4:0]   flags_fin_s3;
  always_comb begin
    int ey;
    y_fin_s3   = '0;
    flags_fin_s3 = 5'd0;
    ey = 0;
    if (int_part_s2r == '0) begin
      y_fin_s3 = {a_sign_s2, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
    end else begin
      for (int i = 0; i < S_W; i++)
        if (int_part_s2r[i]) ey = i;
      if (ey > EMAX) begin
        case (rm_s2)
          fp_pkg::RM_RNE,
          fp_pkg::RM_RNA: y_fin_s3 = {a_sign_s2, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
          fp_pkg::RM_RZ:  y_fin_s3 = {a_sign_s2, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
          fp_pkg::RM_RP:  y_fin_s3 = a_sign_s2 ? {1'b1, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}}
                                               : {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
          fp_pkg::RM_RM:  y_fin_s3 = a_sign_s2 ? {1'b1, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}}
                                               : {1'b0, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
          default:        y_fin_s3 = {a_sign_s2, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        endcase
        flags_fin_s3 = (1 << fp_pkg::FLAG_OVERFLOW) | (1 << fp_pkg::FLAG_INEXACT);
      end else if (ey >= EMIN) begin
        y_fin_s3 = {a_sign_s2, (W_EXP)'(ey + BIAS),
                    (MANT_W)'((int_part_s2r - ((S_W)'(1) << ey)) << (W_MANT - ey))};
      end else begin
        y_fin_s3 = {a_sign_s2, {W_EXP{1'b0}},
                    (MANT_W)'(int_part_s2r) << (W_MANT - EMIN)};
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      y         <= '0;
      flags     <= 5'd0;
      out_valid <= 1'b0;
    end else begin
      if (special_s2) begin
        y     <= y_special_s2;
        flags <= flags_special_s2;
      end else if ($signed(e0_s2) >= 0) begin
        y     <= a_s2;  // already integral: returned unchanged
        flags <= 5'd0;
      end else begin
        y     <= y_fin_s3;
        flags <= flags_fin_s3;
      end
      out_valid <= v2;
    end
  end

endmodule
