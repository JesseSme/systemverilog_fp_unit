// Copyright 2026 Jesse Smedberg
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Pipelined IEEE 754-2019 fused multiply-add: (a x b) + c, single rounding.
//
// Same semantics as jsm_fp_fma.sv (special cases, exact sum, single GRS
// rounding, subnormal/overflow rules). The exact significand product comes
// from the LUT-only jsm_fp_mul_core. The addend is aligned while the core
// runs and added to the core's two carry-save rows in place of the core's
// own final carry-propagate add, so the FMA takes as many cycles as a
// multiply (jsm_fp_mul_pipe):
//
//   C0   unpack/classify/special; core stage A; alignment of c from the
//        exponent fields alone (no bit-length scan: a significand's LSB
//        weight is max(exp, 1) - BIAS - W_MANT, subnormal or not)
//   B    the core's last stage, down to two rows X + Y = P; c shifted into
//        place in parallel (a stage of its own with the three-stage core,
//        W_MANT + 1 > 32); then the sign-magnitude add, two ternary adders
//        X + Y + C' with carry-in 0 / 1, selected by the sign of P - C
//   N    normalize (leading one + shift) and the subnormal-candidate shift,
//        both from the accumulator
//   R    GRS round, overflow/subnormal, encode
//
// Fixed latency: 4 cycles (W_MANT + 1 <= 32) / 5 from `start` to `out_valid`
// (jsm_fp_pkg::lat_fma), equal to jsm_fp_pkg::lat_mul.
//
// Accumulator (ACC_W = L + 3p + 2 bits, p = W_MANT + 1): the product P (2p
// bits) is fixed at bits [L, L + 2p); c (p bits) is placed with its LSB at
// L + d, d = (LSB weight of c) - (LSB weight of P). Out of range:
//   d >= D_HI = 2p + 2   c is placed at L + D_HI and P only contributes a
//                        sticky (P < 2^(L+2p) is below a quarter ulp of c)
//   L + d < 0            the bits of c below acc bit 0 become a sticky
// The sticky operand is always the smaller one, so the sum is represented
// as acc + f with f in (0, 1) (acc = larger - smaller - 1, sticky set), and
// every acc bit is a bit of the exact sum. When c is partly below bit 0, P
// has a normal factor (two subnormal factors and a nonzero c put c far above
// P), so P >= 2^(L+p-1) and c < 2^(p-1): the sum's leading one is at
// >= L + p - 2 and its guard bit at >= L - 2. L = 2 is therefore the
// minimum: the round bit can fall below bit 0, but the sticky is then set,
// and with the sticky set no rounding mode depends on the round bit.
// tests/fma_equiv.py checks this (L = 1 fails it).

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */

module jsm_fp_fma_pipe #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23
) (
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
  input  logic [1+W_EXP+W_MANT-1:0] c,
  input  jsm_fp_pkg::rounding_t         rm,
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
  localparam int TARGET  = S_W + 2;
  localparam int FW      = S_W + 3;
  localparam int P_W     = 2 * S_W;
  localparam int L       = 2;                   // accumulator bits below P
  localparam int D_HI    = 2 * S_W + 2;         // c alignment saturation
  localparam int ACC_W   = L + 3 * S_W + 2;
  localparam int CF_W    = ACC_W + S_W;         // c frame: S_W sticky bits below acc bit 0
  localparam int K_SAT   = L + D_HI + S_W;      // largest c frame shift
  localparam int K_W     = $clog2(K_SAT + 1);
  // signed exponent width: covers every BE, e_res and shift value below
  localparam int XW      = $clog2(4 * S_W + 16 + (1 << (W_EXP + 2))) + 1;
  localparam int EXP_ALL = (1 << W_EXP) - 1;
  localparam int EXP_MAXF = (1 << W_EXP) - 2;
  localparam logic [MANT_W-1:0] QUIET = (MANT_W)'(1) << (MANT_W - 1);
  localparam logic signed [XW-1:0] EMAX_S = XW'(EMAX);
  localparam logic signed [XW-1:0] EMIN_S = XW'(EMIN);
  localparam bit CORE_TWO_STAGE = (S_W <= 32);


  // ============================================================ cycle 0
  logic              a_sign, b_sign, c_sign;
  logic [W_EXP-1:0]  a_exp, b_exp, c_exp;
  logic [MANT_W-1:0] a_mant, b_mant, c_mant;
  assign a_sign = a[W-1];
  assign a_exp  = a[W-2 -: W_EXP];
  assign b_sign = b[W-1];
  assign b_exp  = b[W-2 -: W_EXP];
  assign c_sign = c[W-1];
  assign c_exp  = c[W-2 -: W_EXP];
  always_comb begin
    a_mant = '0;
    b_mant = '0;
    c_mant = '0;
    if (W_MANT > 0) begin
      a_mant = a[W_MANT-1:0];
      b_mant = b[W_MANT-1:0];
      c_mant = c[W_MANT-1:0];
    end
  end

  logic a_nan, a_snan, a_inf, a_zero, a_sub;
  logic b_nan, b_snan, b_inf, b_zero, b_sub;
  logic c_nan, c_snan, c_inf, c_zero, c_sub;
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
  assign c_nan  = (c_exp == EXP_ALL[W_EXP-1:0]) && (c_mant != '0);
  assign c_snan = c_nan && !c_mant[MANT_W-1];
  assign c_inf  = (c_exp == EXP_ALL[W_EXP-1:0]) && (c_mant == '0);
  assign c_zero = (c_exp == '0) && (c_mant == '0);
  assign c_sub  = (c_exp == '0) && (c_mant != '0);

  logic [W-1:0] y_special;
  logic [4:0]   flags_special;
  logic         special_case;
  logic         prod_sign;
  assign prod_sign = a_sign ^ b_sign;
  always_comb begin
    y_special    = '0;
    flags_special = '0;
    special_case = 1'b0;
    if (a_nan || b_nan || c_nan) begin
      y_special = {1'b0, EXP_ALL[W_EXP-1:0],
                   (a_nan ? a_mant : (b_nan ? b_mant : c_mant)) | QUIET};
      flags_special[jsm_fp_pkg::FLAG_INVALID] = a_snan || b_snan || c_snan;
      special_case = 1'b1;
    end else if ((a_inf && b_zero) || (a_zero && b_inf)) begin
      y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
      flags_special[jsm_fp_pkg::FLAG_INVALID] = 1'b1;
      special_case = 1'b1;
    end else if (a_inf || b_inf) begin
      if (c_inf && (c_sign != prod_sign)) begin
        y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
        flags_special[jsm_fp_pkg::FLAG_INVALID] = 1'b1;
      end else begin
        y_special = {prod_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      end
      special_case = 1'b1;
    end else if (c_inf) begin
      y_special = {c_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      special_case = 1'b1;
    end else if (a_zero || b_zero) begin
      if (c_zero) begin
        y_special = {(prod_sign == c_sign) ? prod_sign : (rm == jsm_fp_pkg::RM_RM),
                     {W_EXP{1'b0}}, {W_MANT{1'b0}}};
      end else begin
        y_special = c;
      end
      special_case = 1'b1;
    end
  end

  logic [S_W-1:0] s_a, s_b, s_c;
  assign s_a = a_sub ? {1'b0, a_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, a_mant};
  assign s_b = b_sub ? {1'b0, b_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, b_mant};
  assign s_c = c_sub ? {1'b0, c_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, c_mant};

  // the product in carry-save form (cs0 + cs1), in the core's last stage
  logic [P_W-1:0] cs0, cs1;
  logic           cs_valid;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [P_W-1:0] p_nc;  // the core's registered product: not used here
  logic           pv_nc;
  /* verilator lint_on UNUSEDSIGNAL */
  jsm_fp_mul_core #(.W(S_W)) u_core (
    .clk(clk), .rst_n(rst_n), .start(start),
    .a(s_a), .b(s_b), .p(p_nc), .out_valid(pv_nc),
    .cs0(cs0), .cs1(cs1), .cs_valid(cs_valid)
  );

  // Alignment. With the effective exponent ef = max(exp, 1), the LSB weight
  // of a significand is ef - BIAS - W_MANT, so
  //   d  = LSB(c) - LSB(P) = ec - ea - eb + BIAS + W_MANT
  //   k  = L + d + S_W     shift of c in the frame (clamped to [0, K_SAT])
  //   BE = weight of acc bit 0: LSB(P) - L, or LSB(c) - L - D_HI saturated
  // c = 0 is placed as 0 (s_c_s1 cleared) and never saturates.
  logic [W_EXP-1:0]       ea, eb, ec;
  logic [K_W-1:0]         k_c0;
  logic                   sat_c0;
  logic signed [XW-1:0]   ben_c0, bes_c0;
  assign ea = (a_exp == '0) ? (W_EXP)'(1) : a_exp;
  assign eb = (b_exp == '0) ? (W_EXP)'(1) : b_exp;
  assign ec = (c_exp == '0) ? (W_EXP)'(1) : c_exp;
  always_comb begin
    int dd, kk;
    dd = int'(ec) - int'(ea) - int'(eb) + BIAS + W_MANT;
    kk = dd + L + S_W;
    sat_c0 = !c_zero && (dd >= D_HI);
    if (kk >= K_SAT)  k_c0 = (K_W)'(K_SAT);
    else if (kk <= 0) k_c0 = '0;
    else              k_c0 = (K_W)'(kk);
    // both BE candidates; the choice by sat waits until stage B
    bes_c0 = (XW)'(int'(ec) - BIAS - W_MANT - L - D_HI);
    ben_c0 = (XW)'(int'(ea) + int'(eb) - 2 * BIAS - 2 * W_MANT - L);
  end

  // ------------------------------------------------ C0 -> B registers
  logic [W-1:0]         y_special_s1;
  logic [4:0]           flags_special_s1;
  logic                 special_s1, prod_sign_s1, c_sign_s1, sat_s1;
  logic [S_W-1:0]       s_c_s1;
  logic [K_W-1:0]       k_s1;
  logic signed [XW-1:0] ben_s1, bes_s1;
  logic [2:0]           rm_s1;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      y_special_s1     <= '0;
      flags_special_s1 <= 5'd0;
      special_s1       <= 1'b0;
      prod_sign_s1     <= 1'b0;
      c_sign_s1        <= 1'b0;
      sat_s1           <= 1'b0;
      s_c_s1           <= '0;
      k_s1             <= '0;
      ben_s1           <= '0;
      bes_s1           <= '0;
      rm_s1            <= 3'd0;
    end else begin
      y_special_s1     <= y_special;
      flags_special_s1 <= flags_special;
      special_s1       <= special_case;
      prod_sign_s1     <= prod_sign;
      c_sign_s1        <= c_sign;
      sat_s1           <= sat_c0;
      s_c_s1           <= c_zero ? '0 : s_c;  // (s_c has the hidden bit set for 0)
      k_s1             <= k_c0;
      ben_s1           <= ben_c0;
      bes_s1           <= bes_c0;
      rm_s1            <= rm;
    end
  end

  // ------------------------------------------------ place c
  // c in a frame whose low S_W bits lie below acc bit 0 (they form the
  // alignment sticky), shifted left by k. With the two-stage core this runs
  // in the core's last stage, in parallel with its reduction levels; with
  // the three-stage core it gets a stage of its own (g_ctx3 registers).
  logic [ACC_W-1:0] pc_c1;
  logic             stc_c1;
  always_comb begin
    logic [CF_W-1:0] fr;
    fr     = (CF_W)'(s_c_s1) << k_s1;
    pc_c1  = fr[CF_W-1:S_W];
    stc_c1 = |fr[S_W-1:0];
  end

  logic signed [XW-1:0] be_c1;
  assign be_c1 = sat_s1 ? bes_s1 : ben_s1;

  // Context of the add stage, aligned with the core's carry-save rows.
  logic [W-1:0]         y_special_x;
  logic [4:0]           flags_special_x;
  logic                 special_x, prod_sign_x, c_sign_x, sat_x, stc_x;
  logic [ACC_W-1:0]     pc_x;
  logic signed [XW-1:0] be_x;
  logic [2:0]           rm_x;

  generate
    if (CORE_TWO_STAGE) begin : g_ctx2
      assign y_special_x     = y_special_s1;
      assign flags_special_x = flags_special_s1;
      assign special_x       = special_s1;
      assign prod_sign_x     = prod_sign_s1;
      assign c_sign_x        = c_sign_s1;
      assign sat_x           = sat_s1;
      assign stc_x           = stc_c1;
      assign pc_x            = pc_c1;
      assign be_x            = be_c1;
      assign rm_x            = rm_s1;
    end else begin : g_ctx3
      always_ff @(posedge clk) begin
        if (!rst_n) begin
          y_special_x     <= '0;
          flags_special_x <= 5'd0;
          special_x       <= 1'b0;
          prod_sign_x     <= 1'b0;
          c_sign_x        <= 1'b0;
          sat_x           <= 1'b0;
          stc_x           <= 1'b0;
          pc_x            <= '0;
          be_x            <= '0;
          rm_x            <= 3'd0;
        end else begin
          y_special_x     <= y_special_s1;
          flags_special_x <= flags_special_s1;
          special_x       <= special_s1;
          prod_sign_x     <= prod_sign_s1;
          c_sign_x        <= c_sign_s1;
          sat_x           <= sat_s1;
          stc_x           <= stc_c1;
          pc_x            <= pc_c1;
          be_x            <= be_c1;
          rm_x            <= rm_s1;
        end
      end
    end
  endgenerate

  // ============================================================ add (last core stage)
  // The product is P = X + Y (the core's two carry-save rows, at bits
  // [L, L + 2p)), or 0 with a sticky when c saturated. At most one of the
  // stickies is set, and it belongs to the smaller operand, so
  //   larger - smaller - sticky = acc, true value acc + f, f in (0, 1).
  // Two ternary adders on X + Y + C' (C' = C, or ~C for a difference) with
  // carry-in 0 and 1 give every case (T1 adds X | 1 = X + 1, bit 0 of X
  // being 0, so it is a parallel adder, not an incrementer after T0):
  //   P + C            = T0                      (same signs)
  //   P - C - stc      = stc ? T0 : T1           (selected if >= 0)
  //   C - P - stp      = ~(stp ? T1 : T0)        (otherwise; ~z = -z - 1)
  // with stp = sat. Exact cancellation (acc = 0) is detected in stage N.
  logic [ACC_W:0] xr_a, yr_a, cx_a, t0_a, t1_a, dpc_a, acc_a;
  logic           same_a, rsign_a;
  assign same_a = (prod_sign_x == c_sign_x);
  assign xr_a   = sat_x ? '0 : ((ACC_W+1)'(cs0) << L);
  assign yr_a   = sat_x ? '0 : ((ACC_W+1)'(cs1) << L);
  assign cx_a   = same_a ? {1'b0, pc_x} : ~{1'b0, pc_x};
  assign t0_a   = xr_a + yr_a + cx_a;
  assign t1_a   = (xr_a | (ACC_W+1)'(1)) + yr_a + cx_a;
  assign dpc_a  = stc_x ? t0_a : t1_a;
  always_comb begin
    if (same_a) begin
      acc_a   = t0_a;
      rsign_a = prod_sign_x;
    end else if (dpc_a[ACC_W]) begin
      acc_a   = ~(sat_x ? t1_a : t0_a);
      rsign_a = c_sign_x;
    end else begin
      acc_a   = dpc_a;
      rsign_a = prod_sign_x;
    end
  end

  // Subnormal-candidate shift sh = BE - (EMIN - W_MANT) + 3 and, for
  // sh < 0, the mask of the accumulator bits it drops (for stage N).
  logic signed [XW-1:0] shs_a;
  logic [ACC_W:0]       smask_a;
  always_comb begin
    int sh;
    sh = int'(be_x) + W_MANT + 3 - EMIN;
    shs_a = (XW)'(sh);
    smask_a = '0;
    if (sh < 0) begin
      if (-sh >= ACC_W + 1) smask_a = '1;
      else                  smask_a = ((ACC_W+1)'(1) << (-sh)) - 1;
    end
  end

  logic [ACC_W:0]       acc_r, smask_r;
  logic                 rsign_r, sticky_r;
  logic signed [XW-1:0] be_r, shs_r;
  logic [2:0]           rm_r;
  logic [W-1:0]         y_special_r;
  logic [4:0]           flags_special_r;
  logic                 special_r;
  logic                 a_valid;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      acc_r           <= '0;
      smask_r         <= '0;
      rsign_r         <= 1'b0;
      sticky_r        <= 1'b0;
      be_r            <= '0;
      shs_r           <= '0;
      rm_r            <= 3'd0;
      y_special_r     <= '0;
      flags_special_r <= 5'd0;
      special_r       <= 1'b0;
      a_valid         <= 1'b0;
    end else begin
      acc_r           <= acc_a;
      smask_r         <= smask_a;
      rsign_r         <= rsign_a;
      sticky_r        <= stc_x | sat_x;
      be_r            <= be_x;
      shs_r           <= shs_a;
      rm_r            <= rm_x;
      y_special_r     <= y_special_x;
      flags_special_r <= flags_special_x;
      special_r       <= special_x;
      a_valid         <= cs_valid;
    end
  end

  // The sum is never 0 except by exact cancellation: P != 0 outside the
  // special cases, and a sticky difference is >= 1.
  logic cancel_n;
  assign cancel_n = (acc_r == '0);

  // ============================================================ stage N
  // Leading one p0 of the accumulator: result exponent BE + p0.
  int                   p0_n;
  logic [FW-1:0]        norm_n;
  logic                 norm_sticky_n;
  logic signed [XW-1:0] e_res_n;
  always_comb begin
    p0_n = 0;
    norm_sticky_n = 1'b0;
    for (int i = 0; i <= ACC_W; i++)
      if (acc_r[i]) p0_n = i;
    if (p0_n > TARGET) begin
      norm_n = acc_r >> (p0_n - TARGET);
      norm_sticky_n = sticky_r
                    | |(acc_r & (((ACC_W+1)'(1) << (p0_n - TARGET)) - 1));
    end else if (p0_n < TARGET) begin
      norm_n = acc_r << (TARGET - p0_n);
      norm_sticky_n = sticky_r;
    end else begin
      norm_n = acc_r;
      norm_sticky_n = sticky_r;
    end
    e_res_n = be_r + (XW)'(p0_n);
  end

  // Subnormal candidate, from the accumulator directly (independent of p0):
  // value = acc * 2^BE, so the shift onto the subnormal grid (with the guard,
  // round and sticky positions at [2:0]) is sh = BE - (EMIN - W_MANT) + 3;
  // sh and the mask of the bits a right shift drops come registered.
  logic [FW-1:0] shifted_sub_n;
  logic          sub_sticky_n;
  always_comb begin
    int sh;
    sh = int'(shs_r);
    shifted_sub_n = '0;
    sub_sticky_n  = sticky_r | (|(acc_r & smask_r));
    if (sh >= 0) begin
      // left shift: exact; out of the subnormal range the value is unused
      if (sh < FW) shifted_sub_n = (FW)'(acc_r << sh);
    end else if (-sh < ACC_W + 1) begin
      shifted_sub_n = (FW)'(acc_r >> (-sh));
    end
  end

  logic [FW-1:0]        norm_f4r;
  logic                 norm_sticky_f4r;
  logic [FW-1:0]        shifted_sub_r;
  logic                 sub_sticky_r;
  logic signed [XW-1:0] e_res_f4r;
  logic                 rsign_f4;
  logic                 cancel_f4;
  logic                 special_f4;
  logic [W-1:0]         y_special_f4;
  logic [4:0]           flags_special_f4;
  logic [2:0]           rm_f4;
  logic                 f4_valid;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      norm_f4r         <= '0;
      norm_sticky_f4r  <= 1'b0;
      shifted_sub_r    <= '0;
      sub_sticky_r     <= 1'b0;
      e_res_f4r        <= '0;
      rsign_f4         <= 1'b0;
      cancel_f4        <= 1'b0;
      special_f4       <= 1'b0;
      y_special_f4     <= '0;
      flags_special_f4 <= 5'd0;
      rm_f4            <= 3'd0;
      f4_valid         <= 1'b0;
    end else begin
      norm_f4r         <= norm_n;
      norm_sticky_f4r  <= norm_sticky_n;
      shifted_sub_r    <= shifted_sub_n;
      sub_sticky_r     <= sub_sticky_n;
      e_res_f4r        <= e_res_n;
      rsign_f4         <= rsign_r;
      cancel_f4        <= cancel_n;
      special_f4       <= special_r;
      y_special_f4     <= y_special_r;
      flags_special_f4 <= flags_special_r;
      rm_f4            <= rm_r;
      f4_valid         <= a_valid;
    end
  end

  // ============================================================ stage R
  logic [S_W-1:0] sig;
  logic           g, r, s_bit, lsb, inexact, round_up, carry;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [S_W-1:0] sig_rnd;
  /* verilator lint_on UNUSEDSIGNAL */
  logic signed [XW-1:0] e_rnd;
  logic [W-1:0]   y_normal;
  logic [4:0]     flags_normal;
  logic [2:0]     rm_f5;
  assign rm_f5 = rm_f4;
  always_comb begin
    logic [W_EXP-1:0] exp_fld;
    sig     = norm_f4r[TARGET -: S_W];
    g       = norm_f4r[2];
    r       = norm_f4r[1];
    s_bit   = norm_f4r[0] | norm_sticky_f4r;
    lsb     = sig[0];
    inexact = g | r | s_bit;
    case (rm_f5)
      jsm_fp_pkg::RM_RNE: round_up = g & (r | s_bit) | (g & ~r & ~s_bit & lsb);
      jsm_fp_pkg::RM_RNA: round_up = g;
      jsm_fp_pkg::RM_RZ:  round_up = 1'b0;
      jsm_fp_pkg::RM_RP:  round_up = ~rsign_f4 & inexact;
      jsm_fp_pkg::RM_RM:  round_up = rsign_f4 & inexact;
      default:        round_up = 1'b0;
    endcase
    carry = round_up && (sig == {S_W{1'b1}});
    if (carry) begin
      sig_rnd = {1'b1, {W_MANT{1'b0}}};
      e_rnd   = e_res_f4r + 1;
    end else begin
      sig_rnd = sig + { {S_W-1{1'b0}}, round_up };
      e_rnd   = e_res_f4r;
    end
    exp_fld = e_rnd[W_EXP-1:0] + BIAS[W_EXP-1:0];
    if ($signed(e_rnd) > EMAX_S) begin
      case (rm_f5)
        jsm_fp_pkg::RM_RNE,
        jsm_fp_pkg::RM_RNA: y_normal = {rsign_f4, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        jsm_fp_pkg::RM_RZ:  y_normal = {rsign_f4, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
        jsm_fp_pkg::RM_RP:  y_normal = rsign_f4 ? {1'b1, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}}
                                            : {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        jsm_fp_pkg::RM_RM:  y_normal = rsign_f4 ? {1'b1, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}}
                                            : {1'b0, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
        default:        y_normal = {rsign_f4, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      endcase
      flags_normal = (1 << jsm_fp_pkg::FLAG_OVERFLOW) | (1 << jsm_fp_pkg::FLAG_INEXACT);
    end else begin
      y_normal = {rsign_f4, exp_fld, sig_rnd[MANT_W-1:0]};
      flags_normal = inexact ? (1 << jsm_fp_pkg::FLAG_INEXACT) : 5'd0;
    end
  end

  logic [W-1:0] y_sub;
  logic [4:0]   flags_sub;
  generate
    if (W_MANT > 0) begin : g_subnormal
      always_comb begin
        logic [FW-1:0]      shifted;
        logic [S_W-1:0]     sig_s;
        logic               gs, rs, ss, inexact_s, up_s;
        logic [S_W-1:0]     sig_s2;
        // The shift to the subnormal grid was computed from the
        // accumulator and registered in stage N
        // (shifted_sub_r / sub_sticky_r); it does not wait on the
        // leading-one position or e_res_f4r.
        shifted = shifted_sub_r;
        sig_s  = shifted[TARGET -: S_W];
        gs     = shifted[2];
        rs     = shifted[1];
        ss     = shifted[0] | sub_sticky_r;
        inexact_s = gs | rs | ss;
        case (rm_f5)
          jsm_fp_pkg::RM_RNE: up_s = gs & (rs | ss) | (gs & ~rs & ~ss & sig_s[0]);
          jsm_fp_pkg::RM_RNA: up_s = gs;
          jsm_fp_pkg::RM_RZ:  up_s = 1'b0;
          jsm_fp_pkg::RM_RP:  up_s = ~rsign_f4 & inexact_s;
          jsm_fp_pkg::RM_RM:  up_s = rsign_f4 & inexact_s;
          default:        up_s = 1'b0;
        endcase
        sig_s2 = sig_s + { {S_W-1{1'b0}}, up_s };
        if (sig_s2 == {1'b1, {W_MANT{1'b0}}}) begin
          if (EMIN > EMAX &&
              ((gs && rs) || (rm_f5 == jsm_fp_pkg::RM_RP && ~rsign_f4 && gs)
                          || (rm_f5 == jsm_fp_pkg::RM_RM && rsign_f4 && gs))) begin
            case (rm_f5)
              jsm_fp_pkg::RM_RNE,
              jsm_fp_pkg::RM_RNA: y_sub = {rsign_f4, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
              jsm_fp_pkg::RM_RZ:  y_sub = {rsign_f4, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
              jsm_fp_pkg::RM_RP:  y_sub = rsign_f4 ? {1'b1, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}}
                                               : {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
              jsm_fp_pkg::RM_RM:  y_sub = rsign_f4 ? {1'b1, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}}
                                               : {1'b0, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
              default:        y_sub = {rsign_f4, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
            endcase
            flags_sub = (1 << jsm_fp_pkg::FLAG_OVERFLOW) | (1 << jsm_fp_pkg::FLAG_INEXACT);
          end else begin
            y_sub = {rsign_f4, {W_EXP-1{1'b0}}, 1'b1, {W_MANT{1'b0}}};
            flags_sub = inexact_s ? (1 << jsm_fp_pkg::FLAG_INEXACT) : 5'd0;
          end
        end else if (sig_s2 == '0) begin
          y_sub = {rsign_f4, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
          flags_sub = inexact_s ? (1 << jsm_fp_pkg::FLAG_INEXACT) : 5'd0;
        end else begin
          y_sub = {rsign_f4, {W_EXP{1'b0}}, sig_s2[MANT_W-1:0]};
          flags_sub = 5'd0;
          if (inexact_s) begin
            flags_sub[jsm_fp_pkg::FLAG_UNDERFLOW] = 1'b1;
            flags_sub[jsm_fp_pkg::FLAG_INEXACT]   = 1'b1;
          end
        end
      end
    end else begin : g_no_subnormal
      assign y_sub     = {rsign_f4, {W_EXP{1'b0}}};
      assign flags_sub = 5'd0;
    end
  endgenerate

  logic [W-1:0] y_cancel;
  assign y_cancel = {(rm_f5 == jsm_fp_pkg::RM_RM), {W_EXP{1'b0}}, {W_MANT{1'b0}}};

  // Stage R: result select and output register (the *_f4 registers are stage N's).
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      y         <= '0;
      flags     <= 5'd0;
      out_valid <= 1'b0;
    end else begin
      if (special_f4) begin
        y     <= y_special_f4;
        flags <= flags_special_f4;
      end else if (cancel_f4) begin
        y     <= y_cancel;
        flags <= 5'd0;
      end else if ($signed(e_res_f4r) >= EMIN_S) begin
        y     <= y_normal;
        flags <= flags_normal;
      end else begin
        y     <= y_sub;
        flags <= flags_sub;
      end
      out_valid <= f4_valid;
    end
  end

endmodule
