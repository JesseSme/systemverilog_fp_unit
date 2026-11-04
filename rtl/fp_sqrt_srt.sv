// Pipelined radix-4 SRT square root (carry-save remainder, on-the-fly root).
//
// Fully unrolled, DPS radix-4 root digits per stage, one start per cycle.
// Latency = 1 (setup) + ceil(NDIG/DPS) + FOLD_STG + 1 (correct/round/encode).
//
// Integer recurrence (Xp = radicand zero-padded so every step consumes 4 bits):
//   preload: v = top 4 bits, d0 = 2 if v<9 else 3, q = d0, R = v - d0^2
//   step:    p = 16R + bits ; R' = p - d(8q+d) ; q' = 4q+d, d in {-4..4}
// The invariant is |R| <= 2q (non-restoring sqrt); the much wider digit
// intervals from that loose bound give the selection huge tolerance, so the
// digit is chosen from the carry-save estimate of p by comparing against
// q*(8k+4) for k=-4..3 (d = count - 4, i.e. round(p/(8q))). The first digit
// (q<4) uses an exact small-q selection. Negative digits are absorbed by the
// on-the-fly Q/QM registers (QM = Q-1), and the final sign correction picks
// Q or QM and recomputes the sticky.
//
// The remainder is kept in fixed-width carry-save (S,C), both modulo 2^CSW,
// with no carry-propagate fold between digits (the recurrence is linear, so
// S+C stays congruent to the true residual). At digit t the estimate reads
// the EW-bit window starting at bit 2t-6 of S and C and adds them modulo
// 2^EW; the true estimate is below 2^9 in magnitude, so the wrapped sum is
// exact once the window lies inside CSW (2(NDIG-1)-6+EW <= CSW). The final
// residual |R| <= 2q+4 < 2^(2*NDIG+3) is recovered as the CSW-bit signed
// value of S+C. With EW = 12, CSW = 2*NDIG+4 is the minimum (checked on the
// fixed-width model, exhaustively for S_W <= 12); CSW = 2*NDIG+5 keeps one
// bit of margin.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */

module fp_sqrt_srt #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23,
  parameter int DPS    = 2,
  parameter int FOLD_STG = 0,  // 1: register after the final fold (+1 cycle)
  // 1: fold S+C (carry-propagate, mod 2^CSW) at every stage boundary, so the
  // first estimate of the next stage needs no add (best for DPS >= 2);
  // 0: carry-save crosses the boundaries (no CPA in the stages; DPS = 1)
  parameter int STAGE_FOLD = (DPS >= 2) ? 1 : 0
) (
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  fp_pkg::rounding_t         rm,
  input  logic                      start,
  output logic [1+W_EXP+W_MANT-1:0] y,
  output logic [4:0]                flags,
  input  logic                      clk,
  input  logic                      rst_n,
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
  localparam int EXP_ALL = (1 << W_EXP) - 1;
  localparam int EXP_MAXF = (1 << W_EXP) - 2;
  localparam logic [MANT_W-1:0] QUIET = (MANT_W)'(1) << (MANT_W - 1);
  localparam logic signed [W_EXP+4:0] EMAX_S = (W_EXP+4)'(EMAX);
  localparam logic signed [W_EXP+4:0] EMIN_S = (W_EXP+4)'(EMIN);

  localparam int R_W    = 2 * S_W + 6;             // unpadded radicand width
  localparam int PAD    = (S_W % 2 == 0) ? 2 : 0;  // pad so (RE-4)%4 == 0
  localparam int RE     = R_W + PAD;               // padded radicand width
  localparam int NDIG   = (RE - 4) / 4;            // 4-bit steps
  localparam int NSTG   = (NDIG + DPS - 1) / DPS;
  localparam int CSW    = 2 * NDIG + 5;            // fixed carry-save width (mod 2^CSW)
  localparam int EW     = 12;                      // estimate window width
  localparam int QW     = S_W + 8;                 // root register width
  localparam int PAD_SH = PAD;                     // extra root bits from padding

  // ============================================================ setup
  logic              a_sign;
  logic [W_EXP-1:0]  a_exp;
  logic [MANT_W-1:0] a_mant;
  assign a_sign = a[W-1];
  assign a_exp  = a[W-2 -: W_EXP];
  always_comb begin
    a_mant = '0;
    if (W_MANT > 0) a_mant = a[W_MANT-1:0];
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
    y_special     = '0;
    flags_special = '0;
    special_case  = 1'b0;
    if (a_nan) begin
      y_special = {1'b0, EXP_ALL[W_EXP-1:0], a_mant | QUIET};
      flags_special[fp_pkg::FLAG_INVALID] = a_snan;
      special_case = 1'b1;
    end else if (a_inf) begin
      if (a_sign) begin
        y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
        flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
      end else begin
        y_special = {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      end
      special_case = 1'b1;
    end else if (a_zero) begin
      y_special = {a_sign, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
      special_case = 1'b1;
    end else if (a_sign) begin
      y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
      flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
      special_case = 1'b1;
    end
  end

  logic [S_W-1:0] s_a;
  assign s_a = a_sub ? {1'b0, a_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, a_mant};

  function automatic int unsigned bitlen(input logic [S_W-1:0] x);
    bitlen = 0;
    for (int i = 0; i < S_W; i++)
      if (x[i]) bitlen = i + 1;
  endfunction

  logic signed [W_EXP+2:0] e_a;
  always_comb begin
    int bl_a;
    bl_a = int'(bitlen(s_a));
    e_a = (W_EXP+3)'(a_exp - BIAS);
    if (a_sub) e_a = (W_EXP+3)'((1 - BIAS) - W_MANT + $signed(bl_a) - 1);
  end

  // Radicand Xp (padded): MSB at RE-1 or RE-2, as in fp_divsqrt_iter
  logic [RE-1:0] x_p;
  always_comb begin
    int S;
    S = 2 * TARGET + int'(e_a[0]) - int'(bitlen(s_a)) + 1 + PAD;
    x_p = (RE)'(s_a) << S;
  end

  // preload from the top 4 radicand bits
  logic [3:0]     v4;
  logic [1:0]     d0;
  logic [QW-1:0]  q0;
  logic [CSW-1:0] r0;
  assign v4 = x_p[RE-1 -: 4];
  assign d0 = (v4 >= 4'd9) ? 2'd3 : 2'd2;
  assign q0 = QW'(d0);
  assign r0 = CSW'(v4) - CSW'(d0) * CSW'(d0);

  // sqrt exponent: floor(e_a / 2)
  logic signed [W_EXP+3:0] e_res;
  assign e_res = e_a >>> 1;

  // exact first digit (q < 4 only, i.e. the very first digit): small
  // table over {q[1:0], R[2:0], bits[3:0]} generated from the model
  function automatic logic signed [3:0] first_digit(input logic [1:0] qv,
                                                    input logic [2:0] rv,
                                                    input logic [3:0] bits);
    logic [8:0] idx;
    idx = {qv, rv, bits};
    case (idx)
      9'h100: first_digit = 4'sd0;
      9'h101: first_digit = 4'sd0;
      9'h102: first_digit = 4'sd0;
      9'h103: first_digit = 4'sd0;
      9'h104: first_digit = 4'sd0;
      9'h105: first_digit = 4'sd0;
      9'h106: first_digit = 4'sd0;
      9'h107: first_digit = 4'sd0;
      9'h108: first_digit = 4'sd0;
      9'h109: first_digit = 4'sd1;
      9'h10a: first_digit = 4'sd1;
      9'h10b: first_digit = 4'sd1;
      9'h10c: first_digit = 4'sd1;
      9'h10d: first_digit = 4'sd1;
      9'h10e: first_digit = 4'sd1;
      9'h10f: first_digit = 4'sd1;
      9'h110: first_digit = 4'sd1;
      9'h111: first_digit = 4'sd1;
      9'h112: first_digit = 4'sd1;
      9'h113: first_digit = 4'sd1;
      9'h114: first_digit = 4'sd1;
      9'h115: first_digit = 4'sd1;
      9'h116: first_digit = 4'sd1;
      9'h117: first_digit = 4'sd1;
      9'h118: first_digit = 4'sd1;
      9'h119: first_digit = 4'sd1;
      9'h11a: first_digit = 4'sd1;
      9'h11b: first_digit = 4'sd2;
      9'h11c: first_digit = 4'sd2;
      9'h11d: first_digit = 4'sd2;
      9'h11e: first_digit = 4'sd2;
      9'h11f: first_digit = 4'sd2;
      9'h120: first_digit = 4'sd2;
      9'h121: first_digit = 4'sd2;
      9'h122: first_digit = 4'sd2;
      9'h123: first_digit = 4'sd2;
      9'h124: first_digit = 4'sd2;
      9'h125: first_digit = 4'sd2;
      9'h126: first_digit = 4'sd2;
      9'h127: first_digit = 4'sd2;
      9'h128: first_digit = 4'sd2;
      9'h129: first_digit = 4'sd2;
      9'h12a: first_digit = 4'sd2;
      9'h12b: first_digit = 4'sd2;
      9'h12c: first_digit = 4'sd2;
      9'h12d: first_digit = 4'sd2;
      9'h12e: first_digit = 4'sd2;
      9'h12f: first_digit = 4'sd3;
      9'h130: first_digit = 4'sd3;
      9'h131: first_digit = 4'sd3;
      9'h132: first_digit = 4'sd3;
      9'h133: first_digit = 4'sd3;
      9'h134: first_digit = 4'sd3;
      9'h135: first_digit = 4'sd3;
      9'h136: first_digit = 4'sd3;
      9'h137: first_digit = 4'sd3;
      9'h138: first_digit = 4'sd3;
      9'h139: first_digit = 4'sd3;
      9'h13a: first_digit = 4'sd3;
      9'h13b: first_digit = 4'sd3;
      9'h13c: first_digit = 4'sd3;
      9'h13d: first_digit = 4'sd3;
      9'h13e: first_digit = 4'sd3;
      9'h13f: first_digit = 4'sd3;
      9'h140: first_digit = 4'sd3;
      9'h141: first_digit = 4'sd3;
      9'h142: first_digit = 4'sd3;
      9'h143: first_digit = 4'sd3;
      9'h144: first_digit = 4'sd3;
      9'h145: first_digit = 4'sd4;
      9'h146: first_digit = 4'sd4;
      9'h147: first_digit = 4'sd4;
      9'h148: first_digit = 4'sd4;
      9'h149: first_digit = 4'sd4;
      9'h14a: first_digit = 4'sd4;
      9'h14b: first_digit = 4'sd4;
      9'h14c: first_digit = 4'sd4;
      9'h14d: first_digit = 4'sd4;
      9'h14e: first_digit = 4'sd4;
      9'h14f: first_digit = 4'sd4;
      9'h150: first_digit = 4'sd4;
      9'h151: first_digit = 4'sd4;
      9'h152: first_digit = 4'sd4;
      9'h153: first_digit = 4'sd4;
      9'h154: first_digit = 4'sd4;
      9'h155: first_digit = 4'sd4;
      9'h156: first_digit = 4'sd4;
      9'h157: first_digit = 4'sd4;
      9'h158: first_digit = 4'sd4;
      9'h159: first_digit = 4'sd4;
      9'h15a: first_digit = 4'sd4;
      9'h15b: first_digit = 4'sd4;
      9'h15c: first_digit = 4'sd4;
      9'h15d: first_digit = 4'sd4;
      9'h15e: first_digit = 4'sd4;
      9'h15f: first_digit = 4'sd4;
      9'h160: first_digit = 4'sd4;
      9'h161: first_digit = 4'sd4;
      9'h162: first_digit = 4'sd4;
      9'h163: first_digit = 4'sd4;
      9'h164: first_digit = 4'sd4;
      9'h165: first_digit = 4'sd4;
      9'h166: first_digit = 4'sd4;
      9'h167: first_digit = 4'sd4;
      9'h168: first_digit = 4'sd4;
      9'h169: first_digit = 4'sd0;
      9'h16a: first_digit = 4'sd0;
      9'h16b: first_digit = 4'sd0;
      9'h16c: first_digit = 4'sd0;
      9'h16d: first_digit = 4'sd0;
      9'h16e: first_digit = 4'sd0;
      9'h16f: first_digit = 4'sd0;
      9'h180: first_digit = 4'sd0;
      9'h181: first_digit = 4'sd0;
      9'h182: first_digit = 4'sd0;
      9'h183: first_digit = 4'sd0;
      9'h184: first_digit = 4'sd0;
      9'h185: first_digit = 4'sd0;
      9'h186: first_digit = 4'sd0;
      9'h187: first_digit = 4'sd0;
      9'h188: first_digit = 4'sd0;
      9'h189: first_digit = 4'sd0;
      9'h18a: first_digit = 4'sd0;
      9'h18b: first_digit = 4'sd0;
      9'h18c: first_digit = 4'sd0;
      9'h18d: first_digit = 4'sd1;
      9'h18e: first_digit = 4'sd1;
      9'h18f: first_digit = 4'sd1;
      9'h190: first_digit = 4'sd1;
      9'h191: first_digit = 4'sd1;
      9'h192: first_digit = 4'sd1;
      9'h193: first_digit = 4'sd1;
      9'h194: first_digit = 4'sd1;
      9'h195: first_digit = 4'sd1;
      9'h196: first_digit = 4'sd1;
      9'h197: first_digit = 4'sd1;
      9'h198: first_digit = 4'sd1;
      9'h199: first_digit = 4'sd1;
      9'h19a: first_digit = 4'sd1;
      9'h19b: first_digit = 4'sd1;
      9'h19c: first_digit = 4'sd1;
      9'h19d: first_digit = 4'sd1;
      9'h19e: first_digit = 4'sd1;
      9'h19f: first_digit = 4'sd1;
      9'h1a0: first_digit = 4'sd1;
      9'h1a1: first_digit = 4'sd1;
      9'h1a2: first_digit = 4'sd1;
      9'h1a3: first_digit = 4'sd1;
      9'h1a4: first_digit = 4'sd1;
      9'h1a5: first_digit = 4'sd1;
      9'h1a6: first_digit = 4'sd1;
      9'h1a7: first_digit = 4'sd2;
      9'h1a8: first_digit = 4'sd2;
      9'h1a9: first_digit = 4'sd2;
      9'h1aa: first_digit = 4'sd2;
      9'h1ab: first_digit = 4'sd2;
      9'h1ac: first_digit = 4'sd2;
      9'h1ad: first_digit = 4'sd2;
      9'h1ae: first_digit = 4'sd2;
      9'h1af: first_digit = 4'sd2;
      9'h1b0: first_digit = 4'sd2;
      9'h1b1: first_digit = 4'sd2;
      9'h1b2: first_digit = 4'sd2;
      9'h1b3: first_digit = 4'sd2;
      9'h1b4: first_digit = 4'sd2;
      9'h1b5: first_digit = 4'sd2;
      9'h1b6: first_digit = 4'sd2;
      9'h1b7: first_digit = 4'sd2;
      9'h1b8: first_digit = 4'sd2;
      9'h1b9: first_digit = 4'sd2;
      9'h1ba: first_digit = 4'sd2;
      9'h1bb: first_digit = 4'sd2;
      9'h1bc: first_digit = 4'sd2;
      9'h1bd: first_digit = 4'sd2;
      9'h1be: first_digit = 4'sd2;
      9'h1bf: first_digit = 4'sd2;
      9'h1c0: first_digit = 4'sd2;
      9'h1c1: first_digit = 4'sd2;
      9'h1c2: first_digit = 4'sd2;
      9'h1c3: first_digit = 4'sd3;
      9'h1c4: first_digit = 4'sd3;
      9'h1c5: first_digit = 4'sd3;
      9'h1c6: first_digit = 4'sd3;
      9'h1c7: first_digit = 4'sd3;
      9'h1c8: first_digit = 4'sd3;
      9'h1c9: first_digit = 4'sd3;
      9'h1ca: first_digit = 4'sd3;
      9'h1cb: first_digit = 4'sd3;
      9'h1cc: first_digit = 4'sd3;
      9'h1cd: first_digit = 4'sd3;
      9'h1ce: first_digit = 4'sd3;
      9'h1cf: first_digit = 4'sd3;
      9'h1d0: first_digit = 4'sd3;
      9'h1d1: first_digit = 4'sd3;
      9'h1d2: first_digit = 4'sd3;
      9'h1d3: first_digit = 4'sd3;
      9'h1d4: first_digit = 4'sd3;
      9'h1d5: first_digit = 4'sd3;
      9'h1d6: first_digit = 4'sd3;
      9'h1d7: first_digit = 4'sd3;
      9'h1d8: first_digit = 4'sd3;
      9'h1d9: first_digit = 4'sd3;
      9'h1da: first_digit = 4'sd3;
      9'h1db: first_digit = 4'sd3;
      9'h1dc: first_digit = 4'sd3;
      9'h1dd: first_digit = 4'sd3;
      9'h1de: first_digit = 4'sd3;
      9'h1df: first_digit = 4'sd3;
      9'h1e0: first_digit = 4'sd3;
      9'h1e1: first_digit = 4'sd4;
      9'h1e2: first_digit = 4'sd4;
      9'h1e3: first_digit = 4'sd4;
      9'h1e4: first_digit = 4'sd4;
      9'h1e5: first_digit = 4'sd4;
      9'h1e6: first_digit = 4'sd4;
      9'h1e7: first_digit = 4'sd4;
      9'h1e8: first_digit = 4'sd4;
      9'h1e9: first_digit = 4'sd4;
      9'h1ea: first_digit = 4'sd4;
      9'h1eb: first_digit = 4'sd4;
      9'h1ec: first_digit = 4'sd4;
      9'h1ed: first_digit = 4'sd4;
      9'h1ee: first_digit = 4'sd4;
      9'h1ef: first_digit = 4'sd4;
      default: first_digit = 4'sd0;
    endcase
  endfunction

  // carry-save estimate of p >> (2t-2): EW-bit windows of S and C at bit
  // 2t-6 plus the incoming radicand bits, summed modulo 2^EW
  function automatic logic signed [12:0] est_pe(input logic [CSW-1:0] sv,
                                                input logic [CSW-1:0] cv,
                                                input logic [3:0]     bits,
                                                input int             t);
    logic [CSW+15:0] sz, cz, bz;
    logic [EW-1:0]   ws, wc, wb, sum;
    sz = (CSW+16)'(sv);
    cz = (CSW+16)'(cv);
    bz = (CSW+16)'(bits);
    if (2*t - 6 >= 0) begin ws = EW'(sz >> (2*t - 6)); wc = EW'(cz >> (2*t - 6)); end
    else              begin ws = EW'(sz << (6 - 2*t)); wc = EW'(cz << (6 - 2*t)); end
    if (2*t - 2 >= 0) wb = EW'(bz >> (2*t - 2));
    else              wb = EW'(bz << (2 - 2*t));
    sum    = ws + wc + wb;
    est_pe = 13'($signed(sum));
  endfunction

  // threshold selection (q >= 4): d = count(p >= q*(8k+4), k=-4..3) - 4.
  // At digit t >= 1 the root q has t+1 digits, so qs = q >> (2t-2) lies in
  // [8, 16] (q ~ [2, 4] * 4^t) and |pe| < 2^9: a 6-bit qs and 13-bit
  // compares are exact (the RTL-shaped model in verification/srt checks the
  // ranges), which keeps the threshold multiples off the long carry chains.
  function automatic logic signed [3:0] thr_digit(input logic [QW-1:0] qv,
                                                  input logic signed [12:0] pe,
                                                  input int sh);
    logic [5:0]         qs;
    logic signed [12:0] p, q4, q12, q20, q28;
    logic [3:0]         cnt;              // 0..8 (8 compares)
    qs  = (sh >= 0) ? 6'(qv >> sh) : 6'(qv << (-sh));
    p   = pe;
    q4  = 13'({qs, 2'b00});
    q12 = 13'(q4 * 3);
    q20 = 13'(q4 * 5);
    q28 = 13'(q4 * 7);
    cnt = 4'd0;
    if (p >= -q28) cnt = cnt + 4'd1;
    if (p >= -q20) cnt = cnt + 4'd1;
    if (p >= -q12) cnt = cnt + 4'd1;
    if (p >= -q4)  cnt = cnt + 4'd1;
    if (p >=  q4)  cnt = cnt + 4'd1;
    if (p >=  q12) cnt = cnt + 4'd1;
    if (p >=  q20) cnt = cnt + 4'd1;
    if (p >=  q28) cnt = cnt + 4'd1;
    thr_digit = 4'(cnt - 4'd4);
  endfunction

  // ===================================================== pipeline registers
  logic [CSW-1:0] s_st [0:NSTG];
  logic [CSW-1:0] c_st [0:NSTG];
  logic [QW-1:0]  q_st [0:NSTG];
  logic [QW-1:0]  qm_st [0:NSTG];
  logic [RE-1:0]  x_st [0:NSTG];
  logic           valid_st [0:NSTG];
  logic [W-1:0]   ysp_st [0:NSTG];
  logic [4:0]     fsp_st [0:NSTG];
  logic           sp_st  [0:NSTG];
  logic [2:0]     rm_st  [0:NSTG];
  logic signed [W_EXP+3:0] er_st [0:NSTG];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s_st[0]  <= '0;
      c_st[0]  <= '0;
      q_st[0]  <= '0;
      qm_st[0] <= '1;
      x_st[0]  <= '0;
      valid_st[0] <= 1'b0;
      ysp_st[0] <= '0;
      fsp_st[0] <= 5'd0;
      sp_st[0]  <= 1'b0;
      rm_st[0]  <= 3'd0;
      er_st[0]  <= '0;
    end else if (start) begin
      s_st[0]  <= CSW'(r0);
      c_st[0]  <= '0;
      q_st[0]  <= q0;
      qm_st[0] <= QW'(q0 - 1);
      x_st[0]  <= x_p;
      valid_st[0] <= 1'b1;
      ysp_st[0] <= y_special;
      fsp_st[0] <= flags_special;
      sp_st[0]  <= special_case;
      rm_st[0]  <= rm;
      er_st[0]  <= e_res;
    end else begin
      valid_st[0] <= 1'b0;
    end
  end

  // ===================================================== digit stages
  for (genvar st = 0; st < NSTG; st++) begin : g_stage
    logic [CSW-1:0] s_nxt, c_nxt;
    logic [QW-1:0]  q_nxt, qm_nxt;
    always_comb begin
      logic signed [3:0] d;
      logic [CSW-1:0]    sv, cv;
      logic [2:0]        rsum;
      logic [QW-1:0]     qv, qmv;
      logic [RE-1:0]     xv;
      logic [CSW-1:0]    a16, b16, t1, t2, s1, c1;
      logic              inj1, inj2;
      /* verilator lint_off UNUSEDSIGNAL */
      logic signed [12:0]    pe;
      /* verilator lint_on UNUSEDSIGNAL */
      sv  = s_st[st];
      cv  = c_st[st];
      qv  = q_st[st];
      qmv = qm_st[st];
      xv  = x_st[st];
      rsum = 3'(sv + cv);
      d   = '0;
      a16 = '0;
      b16 = '0;
      t1  = '0;
      t2  = '0;
      s1  = '0;
      c1  = '0;
      inj1 = 1'b0;
      inj2 = 1'b0;
      pe  = '0;
      for (int j = 0; j < DPS; j++) begin
        if (st * DPS + j < NDIG) begin
          int t;
          t = st * DPS + j;
          // radicand bits for this digit (preload consumed the top 4)
          if ((st * DPS + j) == 0) begin
            d = first_digit(qv[1:0], rsum[2:0], xv[RE-5 -: 4]);
          end else begin
            pe = est_pe(sv, cv, xv[RE-5-4*t -: 4], t);
            d = thr_digit(qv, pe, 2*t - 2);
          end
          // R' = 16R + bits - d(8q+d) with no carry-propagate add (two
          // 3:2 levels). The radicand bits fill the zero LSBs of 16C;
          // 8q+d = {q, d} for d > 0 and 8q+d = 8qm + 8-|d| = {qm, 8-|d|}
          // for d < 0, so -d(8q+d) is one or two shifted copies of a
          // concatenation, bit-inverted for d > 0 (the +1s of the
          // two's-complement negation go into the zero carry LSBs).
          a16 = CSW'(sv << 4);
          b16 = CSW'(cv << 4) | CSW'(xv[RE-5-4*t -: 4]);
          case (d)
            4'sd1:  begin t1 = ~CSW'({qv, 3'd1});        t2 = '0;                       inj1 = 1'b1; inj2 = 1'b0; end
            4'sd2:  begin t1 = ~CSW'({qv, 3'd2, 1'b0});  t2 = '0;                       inj1 = 1'b1; inj2 = 1'b0; end
            4'sd3:  begin t1 = ~CSW'({qv, 3'd3});        t2 = ~CSW'({qv, 3'd3, 1'b0});  inj1 = 1'b1; inj2 = 1'b1; end
            4'sd4:  begin t1 = ~CSW'({qv, 3'd4, 2'b0});  t2 = '0;                       inj1 = 1'b1; inj2 = 1'b0; end
            -4'sd1: begin t1 = CSW'({qmv, 3'd7});        t2 = '0;                       inj1 = 1'b0; inj2 = 1'b0; end
            -4'sd2: begin t1 = CSW'({qmv, 3'd6, 1'b0});  t2 = '0;                       inj1 = 1'b0; inj2 = 1'b0; end
            -4'sd3: begin t1 = CSW'({qmv, 3'd5});        t2 = CSW'({qmv, 3'd5, 1'b0});  inj1 = 1'b0; inj2 = 1'b0; end
            -4'sd4: begin t1 = CSW'({qmv, 3'd4, 2'b0});  t2 = '0;                       inj1 = 1'b0; inj2 = 1'b0; end
            default: begin t1 = '0;                      t2 = '0;                       inj1 = 1'b0; inj2 = 1'b0; end
          endcase
          s1  = a16 ^ b16 ^ t1;
          c1  = CSW'(((a16 & b16) | (a16 & t1) | (b16 & t1)) << 1) | CSW'(inj1);
          sv  = s1 ^ c1 ^ t2;
          cv  = CSW'(((s1 & c1) | (s1 & t2) | (c1 & t2)) << 1) | CSW'(inj2);
          if (d >= 0) begin
            qv  = QW'($signed(qv) * 4 + d);
            qmv = QW'($signed(qmv) * 4 + d + 3);
          end else begin
            qv  = QW'($signed(qmv) * 4 + d + 4);
            qmv = QW'($signed(qmv) * 4 + d + 3);
          end
        end
      end
      s_nxt  = (STAGE_FOLD != 0) ? CSW'(sv + cv) : sv;   // see STAGE_FOLD
      c_nxt  = (STAGE_FOLD != 0) ? '0 : cv;
      q_nxt  = qv;
      qm_nxt = qmv;
    end

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        s_st[st+1]  <= '0;
        c_st[st+1]  <= '0;
        q_st[st+1]  <= '0;
        qm_st[st+1] <= '1;
        x_st[st+1]  <= '0;
        valid_st[st+1] <= 1'b0;
        ysp_st[st+1] <= '0;
        fsp_st[st+1] <= 5'd0;
        sp_st[st+1]  <= 1'b0;
        rm_st[st+1]  <= 3'd0;
        er_st[st+1]  <= '0;
      end else begin
        s_st[st+1]  <= s_nxt;
        c_st[st+1]  <= c_nxt;
        q_st[st+1]  <= q_nxt;
        qm_st[st+1] <= qm_nxt;
        x_st[st+1]  <= x_st[st];
        valid_st[st+1] <= valid_st[st];
        ysp_st[st+1] <= ysp_st[st];
        fsp_st[st+1] <= fsp_st[st];
        sp_st[st+1]  <= sp_st[st];
        rm_st[st+1]  <= rm_st[st];
        er_st[st+1]  <= er_st[st];
      end
    end
  end

  // ===================================================== correct / round
  logic [CSW-1:0]        r_mod;
  logic signed [CSW+1:0] r_fin, r_corr;
  logic [QW-1:0]         q_fin;
  logic                  sticky;
  always_comb begin
    r_mod  = s_st[NSTG] + c_st[NSTG];               // wraps: exact mod 2^CSW
    r_fin  = (CSW+2)'($signed(r_mod));
    q_fin  = q_st[NSTG];
    r_corr = r_fin;
    sticky = (r_fin != 0) || ((PAD_SH != 0) && (q_st[NSTG][0] != 1'b0));
    if (r_fin < 0) begin
      // q was above the true root: step down one digit-grid ulp
      q_fin  = qm_st[NSTG];
      r_corr = r_fin + (CSW+2)'($signed(qm_st[NSTG]) << 1) - 1;
      sticky = (r_corr != 0) || ((PAD_SH != 0) && (qm_st[NSTG][0] != 1'b0));
    end
  end

  // Optional pipeline register after the final carry-save fold
  // (FOLD_STG = 1, one more cycle of latency): splits the fold CPA + Q/QM
  // selection from the rounding, which is needed below ~4.5 ns.
  logic [QW-1:0]             q_f;
  logic                      sticky_f;
  logic [2:0]                rm_f;
  logic signed [W_EXP+3:0]   er_f;
  logic                      sp_f;
  logic [W-1:0]              ysp_f;
  logic [4:0]                fsp_f;
  logic                      valid_f;
  if (FOLD_STG != 0) begin : g_fold_reg
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        q_f      <= '0;
        sticky_f <= 1'b0;
        rm_f <= '0;
        er_f <= '0;
        sp_f <= '0;
        ysp_f <= '0;
        fsp_f <= '0;
        valid_f <= '0;
      end else begin
        q_f      <= q_fin;
        sticky_f <= sticky;
        rm_f <= rm_st[NSTG];
        er_f <= er_st[NSTG];
        sp_f <= sp_st[NSTG];
        ysp_f <= ysp_st[NSTG];
        fsp_f <= fsp_st[NSTG];
        valid_f <= valid_st[NSTG];
      end
    end
  end else begin : g_fold_comb
    assign q_f      = q_fin;
    assign sticky_f = sticky;
    assign rm_f = rm_st[NSTG];
    assign er_f = er_st[NSTG];
    assign sp_f = sp_st[NSTG];
    assign ysp_f = ysp_st[NSTG];
    assign fsp_f = fsp_st[NSTG];
    assign valid_f = valid_st[NSTG];
  end

  logic [FW-1:0] placed;
  logic          norm_sticky;
  always_comb begin
    placed      = (PAD_SH != 0) ? FW'($signed(q_f) >>> 1) : FW'(q_f);
    norm_sticky = sticky_f;
  end

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
    sig     = placed[TARGET -: S_W];
    g       = placed[2];
    r       = placed[1];
    s_bit   = placed[0] | norm_sticky;
    lsb     = sig[0];
    inexact = g | r | s_bit;
    case (rm_f)
      fp_pkg::RM_RNE: round_up = g & (r | s_bit) | (g & ~r & ~s_bit & lsb);
      fp_pkg::RM_RNA: round_up = g;
      fp_pkg::RM_RZ:  round_up = 1'b0;
      fp_pkg::RM_RP:  round_up = inexact;
      fp_pkg::RM_RM:  round_up = 1'b0;
      default:        round_up = 1'b0;
    endcase
    carry = round_up && (sig == {S_W{1'b1}});
    if (carry) begin
      sig_rnd = {1'b1, {W_MANT{1'b0}}};
      e_rnd   = er_f + 1;
    end else begin
      sig_rnd = sig + { {S_W-1{1'b0}}, round_up };
      e_rnd   = er_f;
    end
    exp_fld = e_rnd[W_EXP-1:0] + BIAS[W_EXP-1:0];
    if ($signed(e_rnd) > EMAX_S) begin
      case (rm_f)
        fp_pkg::RM_RNE,
        fp_pkg::RM_RNA: y_normal = {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        fp_pkg::RM_RZ:  y_normal = {1'b0, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
        fp_pkg::RM_RP:  y_normal = {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        fp_pkg::RM_RM:  y_normal = {1'b0, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
        default:        y_normal = {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      endcase
      flags_normal = (1 << fp_pkg::FLAG_OVERFLOW) | (1 << fp_pkg::FLAG_INEXACT);
    end else begin
      y_normal = {1'b0, exp_fld, sig_rnd[MANT_W-1:0]};
      flags_normal = inexact ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
    end
  end

  logic [W-1:0] y_sub;
  logic [4:0]   flags_sub;
  always_comb begin
    int signed          shift;
    logic [FW-1:0]      shifted;
    logic [S_W-1:0]     sig_s;
    logic               gs, rs, ss, inexact_s, up_s;
    logic [S_W-1:0]     sig_s2;
    shift = int'(EMIN - int'(er_f));
    if (shift > 0) shifted = placed >> shift;
    else           shifted = '0;
    sig_s  = shifted[TARGET -: S_W];
    gs     = shifted[2];
    rs     = shifted[1];
    ss     = shifted[0] | norm_sticky
           | |(placed & (((FW)'(1) << (shift > 0 ? shift : 0)) - 1));
    inexact_s = gs | rs | ss;
    case (rm_f)
      fp_pkg::RM_RNE: up_s = gs & (rs | ss) | (gs & ~rs & ~ss & sig_s[0]);
      fp_pkg::RM_RNA: up_s = gs;
      fp_pkg::RM_RZ:  up_s = 1'b0;
      fp_pkg::RM_RP:  up_s = inexact_s;
      fp_pkg::RM_RM:  up_s = 1'b0;
      default:        up_s = 1'b0;
    endcase
    sig_s2 = sig_s + { {S_W-1{1'b0}}, up_s };
    if (sig_s2 == {1'b1, {W_MANT{1'b0}}}) begin
      if (EMIN > EMAX) begin
        case (rm_f)
          fp_pkg::RM_RNE,
          fp_pkg::RM_RNA: y_sub = {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
          fp_pkg::RM_RZ:  y_sub = {1'b0, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
          fp_pkg::RM_RP:  y_sub = {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
          fp_pkg::RM_RM:  y_sub = {1'b0, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
          default:        y_sub = {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        endcase
        flags_sub = (1 << fp_pkg::FLAG_OVERFLOW) | (1 << fp_pkg::FLAG_INEXACT);
      end else begin
        y_sub = {1'b0, {W_EXP-1{1'b0}}, 1'b1, {W_MANT{1'b0}}};
        flags_sub = inexact_s ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
      end
    end else if (sig_s2 == '0) begin
      y_sub = {1'b0, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
      flags_sub = inexact_s ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
    end else begin
      y_sub = {1'b0, {W_EXP{1'b0}}, sig_s2[MANT_W-1:0]};
      flags_sub = 5'd0;
      if (inexact_s) begin
        flags_sub[fp_pkg::FLAG_UNDERFLOW] = 1'b1;
        flags_sub[fp_pkg::FLAG_INEXACT]   = 1'b1;
      end
    end
  end

  logic [W-1:0] y_result;
  logic [4:0]   flags_result;
  always_comb begin
    if ($signed(er_f) >= EMIN_S) begin
      y_result     = y_normal;
      flags_result = flags_normal;
    end else begin
      y_result     = y_sub;
      flags_result = flags_sub;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      y         <= '0;
      flags     <= 5'd0;
      out_valid <= 1'b0;
    end else begin
      y     <= sp_f ? ysp_f : y_result;
      flags <= sp_f ? fsp_f : flags_result;
      out_valid <= valid_f;
    end
  end

endmodule
