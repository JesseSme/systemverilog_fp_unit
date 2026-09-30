// Pipelined IEEE 754-2019 addition / subtraction (5 stages).
//
// Semantics are bit-identical to fp_add.sv (same special cases, alignment,
// GRS rounding, subnormal path, overflow/underflow rules); the datapath is
// split into five registered stages so each stage has a short critical path:
//
//   S1  unpack, classification, special cases, significands, exponents
//   S2  align to the larger exponent (barrel shift) + sticky capture
//   S3  sign-magnitude add / subtract
//   S4  normalize (leading-one search + shift)
//   S5  GRS rounding (normal + subnormal), overflow/underflow, encode
//
// Fixed latency: 5 cycles from `start` to `out_valid` for every input.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
// Int arithmetic is deliberately mixed with sized logic; every expression is
// bounded such that the truncation/extensions are exact.

module fp_add_pipe #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23
) (
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
  input  fp_pkg::rounding_t         rm,
  input  fp_pkg::op_t               op,
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
  localparam int MANT_W  = (W_MANT > 0) ? W_MANT : 1;  // internal mantissa width
  localparam int TARGET  = S_W + 2;              // MSB position of aligned significand
  localparam int FW      = S_W + 3;              // aligned fixed-point width
  localparam int SUM_W   = FW + 1;               // aligned sum width (carry bit)
  localparam int NORM_W  = SUM_W + TARGET;       // normalized result width
  localparam int EXP_ALL = (1 << W_EXP) - 1;     // all-ones exponent field
  localparam int EXP_MAXF = (1 << W_EXP) - 2;    // exponent field of the largest finite
  localparam logic [MANT_W-1:0] QUIET = (MANT_W)'(1) << (MANT_W - 1);
  localparam logic signed [W_EXP+4:0] EMAX_S = (W_EXP+4)'(EMAX);
  localparam logic signed [W_EXP+4:0] EMIN_S = (W_EXP+4)'(EMIN);
  localparam int BL_W = $clog2(S_W + 1);         // bitlen width

  // ============================================================ stage 1
  // unpack (3.3)
  logic              a_sign, b_sign, b_sign_eff;
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
  assign b_sign_eff = b_sign ^ (op == fp_pkg::OP_SUB);

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

  // special cases (6.x)
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
        if (a_sign == b_sign_eff)
          y_special = {a_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        else begin
          y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
          flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
        end
      end else if (a_inf) begin
        y_special = {a_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      end else begin
        y_special = {b_sign_eff, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      end
      special_case = 1'b1;
    end else if (a_zero && b_zero) begin
      y_special = {(a_sign == b_sign_eff) ? a_sign : (rm == fp_pkg::RM_RM),
                   {W_EXP{1'b0}}, {W_MANT{1'b0}}};
      special_case = 1'b1;
    end else if (a_zero) begin
      y_special = {b_sign_eff, b_exp, b_mant};
      special_case = 1'b1;
    end else if (b_zero) begin
      y_special = a;
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
  logic signed [W_EXP+2:0] e_max;
  assign e_max = (e_a >= e_b) ? e_a : e_b;

  // stage 1 registers
  logic [W-1:0]   y_special_s1;
  logic [4:0]     flags_special_s1;
  logic           special_s1;
  logic           a_sign_s1, b_sign_eff_s1;
  logic [S_W-1:0] s_a_s1, s_b_s1;
  logic [BL_W-1:0] bl_a_s1, bl_b_s1;
  logic signed [W_EXP+2:0] e_a_s1, e_b_s1, e_max_s1;
  logic [2:0]     rm_s1;
  logic           v1;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      y_special_s1    <= '0;
      flags_special_s1 <= 5'd0;
      special_s1      <= 1'b0;
      a_sign_s1       <= 1'b0;
      b_sign_eff_s1   <= 1'b0;
      s_a_s1          <= '0;
      s_b_s1          <= '0;
      bl_a_s1         <= '0;
      bl_b_s1         <= '0;
      e_a_s1          <= '0;
      e_b_s1          <= '0;
      e_max_s1        <= '0;
      rm_s1           <= 3'd0;
      v1              <= 1'b0;
    end else begin
      y_special_s1    <= y_special;
      flags_special_s1 <= flags_special;
      special_s1      <= special_case;
      a_sign_s1       <= a_sign;
      b_sign_eff_s1   <= b_sign_eff;
      s_a_s1          <= s_a;
      s_b_s1          <= s_b;
      bl_a_s1         <= BL_W'(bitlen(s_a));
      bl_b_s1         <= BL_W'(bitlen(s_b));
      e_a_s1          <= e_a;
      e_b_s1          <= e_b;
      e_max_s1        <= e_max;
      rm_s1           <= rm;
      v1              <= start;
    end
  end

  // ============================================================ stage 2
  // align to the larger exponent
  logic [FW-1:0]  fp_a_s2, fp_b_s2;
  logic           sticky_s2;
  always_comb begin
    int rsh;
    logic [FW-1:0] placed;
    fp_a_s2 = '0;
    fp_b_s2 = '0;
    sticky_s2 = 1'b0;
    // operand a
    rsh = int'(e_max_s1 - e_a_s1);
    placed = FW'($unsigned(s_a_s1)) << (TARGET - int'(bl_a_s1) + 1);
    if (rsh >= FW) begin
      fp_a_s2 = '0;
      sticky_s2 = sticky_s2 | |placed;
    end else begin
      fp_a_s2 = FW'(placed >> rsh);
      sticky_s2 = sticky_s2 | |(placed & ((FW)'(1) << rsh) - 1);
    end
    // operand b
    rsh = int'(e_max_s1 - e_b_s1);
    placed = FW'($unsigned(s_b_s1)) << (TARGET - int'(bl_b_s1) + 1);
    if (rsh >= FW) begin
      fp_b_s2 = '0;
      sticky_s2 = sticky_s2 | |placed;
    end else begin
      fp_b_s2 = FW'(placed >> rsh);
      sticky_s2 = sticky_s2 | |(placed & ((FW)'(1) << rsh) - 1);
    end
  end

  logic [FW-1:0] fp_a_s2r, fp_b_s2r;
  logic          sticky_s2r;
  logic          a_sign_s2, b_sign_eff_s2;
  logic signed [W_EXP+2:0] e_max_s2;
  logic [W-1:0]  y_special_s2;
  logic [4:0]    flags_special_s2;
  logic          special_s2;
  logic [2:0]    rm_s2;
  logic          v2;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fp_a_s2r        <= '0;
      fp_b_s2r        <= '0;
      sticky_s2r      <= 1'b0;
      a_sign_s2       <= 1'b0;
      b_sign_eff_s2   <= 1'b0;
      e_max_s2        <= '0;
      y_special_s2    <= '0;
      flags_special_s2 <= 5'd0;
      special_s2      <= 1'b0;
      rm_s2           <= 3'd0;
      v2              <= 1'b0;
    end else begin
      fp_a_s2r        <= fp_a_s2;
      fp_b_s2r        <= fp_b_s2;
      sticky_s2r      <= sticky_s2;
      a_sign_s2       <= a_sign_s1;
      b_sign_eff_s2   <= b_sign_eff_s1;
      e_max_s2        <= e_max_s1;
      y_special_s2    <= y_special_s1;
      flags_special_s2 <= flags_special_s1;
      special_s2      <= special_s1;
      rm_s2           <= rm_s1;
      v2              <= v1;
    end
  end

  // ============================================================ stage 3
  // sign-magnitude addition (same as fp_add)
  logic same_sign;
  logic [SUM_W-1:0] mag_s3;
  logic             rsign_s3, cancel_s3;
  assign same_sign = (a_sign_s2 == b_sign_eff_s2);
  always_comb begin
    if (same_sign) begin
      mag_s3    = {1'b0, fp_a_s2r} + {1'b0, fp_b_s2r};
      rsign_s3  = a_sign_s2;
      cancel_s3 = 1'b0;
    end else if ({1'b0, fp_a_s2r} >= {1'b0, fp_b_s2r}) begin
      mag_s3    = {1'b0, fp_a_s2r} - {1'b0, fp_b_s2r};
      rsign_s3  = a_sign_s2;
      cancel_s3 = (mag_s3 == '0);
      if (sticky_s2r) mag_s3 = mag_s3 - 1;
    end else begin
      mag_s3    = {1'b0, fp_b_s2r} - {1'b0, fp_a_s2r};
      rsign_s3  = b_sign_eff_s2;
      cancel_s3 = (mag_s3 == '0);
      if (sticky_s2r) mag_s3 = mag_s3 - 1;
    end
  end

  logic [SUM_W-1:0] mag_s3r;
  logic             rsign_s3r, cancel_s3r;
  logic             align_sticky_s3r;
  logic signed [W_EXP+2:0] e_max_s3;
  logic [W-1:0]     y_special_s3;
  logic [4:0]       flags_special_s3;
  logic             special_s3;
  logic [2:0]       rm_s3;
  logic             v3;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mag_s3r          <= '0;
      rsign_s3r        <= 1'b0;
      cancel_s3r       <= 1'b0;
      align_sticky_s3r <= 1'b0;
      e_max_s3         <= '0;
      y_special_s3     <= '0;
      flags_special_s3 <= 5'd0;
      special_s3       <= 1'b0;
      rm_s3            <= 3'd0;
      v3               <= 1'b0;
    end else begin
      mag_s3r          <= mag_s3;
      rsign_s3r        <= rsign_s3;
      cancel_s3r       <= cancel_s3;
      align_sticky_s3r <= sticky_s2r;
      e_max_s3         <= e_max_s2;
      y_special_s3     <= y_special_s2;
      flags_special_s3 <= flags_special_s2;
      special_s3       <= special_s2;
      rm_s3            <= rm_s2;
      v3               <= v2;
    end
  end

  // ============================================================ stage 4
  // normalize: leading-one position of the magnitude
  function automatic int unsigned lpos(input logic [SUM_W-1:0] x);
    lpos = 0;
    for (int i = 0; i < SUM_W; i++)
      if (x[i]) lpos = i;
  endfunction

  int                   p0_s4;
  logic [NORM_W-1:0]    norm_s4;
  logic                 norm_sticky_s4;
  logic signed [W_EXP+3:0] e_res_s4;
  always_comb begin
    p0_s4 = int'(lpos(mag_s3r));
    norm_sticky_s4 = align_sticky_s3r;  // sticky bits lost during operand alignment
    if (p0_s4 > TARGET) begin
      norm_s4 = {(NORM_W-SUM_W+1)'(1'b0), mag_s3r} >> 1;
      norm_sticky_s4 = norm_sticky_s4 | mag_s3r[0];
      e_res_s4 = (W_EXP+4)'(e_max_s3) + 1;
    end else if (p0_s4 < TARGET) begin
      norm_s4 = {(NORM_W-SUM_W)'(1'b0), mag_s3r} << (TARGET - p0_s4);
      e_res_s4 = (W_EXP+4)'(e_max_s3) + (W_EXP+4)'($signed(p0_s4) - TARGET);
    end else begin
      norm_s4 = {(NORM_W-SUM_W)'(1'b0), mag_s3r};
      e_res_s4 = (W_EXP+4)'(e_max_s3);
    end
  end

  logic [NORM_W-1:0]    norm_s4r;
  logic                 norm_sticky_s4r;
  logic signed [W_EXP+3:0] e_res_s4r;
  logic                 rsign_s4;
  logic [W-1:0]         y_special_s4;
  logic [4:0]           flags_special_s4;
  logic                 special_s4;
  logic [2:0]           rm_s4;
  logic                 v4;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      norm_s4r         <= '0;
      norm_sticky_s4r  <= 1'b0;
      e_res_s4r        <= '0;
      rsign_s4         <= 1'b0;
      y_special_s4     <= '0;
      flags_special_s4 <= 5'd0;
      special_s4       <= 1'b0;
      rm_s4            <= 3'd0;
      v4               <= 1'b0;
    end else begin
      norm_s4r         <= norm_s4;
      norm_sticky_s4r  <= norm_sticky_s4;
      e_res_s4r        <= e_res_s4;
      rsign_s4         <= rsign_s3r;
      y_special_s4     <= y_special_s3;
      flags_special_s4 <= flags_special_s3;
      special_s4       <= special_s3;
      rm_s4            <= rm_s3;
      v4               <= v3;
    end
  end

  // ============================================================ stage 5
  // rounding (normal + subnormal) and result encoding
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
    sig     = norm_s4r[TARGET -: S_W];
    g       = norm_s4r[2];
    r       = norm_s4r[1];
    s_bit   = norm_s4r[0] | norm_sticky_s4r;
    lsb     = sig[0];
    inexact = g | r | s_bit;
    case (rm_s4)
      fp_pkg::RM_RNE: round_up = g & (r | s_bit) | (g & ~r & ~s_bit & lsb);
      fp_pkg::RM_RNA: round_up = g;
      fp_pkg::RM_RZ:  round_up = 1'b0;
      fp_pkg::RM_RP:  round_up = ~rsign_s4 & inexact;
      fp_pkg::RM_RM:  round_up = rsign_s4 & inexact;
      default:        round_up = 1'b0;
    endcase
    carry = round_up && (sig == {S_W{1'b1}});
    if (carry) begin
      sig_rnd = {1'b1, {W_MANT{1'b0}}};
      e_rnd   = e_res_s4r + 1;
    end else begin
      sig_rnd = sig + { {S_W-1{1'b0}}, round_up };
      e_rnd   = e_res_s4r;
    end
    exp_fld = e_rnd[W_EXP-1:0] + BIAS[W_EXP-1:0];
    if ($signed(e_rnd) > EMAX_S) begin
      case (rm_s4)
        fp_pkg::RM_RNE,
        fp_pkg::RM_RNA: y_normal = {rsign_s4, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        fp_pkg::RM_RZ:  y_normal = {rsign_s4, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
        fp_pkg::RM_RP:  y_normal = rsign_s4 ? {1'b1, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}}
                                            : {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        fp_pkg::RM_RM:  y_normal = rsign_s4 ? {1'b1, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}}
                                            : {1'b0, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
        default:        y_normal = {rsign_s4, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      endcase
      flags_normal = (1 << fp_pkg::FLAG_OVERFLOW) | (1 << fp_pkg::FLAG_INEXACT);
    end else begin
      y_normal = {rsign_s4, exp_fld, sig_rnd[MANT_W-1:0]};
      flags_normal = inexact ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
    end
  end

  logic [W-1:0] y_sub;
  logic [4:0]   flags_sub;
  generate
    if (W_MANT > 0) begin : g_subnormal
      always_comb begin
        int signed          shift;
        /* verilator lint_off UNUSEDSIGNAL */
        logic [NORM_W-1:0]  shifted;
        /* verilator lint_on UNUSEDSIGNAL */
        logic [S_W-1:0]     sig_s;
        logic               gs, rs, ss, inexact_s, up_s;
        logic [S_W-1:0]     sig_s2;
        shift = int'(EMIN - int'(e_res_s4r));
        if (shift > 0) shifted = norm_s4r >> shift;
        else           shifted = '0;
        sig_s  = shifted[TARGET -: S_W];
        gs     = shifted[2];
        rs     = shifted[1];
        ss     = shifted[0] | norm_sticky_s4r
               | |(norm_s4r & (((NORM_W)'(1) << (shift > 0 ? shift : 0)) - 1));
        inexact_s = gs | rs | ss;
        case (rm_s4)
          fp_pkg::RM_RNE: up_s = gs & (rs | ss) | (gs & ~rs & ~ss & sig_s[0]);
          fp_pkg::RM_RNA: up_s = gs;
          fp_pkg::RM_RZ:  up_s = 1'b0;
          fp_pkg::RM_RP:  up_s = ~rsign_s4 & inexact_s;
          fp_pkg::RM_RM:  up_s = rsign_s4 & inexact_s;
          default:        up_s = 1'b0;
        endcase
        sig_s2 = sig_s + { {S_W-1{1'b0}}, up_s };
        if (sig_s2 == {1'b1, {W_MANT{1'b0}}}) begin
          if (EMIN > EMAX &&
              ((gs && rs) || (rm_s4 == fp_pkg::RM_RP && ~rsign_s4 && gs)
                         || (rm_s4 == fp_pkg::RM_RM && rsign_s4 && gs))) begin
            case (rm_s4)
              fp_pkg::RM_RNE,
              fp_pkg::RM_RNA: y_sub = {rsign_s4, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
              fp_pkg::RM_RZ:  y_sub = {rsign_s4, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
              fp_pkg::RM_RP:  y_sub = rsign_s4 ? {1'b1, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}}
                                               : {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
              fp_pkg::RM_RM:  y_sub = rsign_s4 ? {1'b1, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}}
                                               : {1'b0, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
              default:        y_sub = {rsign_s4, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
            endcase
            flags_sub = (1 << fp_pkg::FLAG_OVERFLOW) | (1 << fp_pkg::FLAG_INEXACT);
          end else begin
            y_sub = {rsign_s4, {W_EXP-1{1'b0}}, 1'b1, {W_MANT{1'b0}}};
            flags_sub = inexact_s ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
          end
        end else if (sig_s2 == '0) begin
          y_sub = {rsign_s4, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
          flags_sub = inexact_s ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
        end else begin
          y_sub = {rsign_s4, {W_EXP{1'b0}}, sig_s2[MANT_W-1:0]};
          flags_sub = 5'd0;
          if (inexact_s) begin
            flags_sub[fp_pkg::FLAG_UNDERFLOW] = 1'b1;
            flags_sub[fp_pkg::FLAG_INEXACT]   = 1'b1;
          end
        end
      end
    end else begin : g_no_subnormal
      assign y_sub     = {rsign_s4, {W_EXP{1'b0}}};
      assign flags_sub = 5'd0;
    end
  endgenerate

  logic [W-1:0] y_cancel;
  assign y_cancel = {(rm_s4 == fp_pkg::RM_RM), {W_EXP{1'b0}}, {W_MANT{1'b0}}};

  logic [W-1:0] y_comb;
  logic [4:0]   flags_comb;
  always_comb begin
    if (special_s4) begin
      y_comb     = y_special_s4;
      flags_comb = flags_special_s4;
    end else if (cancel_s3r) begin
      y_comb     = y_cancel;
      flags_comb = 5'd0;
    end else if ($signed(e_res_s4r) >= EMIN_S) begin
      y_comb     = y_normal;
      flags_comb = flags_normal;
    end else begin
      y_comb     = y_sub;
      flags_comb = flags_sub;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      y         <= '0;
      flags     <= 5'd0;
      out_valid <= 1'b0;
    end else begin
      y         <= y_comb;
      flags     <= flags_comb;
      out_valid <= v4;
    end
  end

endmodule
