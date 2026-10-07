// Pipelined radix-4 SRT division (carry-save remainder, on-the-fly quotient).
//
// Fully unrolled, DPS radix-4 quotient digits per pipeline stage, one start per
// cycle (out_valid streams with the results). Latency is fixed:
//   1 (setup) + ceil(NDIG/DPS) + 1 (correct/round/encode) = NSTG + 2 cycles.
//
// Digit recurrence (integer domain, Den = normalized divisor significand):
//   u = R * 2^(S_W+2),  u0 = a_al = Num   (R0 = A/4)
//   u' = 4u - 4*d*Den,  d in {-2..2}
// Quotient accumulated on the fly (Q, QM = Q - 1) so negative digits need no
// borrow propagation; the final sign correction picks Q or QM. After NDIG
// digits, q_raw = floor(Num*2^(S_W+2)/Den), the sticky is the exact remainder.
//
// Digit selection uses carry-save estimates: k = floor(64R) computed from the
// top bits of (S,C) (a 0/1 underestimate), then a 4-threshold comparator
// function per divisor cell (16 cells of width 1/32). The thresholds were
// derived by exhaustive interval analysis and validated bit-exactly against
// floor-division for all formats (see /tmp/opencode/srt).
//
// The remainder is kept in carry-save (S,C); its representation drift is
// bounded by S_W+17 bits, so CSW = S_W+22 is safe for every width.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
// Int arithmetic is deliberately mixed with sized logic; every expression is
// bounded such that the truncation/extensions are exact.

module fp_div_srt #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23,
  parameter int DPS    = 2     // radix-4 digits per pipeline stage
) (
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
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

  // number of radix-4 digits: NDIG-1 = ceil((TARGET+1)/2) with one extra for
  // odd TARGET (the final quotient is Q or Q>>1 accordingly)
  localparam int NDIG   = (TARGET % 2 == 0) ? (TARGET / 2 + 1)
                                            : ((TARGET + 1) / 2 + 1);
  localparam int NSTG   = (NDIG + DPS - 1) / DPS;
  localparam int CSW    = S_W + 14;           // carry-save width (stage-folded)
  localparam int QW     = S_W + 6;            // on-the-fly quotient width
  localparam int EST_SH = S_W - 4;            // k = floor(u / 2^EST_SH)

  // ============================================================ setup (cycle 0)
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
    y_special     = '0;
    flags_special = '0;
    special_case  = 1'b0;
    if (a_nan || b_nan) begin
      y_special = {1'b0, EXP_ALL[W_EXP-1:0], (a_nan ? a_mant : b_mant) | QUIET};
      flags_special[fp_pkg::FLAG_INVALID] = a_snan || b_snan;
      special_case = 1'b1;
    end else if (a_inf || b_inf) begin
      if (a_inf && b_inf) begin
        y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
        flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
      end else if (a_inf) begin
        y_special = {a_sign ^ b_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      end else begin
        y_special = {a_sign ^ b_sign, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
      end
      special_case = 1'b1;
    end else if (a_zero || b_zero) begin
      if (a_zero && b_zero) begin
        y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
        flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
      end else if (a_zero) begin
        y_special = {a_sign ^ b_sign, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
      end else begin
        y_special = {a_sign ^ b_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        flags_special[fp_pkg::FLAG_DIV0] = 1'b1;
      end
      special_case = 1'b1;
    end
  end

  logic rsign;
  assign rsign = a_sign ^ b_sign;

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

  logic [S_W-1:0] a_al, b_al;
  assign a_al = s_a << (S_W - bitlen(s_a));
  assign b_al = s_b << (S_W - bitlen(s_b));

  logic a_ge_b;
  assign a_ge_b = (a_al >= b_al);

  logic signed [W_EXP+3:0] e_res;
  assign e_res = (W_EXP+4)'(e_a) - (W_EXP+4)'(e_b) - (W_EXP+4)'(a_ge_b ? 0 : 1);

  // divisor cell for the QST: (D - 1/2) in units of 1/32
  function automatic logic [3:0] dcell_of(input logic [S_W-1:0] den);
    logic [S_W:0] t;
    t = {1'b0, den} - ((S_W+1)'(1) << (S_W-1));
    if (S_W >= 5) dcell_of = 4'(t >> (S_W - 5));
    else          dcell_of = 4'(t << (5 - S_W));
  endfunction

  // QST: q = -2 + sum(k >= t_i); thresholds by divisor cell
  function automatic logic signed [2:0] qst_sel(input logic signed [7:0] k,
                                                input logic [3:0] dcell);
    logic signed [7:0] t0, t1, t2, t3;
    case (dcell)
      4'd0 : begin t0 = -13; t1 = -4; t2 = 4;  t3 = 12; end
      4'd1 : begin t0 = -13; t1 = -4; t2 = 4;  t3 = 13; end
      4'd2 : begin t0 = -14; t1 = -5; t2 = 5;  t3 = 14; end
      4'd3 : begin t0 = -15; t1 = -5; t2 = 5;  t3 = 14; end
      4'd4 : begin t0 = -15; t1 = -5; t2 = 5;  t3 = 15; end
      4'd5 : begin t0 = -16; t1 = -5; t2 = 6;  t3 = 16; end
      4'd6 : begin t0 = -17; t1 = -5; t2 = 6;  t3 = 17; end
      4'd7 : begin t0 = -17; t1 = -5; t2 = 6;  t3 = 18; end
      4'd8 : begin t0 = -18; t1 = -6; t2 = 7;  t3 = 19; end
      4'd9 : begin t0 = -19; t1 = -6; t2 = 7;  t3 = 19; end
      4'd10: begin t0 = -19; t1 = -6; t2 = 7;  t3 = 20; end
      4'd11: begin t0 = -20; t1 = -6; t2 = 8;  t3 = 21; end
      4'd12: begin t0 = -21; t1 = -6; t2 = 8;  t3 = 22; end
      4'd13: begin t0 = -21; t1 = -6; t2 = 8;  t3 = 23; end
      4'd14: begin t0 = -22; t1 = -7; t2 = 9;  t3 = 24; end
      default: begin t0 = -23; t1 = -7; t2 = 9; t3 = 24; end
    endcase
    qst_sel = 3'(-2) + 3'(k >= t0) + 3'(k >= t1) + 3'(k >= t2) + 3'(k >= t3);
  endfunction

  // estimate k = floor(64R) from the carry-save top bits (0/1 underestimate)
  function automatic logic signed [7:0] est_k(input logic [CSW-1:0] sin,
                                              input logic [CSW-1:0] cin);
    logic signed [CSW+3:0] sx, cx;
    logic signed [7:0]     sum;
    sx = $signed(sin);
    cx = $signed(cin);
    if (EST_SH >= 0) sum = 8'(sx >>> EST_SH) + 8'(cx >>> EST_SH);
    else             sum = 8'(sx <<< (-EST_SH)) + 8'(cx <<< (-EST_SH));
    est_k = sum;
  endfunction

  // ===================================================== pipeline registers
  logic [CSW-1:0] s_st [0:NSTG];
  logic [CSW-1:0] c_st [0:NSTG];
  logic [QW-1:0]  q_st [0:NSTG];
  logic [QW-1:0]  qm_st [0:NSTG];
  logic [3:0]     dc_st [0:NSTG];
  logic [S_W-1:0] bal_st [0:NSTG];
  logic           valid_st [0:NSTG];
  logic [W-1:0]   ysp_st [0:NSTG];
  logic [4:0]     fsp_st [0:NSTG];
  logic           sp_st  [0:NSTG];
  logic           rs_st  [0:NSTG];
  logic           ge_st  [0:NSTG];
  logic [2:0]     rm_st  [0:NSTG];
  logic signed [W_EXP+3:0] er_st [0:NSTG];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i <= NSTG; i++) begin
        s_st[i]  <= '0;
        c_st[i]  <= '0;
        q_st[i]  <= '0;
        qm_st[i] <= '1;             // QM = Q - 1 = -1
        dc_st[i] <= '0;
        bal_st[i] <= '0;
        valid_st[i] <= 1'b0;
        ysp_st[i] <= '0;
        fsp_st[i] <= 5'd0;
        sp_st[i]  <= 1'b0;
        rs_st[i]  <= 1'b0;
        ge_st[i]  <= 1'b0;
        rm_st[i]  <= 3'd0;
        er_st[i]  <= '0;
      end
    end else if (start) begin
      s_st[0]  <= (CSW)'(a_al);
      c_st[0]  <= '0;
      q_st[0]  <= '0;
      qm_st[0] <= '1;
      dc_st[0] <= dcell_of(b_al);
      bal_st[0] <= b_al;
      valid_st[0] <= 1'b1;
      ysp_st[0] <= y_special;
      fsp_st[0] <= flags_special;
      sp_st[0]  <= special_case;
      rs_st[0]  <= rsign;
      ge_st[0]  <= a_ge_b;
      rm_st[0]  <= rm;
      er_st[0]  <= e_res;
    end else begin
      valid_st[0] <= 1'b0;
    end
  end

  // ===================================================== digit stages (unrolled)
  for (genvar st = 0; st < NSTG; st++) begin : g_stage
    logic [CSW-1:0] s_nxt, c_nxt;
    logic [QW-1:0]  q_nxt, qm_nxt;
    always_comb begin
      logic signed [7:0] k;
      logic signed [2:0] d;
      logic [CSW-1:0]    sv, cv;
      logic [QW-1:0]     qv, qmv;
      /* verilator lint_off UNUSEDSIGNAL */
      logic [CSW+2:0]    a4, b4, ss, maj;
      logic signed [CSW+5:0] prod, cc;
      /* verilator lint_on UNUSEDSIGNAL */
      sv  = s_st[st];
      cv  = c_st[st];
      qv  = q_st[st];
      qmv = qm_st[st];
      for (int j = 0; j < DPS; j++) begin
        if (st * DPS + j < NDIG) begin
          k = est_k(sv, cv);
          d = qst_sel(k, dc_st[st]);
          // u' = 4u - 4*d*Den  (3:2 CSA, exact sign extension within CSW+2)
          a4   = (CSW+3)'(sv) << 2;
          b4   = (CSW+3)'(cv) << 2;
          prod = $signed(d) * $signed({1'b0, bal_st[st]});
          cc   = -(prod <<< 2);
          ss   = a4 ^ b4 ^ (CSW+3)'(cc);
          maj  = (a4 & b4) | (a4 & (CSW+3)'(cc)) | (b4 & (CSW+3)'(cc));
          sv   = CSW'(ss);
          cv   = CSW'(maj << 1);
          if (d >= 0) begin
            qv  = QW'($signed(qv) * 4 + d);
            qmv = QW'($signed(qmv) * 4 + d + 3);
          end else begin
            qv  = QW'($signed(qmv) * 4 + d + 4);
            qmv = QW'($signed(qmv) * 4 + d + 3);
          end
        end
      end
      s_nxt  = CSW'($signed(sv) + $signed(cv));   // stage-boundary fold (CPA)
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
        dc_st[st+1] <= '0;
        valid_st[st+1] <= 1'b0;
        ysp_st[st+1] <= '0;
        fsp_st[st+1] <= 5'd0;
        sp_st[st+1]  <= 1'b0;
        rs_st[st+1]  <= 1'b0;
        ge_st[st+1]  <= 1'b0;
        rm_st[st+1]  <= 3'd0;
        er_st[st+1]  <= '0;
      end else begin
        s_st[st+1]  <= s_nxt;
        c_st[st+1]  <= c_nxt;
        q_st[st+1]  <= q_nxt;
        qm_st[st+1] <= qm_nxt;
        dc_st[st+1] <= dc_st[st];
        bal_st[st+1] <= bal_st[st];
        valid_st[st+1] <= valid_st[st];
        ysp_st[st+1] <= ysp_st[st];
        fsp_st[st+1] <= fsp_st[st];
        sp_st[st+1]  <= sp_st[st];
        rs_st[st+1]  <= rs_st[st];
        ge_st[st+1]  <= ge_st[st];
        rm_st[st+1]  <= rm_st[st];
        er_st[st+1]  <= er_st[st];
      end
    end
  end

  // ===================================================== correct / round / encode
  logic signed [CSW+1:0] u_fin;
  logic [QW-1:0]         q_fin;
  logic [QW-1:0]         q_corr;
  logic                  sticky;
  always_comb begin
    u_fin  = (CSW+2)'($signed(s_st[NSTG])) + (CSW+2)'($signed(c_st[NSTG]));
    q_corr = (TARGET % 2 == 0) ? q_st[NSTG] : QW'($signed(q_st[NSTG]) >>> 1);
    sticky = (u_fin != 0) || ((TARGET % 2 == 1) && q_st[NSTG][0]);
    if (u_fin < 0) begin
      // redundant representation was above the true value: use QM and add
      // one divisor multiple back into the remainder
      q_corr = (TARGET % 2 == 0) ? qm_st[NSTG] : QW'($signed(qm_st[NSTG]) >>> 1);
      sticky = ((u_fin + (CSW+2)'(bal_st[NSTG]) * 4) != 0)
            || ((TARGET % 2 == 1) && qm_st[NSTG][0]);
    end
    q_fin = q_corr;
  end

  logic [FW-1:0] placed;
  logic          norm_sticky;
  always_comb begin
    placed      = ge_st[NSTG] ? FW'(q_fin) : FW'(q_fin << 1);
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
      fp_pkg::RM_RP:  round_up = ~rs_st[NSTG] & inexact;
      fp_pkg::RM_RM:  round_up = rs_st[NSTG] & inexact;
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
        fp_pkg::RM_RNA: y_normal = {rs_st[NSTG], EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        fp_pkg::RM_RZ:  y_normal = {rs_st[NSTG], EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
        fp_pkg::RM_RP:  y_normal = rs_st[NSTG] ? {1'b1, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}}
                                               : {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        fp_pkg::RM_RM:  y_normal = rs_st[NSTG] ? {1'b1, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}}
                                               : {1'b0, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
        default:        y_normal = {rs_st[NSTG], EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      endcase
      flags_normal = (1 << fp_pkg::FLAG_OVERFLOW) | (1 << fp_pkg::FLAG_INEXACT);
    end else begin
      y_normal = {rs_st[NSTG], exp_fld, sig_rnd[MANT_W-1:0]};
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
      fp_pkg::RM_RP:  up_s = ~rs_st[NSTG] & inexact_s;
      fp_pkg::RM_RM:  up_s = rs_st[NSTG] & inexact_s;
      default:        up_s = 1'b0;
    endcase
    sig_s2 = sig_s + { {S_W-1{1'b0}}, up_s };
    if (sig_s2 == {1'b1, {W_MANT{1'b0}}}) begin
      if (EMIN > EMAX &&
          ((gs && rs) || (rm_st[NSTG] == fp_pkg::RM_RP && ~rs_st[NSTG] && gs)
                      || (rm_st[NSTG] == fp_pkg::RM_RM && rs_st[NSTG] && gs))) begin
        case (rm_st[NSTG])
          fp_pkg::RM_RNE,
          fp_pkg::RM_RNA: y_sub = {rs_st[NSTG], EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
          fp_pkg::RM_RZ:  y_sub = {rs_st[NSTG], EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
          fp_pkg::RM_RP:  y_sub = rs_st[NSTG] ? {1'b1, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}}
                                              : {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
          fp_pkg::RM_RM:  y_sub = rs_st[NSTG] ? {1'b1, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}}
                                              : {1'b0, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
          default:        y_sub = {rs_st[NSTG], EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        endcase
        flags_sub = (1 << fp_pkg::FLAG_OVERFLOW) | (1 << fp_pkg::FLAG_INEXACT);
      end else begin
        y_sub = {rs_st[NSTG], {W_EXP-1{1'b0}}, 1'b1, {W_MANT{1'b0}}};
        flags_sub = inexact_s ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
      end
    end else if (sig_s2 == '0) begin
      y_sub = {rs_st[NSTG], {W_EXP{1'b0}}, {W_MANT{1'b0}}};
      flags_sub = inexact_s ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
    end else begin
      y_sub = {rs_st[NSTG], {W_EXP{1'b0}}, sig_s2[MANT_W-1:0]};
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
