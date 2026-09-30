// Pipelined IEEE 754-2019 multiplication (5 stages).
//
// Same semantics as fp_mul.sv (special cases, GRS rounding, subnormal path,
// overflow/inexact rules). The exact significand product comes from the
// LUT-only pipelined fp_mul_core (latency 3; no DSP inference), then two
// rounding stages:
//
//   cycle 0  unpack/classify/special, significands, exponents; core start
//   cycles 1-3  core reduction tree
//   stage M1 (reg after cycle 3)  place the product, GRS capture, e_res
//   stage M2 (reg after cycle 4)  round, overflow/subnormal, encode
//
// Fixed latency: 5 cycles from `start` to `out_valid`.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */

module fp_mul_pipe #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23
) (
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
  input  fp_pkg::rounding_t         rm,
  input  logic                      clk,
  input  logic                      rst_n,
  input  logic                      start,
  output logic [1+W_EXP+W_MANT-1:0] y,
  output logic [4:0]                flags,
  output logic                      out_valid
);

  localparam int W       = 1 + W_EXP + W_MANT;   // total width
  localparam int BIAS    = (1 << (W_EXP-1)) - 1; // exponent bias (3.3)
  localparam int EMAX    = BIAS;                 // largest exponent
  localparam int EMIN    = 1 - BIAS;             // smallest normal exponent
  localparam int S_W     = W_MANT + 1;           // significand width incl. implicit bit
  localparam int MANT_W  = (W_MANT > 0) ? W_MANT : 1;
  localparam int TARGET  = S_W + 2;              // MSB position of the placed product
  localparam int FW      = S_W + 3;              // fixed-point width (sig + GRS)
  localparam int P_W     = 2 * S_W;              // exact product width
  localparam int EXP_ALL = (1 << W_EXP) - 1;
  localparam int EXP_MAXF = (1 << W_EXP) - 2;
  localparam logic [MANT_W-1:0] QUIET = (MANT_W)'(1) << (MANT_W - 1);
  localparam logic signed [W_EXP+4:0] EMAX_S = (W_EXP+4)'(EMAX);
  localparam logic signed [W_EXP+4:0] EMIN_S = (W_EXP+4)'(EMIN);
  localparam int BL_W = $clog2(S_W + 1);

  // ============================================================ cycle 0
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

  logic a_nan, a_snan, a_inf, a_zero, a_sub;
  logic b_nan, b_snan, b_inf, b_zero, b_sub;
  assign a_nan  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant != '0);
  assign a_snan = a_nan && !a_mant[MANT_W-1];
  assign a_inf  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant == '0);
  assign a_zero = (a_exp == '0) && (a_mant == '0);
  assign a_sub  = (a_exp == '0) && (a_mant != '0);
  assign b_nan  = (b_exp == EXP_ALL[W_EXP-1:0]) && (b_mant != '0);
  assign b_snan = b_nan && !b_mant[MANT_W-1];
  assign b_inf  = (b_exp == EXP_ALL[W_EXP-1:0]) && (b_mant == '0);
  assign b_zero = (b_exp == '0) && (b_mant == '0);
  assign b_sub  = (b_exp == '0) && (b_mant != '0);

  logic [W-1:0] y_special;
  logic [4:0]   flags_special;
  logic         special_case;
  always_comb begin
    y_special    = '0;
    flags_special = '0;
    special_case = 1'b0;
    if (a_nan || b_nan) begin
      y_special = {1'b0, EXP_ALL[W_EXP-1:0], (a_nan ? a_mant : b_mant) | QUIET};
      flags_special[fp_pkg::FLAG_INVALID] = a_snan || b_snan;
      special_case = 1'b1;
    end else if (a_inf || b_inf) begin
      if (a_inf && b_inf) begin
        y_special = {a_sign ^ b_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      end else if (a_inf) begin
        if (b_zero) begin
          y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
          flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
        end else begin
          y_special = {a_sign ^ b_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        end
      end else begin
        if (a_zero) begin
          y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
          flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
        end else begin
          y_special = {a_sign ^ b_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        end
      end
      special_case = 1'b1;
    end else if (a_zero || b_zero) begin
      y_special = {a_sign ^ b_sign, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
      special_case = 1'b1;
    end
  end

  logic [S_W-1:0] s_a, s_b;
  assign s_a = a_sub ? {1'b0, a_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, a_mant};
  assign s_b = b_sub ? {1'b0, b_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, b_mant};

  function automatic int unsigned bitlen(input logic [S_W-1:0] x);
    bitlen = 0;
    for (int i = 0; i < S_W; i++)
      if (x[i]) bitlen = i + 1;
  endfunction

  logic signed [W_EXP+2:0] e_a, e_b;
  always_comb begin
    int bl_a, bl_b;
    bl_a = int'(bitlen(s_a));
    bl_b = int'(bitlen(s_b));
    e_a = (W_EXP+3)'(a_exp - BIAS);
    if (a_sub) e_a = (W_EXP+3)'((1 - BIAS) - W_MANT + $signed(bl_a) - 1);
    e_b = (W_EXP+3)'(b_exp - BIAS);
    if (b_sub) e_b = (W_EXP+3)'((1 - BIAS) - W_MANT + $signed(bl_b) - 1);
  end

  logic rsign;
  assign rsign = a_sign ^ b_sign;

  // exact product from the LUT-only pipelined core (latency 3)
  logic [P_W-1:0] P;
  logic           core_valid;
  fp_mul_core #(.W(S_W)) u_core (
    .clk(clk), .rst_n(rst_n), .start(start),
    .a(s_a), .b(s_b), .p(P), .out_valid(core_valid)
  );

  // context registers (valid from cycle 1; consumed by stage M1 in cycle 3)
  logic [W-1:0]   y_special_s1;
  logic [4:0]     flags_special_s1;
  logic           special_s1;
  logic           rsign_s1;
  logic [2:0]     rm_s1;
  logic signed [W_EXP+2:0] e_a_s1, e_b_s1;
  logic [BL_W-1:0] bl_a_s1, bl_b_s1;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      y_special_s1    <= '0;
      flags_special_s1 <= 5'd0;
      special_s1      <= 1'b0;
      rsign_s1        <= 1'b0;
      rm_s1           <= 3'd0;
      e_a_s1          <= '0;
      e_b_s1          <= '0;
      bl_a_s1         <= '0;
      bl_b_s1         <= '0;
    end else begin
      y_special_s1    <= y_special;
      flags_special_s1 <= flags_special;
      special_s1      <= special_case;
      rsign_s1        <= rsign;
      rm_s1           <= rm;
      e_a_s1          <= e_a;
      e_b_s1          <= e_b;
      bl_a_s1         <= BL_W'(bitlen(s_a));
      bl_b_s1         <= BL_W'(bitlen(s_b));
    end
  end

  // ============================================================ stage M1
  function automatic int unsigned pbitlen(input logic [P_W-1:0] x);
    pbitlen = 0;
    for (int i = 0; i < P_W; i++)
      if (x[i]) pbitlen = i + 1;
  endfunction

  logic [FW-1:0]    placed_m1;
  logic             placed_sticky_m1;
  logic signed [W_EXP+3:0] e_res_m1;
  always_comb begin
    int B;
    B = int'(pbitlen(P));
    if (B == 0) begin
      placed_m1        = '0;
      placed_sticky_m1 = 1'b0;
    end else if (B <= FW) begin
      placed_m1        = FW'(P) << (FW - B);
      placed_sticky_m1 = 1'b0;
    end else begin
      placed_m1        = FW'(P >> (B - FW));
      placed_sticky_m1 = |(P & (((P_W)'(1) << (B - FW)) - 1));
    end
    e_res_m1 = (W_EXP+4)'(e_a_s1) + (W_EXP+4)'(e_b_s1)
             + (W_EXP+4)'(pbitlen(P) == int'(bl_a_s1) + int'(bl_b_s1));
  end
  // bitlen(s_a_s1)/s_b_s1 are carried in bl_a_s1/bl_b_s1; the carry-out
  // identity uses those instead of re-running the leading-one search.

  logic [FW-1:0]    placed_r;
  logic             placed_sticky_r;
  logic signed [W_EXP+3:0] e_res_r;
  logic             rsign_r;
  logic [2:0]       rm_r;
  logic [W-1:0]     y_special_r;
  logic [4:0]       flags_special_r;
  logic             special_r;
  logic             m1_valid;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      placed_r         <= '0;
      placed_sticky_r  <= 1'b0;
      e_res_r          <= '0;
      rsign_r          <= 1'b0;
      rm_r             <= 3'd0;
      y_special_r      <= '0;
      flags_special_r  <= 5'd0;
      special_r        <= 1'b0;
      m1_valid         <= 1'b0;
    end else begin
      placed_r         <= placed_m1;
      placed_sticky_r  <= placed_sticky_m1;
      e_res_r          <= e_res_m1;
      rsign_r          <= rsign_s1;
      rm_r             <= rm_s1;
      y_special_r      <= y_special_s1;
      flags_special_r  <= flags_special_s1;
      special_r        <= special_s1;
      m1_valid         <= core_valid;
    end
  end

  // ============================================================ stage M2
  logic [S_W-1:0] sig;
  logic           g, r, s_bit, lsb, inexact, round_up, carry;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [S_W-1:0] sig_rnd;
  /* verilator lint_on UNUSEDSIGNAL */
  logic signed [W_EXP+3:0] e_rnd;
  logic [W-1:0]   y_normal;
  logic [4:0]     flags_normal;
  always_comb begin
    logic [W_EXP-1:0] exp_fld;
    sig     = placed_r[TARGET -: S_W];
    g       = placed_r[2];
    r       = placed_r[1];
    s_bit   = placed_r[0] | placed_sticky_r;
    lsb     = sig[0];
    inexact = g | r | s_bit;
    case (rm_r)
      fp_pkg::RM_RNE: round_up = g & (r | s_bit) | (g & ~r & ~s_bit & lsb);
      fp_pkg::RM_RNA: round_up = g;
      fp_pkg::RM_RZ:  round_up = 1'b0;
      fp_pkg::RM_RP:  round_up = ~rsign_r & inexact;
      fp_pkg::RM_RM:  round_up = rsign_r & inexact;
      default:        round_up = 1'b0;
    endcase
    carry = round_up && (sig == {S_W{1'b1}});
    if (carry) begin
      sig_rnd = {1'b1, {W_MANT{1'b0}}};
      e_rnd   = e_res_r + 1;
    end else begin
      sig_rnd = sig + { {S_W-1{1'b0}}, round_up };
      e_rnd   = e_res_r;
    end
    exp_fld = e_rnd[W_EXP-1:0] + BIAS[W_EXP-1:0];
    if ($signed(e_rnd) > EMAX_S) begin
      case (rm_r)
        fp_pkg::RM_RNE,
        fp_pkg::RM_RNA: y_normal = {rsign_r, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        fp_pkg::RM_RZ:  y_normal = {rsign_r, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
        fp_pkg::RM_RP:  y_normal = rsign_r ? {1'b1, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}}
                                           : {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        fp_pkg::RM_RM:  y_normal = rsign_r ? {1'b1, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}}
                                           : {1'b0, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
        default:        y_normal = {rsign_r, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      endcase
      flags_normal = (1 << fp_pkg::FLAG_OVERFLOW) | (1 << fp_pkg::FLAG_INEXACT);
    end else begin
      y_normal = {rsign_r, exp_fld, sig_rnd[MANT_W-1:0]};
      flags_normal = inexact ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
    end
  end

  logic [W-1:0] y_sub;
  logic [4:0]   flags_sub;
  generate
    if (W_MANT > 0) begin : g_subnormal
      always_comb begin
        int signed          shift;
        logic [FW-1:0]      shifted;
        logic [S_W-1:0]     sig_s;
        logic               gs, rs, ss, inexact_s, up_s;
        logic [S_W-1:0]     sig_s2;
        shift = int'(EMIN - int'(e_res_r));
        if (shift > 0) shifted = placed_r >> shift;
        else           shifted = '0;
        sig_s  = shifted[TARGET -: S_W];
        gs     = shifted[2];
        rs     = shifted[1];
        ss     = shifted[0] | placed_sticky_r
               | |(placed_r & (((FW)'(1) << (shift > 0 ? shift : 0)) - 1));
        inexact_s = gs | rs | ss;
        case (rm_r)
          fp_pkg::RM_RNE: up_s = gs & (rs | ss) | (gs & ~rs & ~ss & sig_s[0]);
          fp_pkg::RM_RNA: up_s = gs;
          fp_pkg::RM_RZ:  up_s = 1'b0;
          fp_pkg::RM_RP:  up_s = ~rsign_r & inexact_s;
          fp_pkg::RM_RM:  up_s = rsign_r & inexact_s;
          default:        up_s = 1'b0;
        endcase
        sig_s2 = sig_s + { {S_W-1{1'b0}}, up_s };
        if (sig_s2 == {1'b1, {W_MANT{1'b0}}}) begin
          if (EMIN > EMAX &&
              ((gs && rs) || (rm_r == fp_pkg::RM_RP && ~rsign_r && gs)
                         || (rm_r == fp_pkg::RM_RM && rsign_r && gs))) begin
            case (rm_r)
              fp_pkg::RM_RNE,
              fp_pkg::RM_RNA: y_sub = {rsign_r, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
              fp_pkg::RM_RZ:  y_sub = {rsign_r, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
              fp_pkg::RM_RP:  y_sub = rsign_r ? {1'b1, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}}
                                              : {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
              fp_pkg::RM_RM:  y_sub = rsign_r ? {1'b1, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}}
                                              : {1'b0, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
              default:        y_sub = {rsign_r, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
            endcase
            flags_sub = (1 << fp_pkg::FLAG_OVERFLOW) | (1 << fp_pkg::FLAG_INEXACT);
          end else begin
            y_sub = {rsign_r, {W_EXP-1{1'b0}}, 1'b1, {W_MANT{1'b0}}};
            flags_sub = inexact_s ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
          end
        end else if (sig_s2 == '0) begin
          y_sub = {rsign_r, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
          flags_sub = inexact_s ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
        end else begin
          y_sub = {rsign_r, {W_EXP{1'b0}}, sig_s2[MANT_W-1:0]};
          flags_sub = 5'd0;
          if (inexact_s) begin
            flags_sub[fp_pkg::FLAG_UNDERFLOW] = 1'b1;
            flags_sub[fp_pkg::FLAG_INEXACT]   = 1'b1;
          end
        end
      end
    end else begin : g_no_subnormal
      assign y_sub     = {rsign_r, {W_EXP{1'b0}}};
      assign flags_sub = 5'd0;
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      y         <= '0;
      flags     <= 5'd0;
      out_valid <= 1'b0;
    end else begin
      if (special_r) begin
        y     <= y_special_r;
        flags <= flags_special_r;
      end else if ($signed(e_res_r) >= EMIN_S) begin
        y     <= y_normal;
        flags <= flags_normal;
      end else begin
        y     <= y_sub;
        flags <= flags_sub;
      end
      out_valid <= m1_valid;
    end
  end

endmodule
