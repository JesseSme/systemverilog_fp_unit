// Iterative (multi-cycle) IEEE 754-2019 division / square root datapath.
//
// This is the area/Fmax alternative to the fully combinational fp_div and
// fp_sqrt modules: one shared restoring engine produces either the quotient
// (one bit per cycle) or the square-root significand (one bit per two
// radicand bits per cycle), so a single adder/subtractor replaces the two
// large combinational arrays. Semantics are bit-exact with fp_div/fp_sqrt:
// same special cases, same GRS rounding on the exact quotient/root grid, same
// overflow/underflow/inexact rules (7.2-7.6).
//
// Division (fp_div math): q_raw = floor(num / b_al) with
// num = a_al << (S_W+2), a_al/b_al the significands normalized to MSB at
// S_W-1. Restoring division consumes one radicand bit per cycle (2*S_W+2
// cycles), producing the quotient plus GRS bits; the final remainder is the
// sticky (norm_sticky = |rem). placed is q_raw with its MSB at TARGET (one
// extra shift when a_al < b_al).
//
// Square root (fp_sqrt math): placed = floor(sqrt(X)) with
// X = s_a << (2*TARGET + e_a[0] - bitlen(s_a) + 1), processed two radicand
// bits per root bit. The final remainder is exactly X - placed^2, which is
// the sticky (zero iff X is a perfect square).
//
// Interface: pulse `start` (with is_sqrt/a/b/rm valid) when `busy` is low;
// `done` pulses one cycle with y/flags valid. Special cases complete with the
// same latency as a `start`-to-`done` handshake (done one cycle after start).

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
// Int arithmetic is deliberately mixed with sized logic; every expression is
// bounded such that the truncation/extensions are exact.

module fp_divsqrt_iter #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23
) (
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
  input  fp_pkg::rounding_t         rm,
  input  logic                      is_sqrt,
  input  logic                      start,
  output logic [1+W_EXP+W_MANT-1:0] y,
  output logic [4:0]                flags,
  input  logic                      clk,
  input  logic                      rst_n,
  output logic                      busy,
  output logic                      done
);

  localparam int W       = 1 + W_EXP + W_MANT;   // total width
  localparam int BIAS    = (1 << (W_EXP-1)) - 1; // exponent bias (3.3)
  localparam int EMAX    = BIAS;                 // largest exponent
  localparam int EMIN    = 1 - BIAS;             // smallest normal exponent
  localparam int S_W     = W_MANT + 1;           // significand width incl. implicit bit
  localparam int MANT_W  = (W_MANT > 0) ? W_MANT : 1;  // internal mantissa width
  localparam int TARGET  = S_W + 2;              // MSB position of the placed quotient/root
  localparam int FW      = S_W + 3;              // sig + GRS width (engine bits)
  localparam int R_W     = 2 * S_W + 6;          // sqrt radicand / remainder width (even)
  localparam int Q_W     = 2 * S_W + 2;          // full quotient width (division)
  localparam int EXP_ALL = (1 << W_EXP) - 1;     // all-ones exponent field
  localparam int EXP_MAXF = (1 << W_EXP) - 2;    // exponent field of the largest finite
  localparam int COUNT_W = $clog2(Q_W);          // iteration counter width
  // Quiet bit of a NaN payload. Sized to MANT_W: `int` arithmetic would
  // overflow for W_MANT >= 32 (e.g. binary64); for W_MANT = 0 (E8M0) the
  // NaN path is unreachable and this constant is never used.
  localparam logic [MANT_W-1:0] QUIET = (MANT_W)'(1) << (MANT_W - 1);
  // Signed versions of the exponent bounds for width-clean comparisons.
  localparam logic signed [W_EXP+4:0] EMAX_S = (W_EXP+4)'(EMAX);
  localparam logic signed [W_EXP+4:0] EMIN_S = (W_EXP+4)'(EMIN);


  // ------------------------------------------------------------- unpack (3.3)
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

  // ------------------------------------------------------- special cases (6.x)
  logic [W-1:0] y_special;
  logic [4:0]   flags_special;
  logic         special_case;
  always_comb begin
    y_special     = '0;
    flags_special = '0;
    special_case  = 1'b0;
    if (is_sqrt) begin
      // fp_sqrt special cases.
      if (a_nan) begin
        // 6.2.3: quiet NaN, payload of the operand; 7.2a: sNaN -> invalid.
        y_special = {1'b0, EXP_ALL[W_EXP-1:0], a_mant | QUIET};
        flags_special[fp_pkg::FLAG_INVALID] = a_snan;
        special_case = 1'b1;
      end else if (a_inf) begin
        if (a_sign) begin
          // 7.2g: sqrt of negative infinity.
          y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
          flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
        end else begin
          y_special = {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        end
        special_case = 1'b1;
      end else if (a_zero) begin
        // 6.3: sqrt(+-0) = +-0.
        y_special = {a_sign, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
        special_case = 1'b1;
      end else if (a_sign) begin
        // 7.2g: sqrt of a negative finite number.
        y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
        flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
        special_case = 1'b1;
      end
    end else begin
      // fp_div special cases.
      if (a_nan || b_nan) begin
        // 6.2.3: quiet NaN, payload of the first NaN operand; 7.2a: sNaN -> invalid.
        y_special = {1'b0, EXP_ALL[W_EXP-1:0], (a_nan ? a_mant : b_mant) | QUIET};
        flags_special[fp_pkg::FLAG_INVALID] = a_snan || b_snan;
        special_case = 1'b1;
      end else if (a_inf || b_inf) begin
        if (a_inf && b_inf) begin
          // 7.2f: magnitude division of infinities.
          y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
          flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
        end else if (a_inf) begin
          // inf / finite = inf; sign is the XOR of the operand signs (6.3).
          y_special = {a_sign ^ b_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        end else begin
          // finite / inf = 0; sign is the XOR of the operand signs (6.3).
          y_special = {a_sign ^ b_sign, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
        end
        special_case = 1'b1;
      end else if (a_zero || b_zero) begin
        if (a_zero && b_zero) begin
          // 7.2f: division of zero by zero.
          y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
          flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
        end else if (a_zero) begin
          // 0 / finite = 0; sign is the XOR of the operand signs (6.3).
          y_special = {a_sign ^ b_sign, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
        end else begin
          // finite / 0 = inf (7.3 divide-by-zero); sign XOR (6.3).
          y_special = {a_sign ^ b_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
          flags_special[fp_pkg::FLAG_DIV0] = 1'b1;
        end
        special_case = 1'b1;
      end
    end
  end

  // ----------------------------------------------------- main datapath setup
  // (both operands finite; for sqrt the operand is positive and non-zero).
  logic [S_W-1:0] s_a, s_b;  // significands with implicit bit (3.3)
  assign s_a = a_sub ? {1'b0, a_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, a_mant};
  assign s_b = b_sub ? {1'b0, b_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, b_mant};

  // Bit length of x (leading-one position + 1); 0 if x is zero. Last set bit
  // wins, i.e. the highest set bit (no break: yosys does not support `break`
  // in for loops).
  function automatic int unsigned bitlen(input logic [S_W-1:0] x);
    bitlen = 0;
    for (int i = 0; i < S_W; i++)
      if (x[i]) bitlen = i + 1;
  endfunction

  // Leading-bit exponents: value = s * 2^e.
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

  // ---- division scaling (fp_div)
  logic [S_W-1:0] a_al, b_al;
  assign a_al = s_a << (S_W - bitlen(s_a));
  assign b_al = s_b << (S_W - bitlen(s_b));

  // Full radicand, consumed MSB-first one bit per division cycle.
  logic [Q_W-1:0] num;
  assign num = (Q_W)'(a_al) << (S_W + 2);
  logic a_ge_b;
  assign a_ge_b = (a_al >= b_al);
  logic signed [W_EXP+3:0] e_res_div;
  assign e_res_div = (W_EXP+4)'(e_a) - (W_EXP+4)'(e_b) - (W_EXP+4)'(a_al < b_al);

  // ---- square-root scaling (fp_sqrt)
  logic [R_W-1:0] X;
  always_comb begin
    int S;
    S = 2*TARGET + int'(e_a[0]) - int'(bitlen(s_a)) + 1;
    X = (R_W)'(s_a) << S;
  end
  logic signed [W_EXP+3:0] e_res_sqrt;
  assign e_res_sqrt = e_a >>> 1;  // floor(e_a / 2)

  logic rsign;  // quotient sign XOR / 0 for sqrt
  assign rsign = is_sqrt ? 1'b0 : (a_sign ^ b_sign);

  // ------------------------------------------------------------- iteration
  logic [1:0]        state;
  localparam logic [1:0] ST_IDLE = 2'd0, ST_RUN = 2'd1, ST_DONE = 2'd2;
  logic [Q_W-1:0]    q;
  logic [R_W-1:0]    rem;
  logic [COUNT_W-1:0] count;

  // Latched iteration context.
  logic              is_sqrt_r, rsign_r, a_ge_b_r;
  logic [2:0]        rm_r;
  logic signed [W_EXP+3:0] e_res_r;
  logic [S_W-1:0]    b_al_r;
  logic [Q_W-1:0]    div_num_r;
  logic [R_W-1:0]    x_r;

  // One restoring step. Division consumes one radicand bit per cycle with the
  // constant divisor b_al; sqrt consumes two radicand bits with the partial
  // root as the trial subtrahend ((q<<2)|1).
  logic [R_W-1:0] rem_next;
  logic [Q_W-1:0] q_next;
  logic           rem_ge_sub;
  always_comb begin
    logic [R_W-1:0] rad_and_sub;
    if (is_sqrt_r) begin
      rem_next    = (rem << 2) | (R_W)'(x_r[2*count +: 2]);
      rad_and_sub = ((R_W)'(q) << 2) | (R_W)'(1);
    end else begin
      rem_next    = (rem << 1) | (R_W)'(div_num_r[count]);
      rad_and_sub = (R_W)'(b_al_r);
    end
    rem_ge_sub = (rem_next >= rad_and_sub);
    rem_next   = rem_ge_sub ? (rem_next - rad_and_sub) : rem_next;
    q_next     = (q << 1) | (Q_W)'(rem_ge_sub);
  end

  // Final placement / sticky from the post-step registers: the full quotient
  // (MSB at TARGET after the optional a_al < b_al shift) or the root
  // significand. The final remainder is the sticky in both cases (division:
  // remainder != 0 iff the quotient has dropped fraction bits; sqrt:
  // remainder != 0 iff X is not a perfect square).
  logic [FW-1:0] placed;
  logic          norm_sticky;
  always_comb begin
    if (is_sqrt_r) begin
      placed      = FW'(q_next);
      norm_sticky = |rem_next;
    end else begin
      placed      = a_ge_b_r ? FW'(q_next) : FW'(q_next << 1);
      norm_sticky = |rem_next;
    end
  end

  // ------------------------------------------- rounding (4.3), copied from
  // fp_div/fp_sqrt so the iterative engine is bit-exact with them.
  logic [S_W-1:0] sig;
  logic           g, r, s_bit, lsb, inexact, round_up, carry;
  /* verilator lint_off UNUSEDSIGNAL */
  // sig_rnd[S_W-1] is the implicit (leading) bit, always 1 after
  // normalization; only the W_MANT explicit bits are emitted in y_normal.
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
      sig_rnd = {1'b1, {W_MANT{1'b0}}};  // renormalized after the carry
      e_rnd   = e_res_r + 1;
    end else begin
      sig_rnd = sig + { {S_W-1{1'b0}}, round_up };
      e_rnd   = e_res_r;
    end
    exp_fld = e_rnd[W_EXP-1:0] + BIAS[W_EXP-1:0];
    if ($signed(e_rnd) > EMAX_S) begin
      // Overflow (7.4): default result by rounding attribute; inexact always.
      // Unreachable for sqrt, kept for structural consistency with fp_div.
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

  // ----------------------------------------------------- rounding, subnormal
  // path: e_res < EMIN. Round on the subnormal grid (ulp = 2^(emin-W_MANT)).
  logic [W-1:0] y_sub;
  logic [4:0]   flags_sub;
  always_comb begin
    int signed          shift;
    logic [FW-1:0]      shifted;
    logic [S_W-1:0]     sig_s;
    logic               gs, rs, ss, inexact_s, up_s;
    logic [S_W-1:0]     sig_s2;
    shift = int'(EMIN - int'(e_res_r));
    if (shift > 0) shifted = placed >> shift;
    else           shifted = '0;
    sig_s  = shifted[TARGET -: S_W];
    gs     = shifted[2];
    rs     = shifted[1];
    ss     = shifted[0] | norm_sticky
           | |(placed & (((FW)'(1) << (shift > 0 ? shift : 0)) - 1));
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
      // Rounded up to the smallest normal number. For a degenerate exponent
      // range (W_EXP = 1, EMIN > EMAX) the smallest normal 2^emin already
      // exceeds the largest finite number, so this is overflow per 7.4
      // whenever the p-bit (unbounded-range) rounding carries past 2^emin
      // (same rule as fp_mul/fp_div/fp_sqrt).
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
      // Rounded to zero; keeps the sign of the exact result.
      y_sub = {rsign_r, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
      flags_sub = inexact_s ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
    end else begin
      y_sub = {rsign_r, {W_EXP{1'b0}}, sig_s2[MANT_W-1:0]};
      flags_sub = 5'd0;
      // 7.5 (tininess after rounding): tiny non-zero rounded result, inexact.
      if (inexact_s) begin
        flags_sub[fp_pkg::FLAG_UNDERFLOW] = 1'b1;
        flags_sub[fp_pkg::FLAG_INEXACT]   = 1'b1;
      end
    end
  end

  logic [W-1:0] y_result;
  logic [4:0]   flags_result;
  always_comb begin
    if ($signed(e_res_r) >= EMIN_S) begin
      y_result     = y_normal;
      flags_result = flags_normal;
    end else begin
      y_result     = y_sub;
      flags_result = flags_sub;
    end
  end

  // ----------------------------------------------------------------- control
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state          <= ST_IDLE;
      busy           <= 1'b0;
      done           <= 1'b0;
      y              <= '0;
      flags          <= 5'd0;
      q              <= '0;
      rem            <= '0;
      count          <= '0;
      is_sqrt_r      <= 1'b0;
      rsign_r        <= 1'b0;
      a_ge_b_r       <= 1'b0;
      rm_r           <= 3'd0;
      e_res_r        <= '0;
      b_al_r         <= '0;
      div_num_r      <= '0;
      x_r            <= '0;
    end else begin
      done <= 1'b0;
      case (state)
        ST_IDLE: begin
          busy <= 1'b0;
          if (start) begin
            is_sqrt_r       <= is_sqrt;
            rsign_r         <= rsign;
            a_ge_b_r        <= a_ge_b;
            rm_r            <= rm;
            e_res_r         <= is_sqrt ? e_res_sqrt : e_res_div;
            b_al_r          <= b_al;
            div_num_r       <= num;
            x_r             <= X;
            q               <= '0;
            rem             <= '0;
            // Division runs 2*S_W+2 iterations (one radicand bit each), sqrt
            // FW iterations (two radicand bits each).
            count           <= COUNT_W'(is_sqrt ? FW - 1 : Q_W - 1);
            if (special_case) begin
              y     <= y_special;
              flags <= flags_special;
              state <= ST_DONE;
              done  <= 1'b1;
            end else begin
              state <= ST_RUN;
              busy  <= 1'b1;
            end
          end
        end
        ST_RUN: begin
          if (count == '0) begin
            // Last iteration: q_next/rem_next are the final quotient/root and
            // remainder; round and publish.
            y      <= y_result;
            flags  <= flags_result;
            state  <= ST_DONE;
            busy   <= 1'b0;
            done   <= 1'b1;
          end else begin
            q     <= q_next;
            rem   <= rem_next;
            count <= count - 1'b1;
          end
        end
        ST_DONE: state <= ST_IDLE;
        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule
