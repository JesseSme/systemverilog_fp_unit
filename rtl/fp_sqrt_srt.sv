// Pipelined radix-4 SRT square root (carry-save remainder, on-the-fly root).
//
// Fully unrolled, DPS radix-4 root digits per stage, one start per cycle.
// Latency = 1 (setup) + ceil(NDIG/DPS) + 1 (correct/round/encode).
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
// The carry-save remainder is folded with a small CPA at each stage boundary
// (same as fp_div_srt) to bound the representation drift.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */

module fp_sqrt_srt #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23,
  parameter int DPS    = 2
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
  localparam int CSW    = S_W + 18;                // carry-save width (folded)
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
  logic [QW-1:0]  r0;
  assign v4 = x_p[RE-1 -: 4];
  assign d0 = (v4 >= 4'd9) ? 2'd3 : 2'd2;
  assign q0 = QW'(d0);
  assign r0 = QW'(v4) - QW'(d0) * QW'(d0);

  // sqrt exponent: floor(e_a / 2)
  logic signed [W_EXP+3:0] e_res;
  assign e_res = e_a >>> 1;

  // generalized arithmetic shift helper (constant shift amounts per call)
  function automatic logic signed [15:0] sh_ar(input logic signed [CSW+5:0] v,
                                               input int sh);
    if (sh >= 0) sh_ar = 16'($signed(v) >>> sh);
    else          sh_ar = 16'($signed(v) <<< (-sh));
  endfunction

  // exact first digit (q < 4): pick the valid d with the smallest |R'|
  function automatic logic signed [3:0] first_digit(input logic [QW-1:0] qv,
                                                    input logic [CSW-1:0] rv,
                                                    input logic [3:0] bits);
    logic signed [CSW+4:0] p, term, bound, diff;
    logic signed [3:0]     best;
    logic signed [CSW+4:0] bestabs;
    p = $signed((CSW+5)'(rv)) * 16 + $signed((CSW+5)'(bits));
    best = 0;
    bestabs = {1'b0, {(CSW+4){1'b1}}};
    for (int d = -4; d <= 4; d++) begin
      term  = $signed((CSW+5)'(d)) * ($signed((CSW+5)'(qv)) * 8 + d);
      bound = $signed((CSW+5)'(qv)) * 8 + 2 * d;
      if ((4 * $signed((CSW+5)'(qv)) + d) > 0) begin            // q' > 0
        diff = term - p;
        if ((diff <= bound) && (diff >= -bound)) begin
          if ((diff >= 0 ? diff : -diff) < bestabs) begin
            bestabs = (diff >= 0 ? diff : -diff);
            best    = 4'(d);
          end
        end
      end
    end
    first_digit = best;
  endfunction

  // threshold selection (q >= 4): d = count(p >= q*(8k+4), k=-4..3) - 4
  function automatic logic signed [3:0] thr_digit(input logic [QW-1:0] qv,
                                                  input logic signed [15:0] pe,
                                                  input int sh);
    logic signed [15:0] q4, q12, q20, q28;
    logic signed [15:0] qs;
    logic [2:0] cnt;
    qs  = sh_ar((CSW+6)'({1'b0, qv}), sh);
    q4  = qs <<< 2;
    q12 = q4 * 3;
    q20 = q4 * 5;
    q28 = q4 * 7;
    cnt = 3'd0;
    if (pe >= -q28) cnt = cnt + 1'b1;
    if (pe >= -q20) cnt = cnt + 1'b1;
    if (pe >= -q12) cnt = cnt + 1'b1;
    if (pe >= -q4)  cnt = cnt + 1'b1;
    if (pe >=  q4)  cnt = cnt + 1'b1;
    if (pe >=  q12) cnt = cnt + 1'b1;
    if (pe >=  q20) cnt = cnt + 1'b1;
    if (pe >=  q28) cnt = cnt + 1'b1;
    thr_digit = 4'($signed({1'b0, cnt}) - 4);
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
      logic [QW-1:0]     qv, qmv;
      logic [RE-1:0]     xv;
      /* verilator lint_off UNUSEDSIGNAL */
      logic [CSW+5:0]    a16, b16, d2, ss, maj;
      logic signed [CSW+5:0] term;
      logic signed [15:0]    pe;
      /* verilator lint_on UNUSEDSIGNAL */
      sv  = s_st[st];
      cv  = c_st[st];
      qv  = q_st[st];
      qmv = qm_st[st];
      xv  = x_st[st];
      d   = '0;
      a16 = '0;
      b16 = '0;
      term = '0;
      d2  = '0;
      ss  = '0;
      maj = '0;
      pe  = '0;
      for (int j = 0; j < DPS; j++) begin
        if (st * DPS + j < NDIG) begin
          int t;
          t = st * DPS + j;
          // radicand bits for this digit (preload consumed the top 4)
          if (qv < QW'(4)) begin
            d = first_digit(qv, sv + cv, xv[RE-5-4*t -: 4]);
          end else begin
            pe = sh_ar($signed(sv), 2*t - 6)
               + sh_ar($signed(cv), 2*t - 6)
               + sh_ar((CSW+6)'({12'b0, xv[RE-5-4*t -: 4]}), 2*t - 2);
            d = thr_digit(qv, pe, 2*t - 2);
          end
          // R' = 16R + bits - d(8q+d)  (3:2 CSA)
          a16 = (CSW+6)'(sv) << 4;
          b16 = (CSW+6)'(cv) << 4;
          term = $signed(d) * $signed({1'b0, qv, 3'b000}) + d * d;
          d2  = (CSW+6)'({12'b0, xv[RE-5-4*t -: 4]}) - (CSW+6)'(term);
          ss  = a16 ^ b16 ^ d2;
          maj = (a16 & b16) | (a16 & d2) | (b16 & d2);
          sv  = CSW'(ss);
          cv  = CSW'(maj << 1);
          if (d >= 0) begin
            qv  = QW'($signed(qv) * 4 + d);
            qmv = QW'($signed(qmv) * 4 + d + 3);
          end else begin
            qv  = QW'($signed(qmv) * 4 + d + 4);
            qmv = QW'($signed(qmv) * 4 + d + 3);
          end
        end
      end
      s_nxt  = CSW'($signed(sv) + $signed(cv));   // stage-boundary fold
      c_nxt  = '0;
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
  logic signed [CSW+1:0] r_fin, r_corr;
  logic [QW-1:0]         q_fin;
  logic                  sticky;
  always_comb begin
    r_fin  = (CSW+2)'($signed(s_st[NSTG])) + (CSW+2)'($signed(c_st[NSTG]));
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

  logic [FW-1:0] placed;
  logic          norm_sticky;
  always_comb begin
    placed      = (PAD_SH != 0) ? FW'($signed(q_fin) >>> 1) : FW'(q_fin);
    norm_sticky = sticky;
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
    case (rm_st[NSTG])
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
      e_rnd   = er_st[NSTG] + 1;
    end else begin
      sig_rnd = sig + { {S_W-1{1'b0}}, round_up };
      e_rnd   = er_st[NSTG];
    end
    exp_fld = e_rnd[W_EXP-1:0] + BIAS[W_EXP-1:0];
    if ($signed(e_rnd) > EMAX_S) begin
      case (rm_st[NSTG])
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
    shift = int'(EMIN - int'(er_st[NSTG]));
    if (shift > 0) shifted = placed >> shift;
    else           shifted = '0;
    sig_s  = shifted[TARGET -: S_W];
    gs     = shifted[2];
    rs     = shifted[1];
    ss     = shifted[0] | norm_sticky
           | |(placed & (((FW)'(1) << (shift > 0 ? shift : 0)) - 1));
    inexact_s = gs | rs | ss;
    case (rm_st[NSTG])
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
        case (rm_st[NSTG])
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
    if ($signed(er_st[NSTG]) >= EMIN_S) begin
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
      y     <= sp_st[NSTG] ? ysp_st[NSTG] : y_result;
      flags <= sp_st[NSTG] ? fsp_st[NSTG] : flags_result;
      out_valid <= valid_st[NSTG];
    end
  end

endmodule
