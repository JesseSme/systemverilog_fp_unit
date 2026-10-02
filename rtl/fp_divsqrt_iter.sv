// Iterative (multi-cycle) IEEE 754-2019 division / square root datapath.
//
// This is the area/Fmax alternative to the fully combinational fp_div and
// fp_sqrt modules: one shared radix-4 restoring engine produces either two
// quotient bits per cycle (division) or two square-root bits per cycle
// (sqrt), so a single small adder/subtractor and a compare tree replace the
// two large combinational arrays. Semantics are bit-exact with fp_div/fp_sqrt:
// same special cases, same GRS rounding on the exact quotient/root grid, same
// overflow/underflow/inexact rules (7.2-7.6).
//
// THE LATENCY IS CONSTANT (input-independent), including for special cases:
//   cycles from `start` to `done` = K + 4, with K = ceil((W_MANT+3)/2)
// (e.g. binary32: 17 cycles; binary64: 31). One radix-4 digit is produced per
// cycle: the digit selection (compare against the precomputed divisor
// multiples / the current root candidates) and the remainder subtraction are
// fused into a single registered step, so the engine runs at one cycle per
// digit instead of the former two. `done` pulses one cycle with the
// registered y/flags.
//
// Division (fp_div math): q_raw = floor(num / b_al) with
// num = a_al << (S_W+2), a_al/b_al the significands normalized to MSB at
// S_W-1. The top two quotient bits (positions TARGET and TARGET-1) are
// precomputed in the start cycle: d0 = floor(2*a_al/b_al) and
// rem0 = 2*a_al - d0*b_al. After that preload the remaining radicand bits
// num[S_W..0] are all zero, so each radix-4 step is p = 4*rem, digit
// d = floor(p/b_al) selected from the precomputed multiples b, 2b, 3b, and
// rem = p - d*b_al. The quotient accumulates two bits per cycle; the final
// remainder is the sticky (norm_sticky = |rem). placed is q with its MSB at
// TARGET (one extra shift when a_al < b_al).
//
// Square root (fp_sqrt math): placed = floor(sqrt(X)) with
// X = s_a << (2*TARGET + e_a[0] - bitlen(s_a) + 1). The first radix-4 digit
// is precomputed from the top four radicand bits v = X >> (R_W-4):
// d0 = floor(sqrt(v)) (2 or 3, since X is normalized) and rem0 = v - d0^2.
// Each radix-4 step consumes four radicand bits and selects the maximal
// digit d in {0,1,2,3} with rem*16 + bits >= d*(8*q+d), i.e. compares
// against 8q+1, 16q+4 and 24q+9. The final remainder is exactly X - placed^2,
// the sticky (zero iff X is a perfect square).
//
// When W_MANT is odd the number of quotient/root bits after the two preloaded
// bits is odd; the last cycle then runs a radix-2 half-step (one bit) instead
// of a radix-4 step. The step count is unchanged, so the latency stays
// constant. E8M0 (W_MANT = 0) never instantiates this module.

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
  localparam int R_W     = 2 * S_W + 6;          // radicand / remainder width (= 2*FW)
  // Radix-4 iterations after the 2-bit preload; ceil((W_MANT+2)/2).
  localparam int K       = (W_MANT + 3) / 2;
  // When W_MANT is odd one final radix-2 half-step completes the last bit.
  localparam bit STEP2_LAST = (W_MANT % 2) == 1;
  localparam int POS_W   = $clog2(R_W + 1);      // radicand position counter
  localparam int COUNT_W = $clog2(K + 1);        // iteration counter
  localparam logic [POS_W-1:0] POS_INIT = (POS_W)'(R_W - 4);
  localparam int EXP_ALL = (1 << W_EXP) - 1;     // all-ones exponent field
  localparam int EXP_MAXF = (1 << W_EXP) - 2;    // exponent field of the largest finite
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
  assign a_sign = a_r[W-1];
  assign a_exp  = a_r[W-2 -: W_EXP];
  assign b_sign = b_r[W-1];
  assign b_exp  = b_r[W-2 -: W_EXP];
  always_comb begin
    a_mant = '0;
    b_mant = '0;
    if (W_MANT > 0) begin
      a_mant = a_r[W_MANT-1:0];
      b_mant = b_r[W_MANT-1:0];
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
    if (is_sqrt_r) begin
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

  // ---- division scaling and 2-bit preload (fp_div)
  logic [S_W-1:0] a_al, b_al;
  assign a_al = s_a << (S_W - bitlen(s_a));
  assign b_al = s_b << (S_W - bitlen(s_b));


  // First radix-4 digit d0 = floor(2*a_al/b_al) (0..3 because
  // 2*a_al < 4*b_al) and rem0 = 2*a_al - d0*b_al < b_al: the exact state of
  // the restoring recurrence at quotient position TARGET-1.
  logic [S_W+1:0] two_a, two_b, three_b;
  assign two_a   = (S_W+2)'(a_al) << 1;
  assign two_b   = (S_W+2)'(b_al) << 1;
  assign three_b = two_b + (S_W+2)'(b_al);

  // ---- square-root scaling and first-digit preload (fp_sqrt)
  logic [R_W-1:0] X;
  always_comb begin
    int S;
    S = 2*TARGET + int'(e_a[0]) - int'(bitlen(s_a)) + 1;
    X = (R_W)'(s_a) << S;
  end
  logic signed [W_EXP+3:0] e_res_sqrt;
  assign e_res_sqrt = e_a >>> 1;  // floor(e_a / 2)

  // v = top 4 radicand bits (X is normalized so its MSB is at R_W-1 or
  // R_W-2, hence v in [4,16)); d0 = floor(sqrt(v)) is 2 or 3.
  logic [3:0]     v4;
  logic [1:0]     d0_sqrt;
  logic [R_W-1:0] rem0_sqrt;
  assign v4       = X[R_W-1 -: 4];
  assign d0_sqrt  = (v4 >= 4'd9) ? 2'd3 : 2'd2;
  assign rem0_sqrt = (R_W)'(v4) - (R_W)'(d0_sqrt) * (R_W)'(d0_sqrt);

  logic rsign;  // quotient sign XOR / 0 for sqrt
  assign rsign = is_sqrt_r ? 1'b0 : (a_sign ^ b_sign);

  // ------------------------------------------------------------- iteration
  logic [2:0]        state;
  localparam logic [2:0] ST_IDLE = 3'd0, ST_PREP1 = 3'd1, ST_PREP2 = 3'd2,
                         ST_STEP = 3'd3, ST_PUB = 3'd4;
  logic [FW-1:0]     q;
  logic [R_W-1:0]    rem;
  logic [POS_W-1:0]  pos;
  logic [COUNT_W-1:0] count;

  // Latched iteration context.
  logic [W-1:0]      a_r, b_r;
  logic              is_sqrt_r, rsign_r, a_ge_b_r, special_r;
  logic [2:0]        rm_r;
  logic signed [W_EXP+3:0] e_res_r;
  logic [W-1:0]      y_special_r;
  logic [4:0]        flags_special_r;
  logic [S_W-1:0]    b_al_r;
  logic [S_W+1:0]    two_b_r, three_b_r;
  logic [R_W-1:0]    x_r;
  // phase-1 latches (wide preload operands)
  logic [S_W-1:0]    a_al_p, b_al_p;
  logic [S_W+1:0]    two_a_p;
  logic signed [W_EXP+2:0] e_a_p, e_b_p;
  logic signed [W_EXP+3:0] e_res_sqrt_p;
  logic [1:0]        d0_sqrt_p;
  logic [R_W-1:0]    rem0_sqrt_p;

  // One-cycle radix-4 digit step: p (the shifted remainder with the new
  // radicand bits), the candidate subtrahends, the selected digit and the
  // remainder subtraction all resolve in the same cycle. `half_step` selects
  // the radix-2 final step for odd W_MANT.
  logic [R_W-1:0] p_a, sel_a;
  logic [1:0]     d4_a;
  logic           d2_a, half_step;
  always_comb begin
    logic [R_W-1:0] t1, t2, t3;
    half_step = STEP2_LAST && (count == '0);
    p_a = '0; sel_a = '0; d4_a = 2'd0; d2_a = 1'b0;
    t1 = '0; t2 = '0; t3 = '0;
    if (is_sqrt_r) begin
      if (half_step) begin
        p_a  = (rem << 2) | (R_W)'(x_r[pos - 2 +: 2]);
        t1   = ((R_W)'(q) << 2) | (R_W)'(1);
        d2_a = (p_a >= t1);
        sel_a = d2_a ? t1 : '0;
      end else begin
        p_a  = (rem << 4) | (R_W)'(x_r[pos - 4 +: 4]);
        t1 = ((R_W)'(q) << 3) | (R_W)'(1);                     //  8q+1
        t2 = ((R_W)'(q) << 4) | (R_W)'(4);                     // 16q+4
        t3 = ((R_W)'(q) << 4) + ((R_W)'(q) << 3) + (R_W)'(9);  // 24q+9
        if      (p_a >= t3) begin d4_a = 2'd3; sel_a = t3; end
        else if (p_a >= t2) begin d4_a = 2'd2; sel_a = t2; end
        else if (p_a >= t1) begin d4_a = 2'd1; sel_a = t1; end
        else                begin d4_a = 2'd0; sel_a = '0; end
      end
    end else begin
      if (half_step) begin
        p_a  = rem << 1;
        d2_a = (p_a >= (R_W)'(b_al_r));
        sel_a = d2_a ? (R_W)'(b_al_r) : '0;
      end else begin
        p_a = rem << 2;
        if      (p_a >= (R_W)'(three_b_r)) begin d4_a = 2'd3; sel_a = (R_W)'(three_b_r); end
        else if (p_a >= (R_W)'(two_b_r))   begin d4_a = 2'd2; sel_a = (R_W)'(two_b_r);   end
        else if (p_a >= (R_W)'(b_al_r))    begin d4_a = 2'd1; sel_a = (R_W)'(b_al_r);    end
        else                               begin d4_a = 2'd0; sel_a = '0;                end
      end
    end
  end

  // Apply the subtraction and shift in the digit (same cycle as the select).
  logic [R_W-1:0] rem_b;
  logic [FW-1:0]  q_b;
  always_comb begin
    rem_b = p_a - sel_a;
    if (half_step)
      q_b = (q << 1) | (FW)'(d2_a);
    else
      q_b = (q << 2) | (FW)'(d4_a);
  end

  // Final placement / sticky from the registered quotient/root and remainder
  // (the publish cycle rounds these; in the step cycles the value is unused).
  // Keeping the rounding off q_b/rem_b avoids re-introducing the digit-step
  // (compare/mux/subtract) path into the publish cycle's static timing.
  // The final remainder is the sticky in both cases (division: remainder != 0
  // iff the quotient has dropped fraction bits; sqrt: remainder != 0 iff X is
  // not a perfect square).
  logic [FW-1:0] placed;
  logic          norm_sticky;
  always_comb begin
    if (is_sqrt_r) begin
      placed      = FW'(q);
      norm_sticky = |rem;
    end else begin
      placed      = a_ge_b_r ? FW'(q) : FW'(q << 1);
      norm_sticky = |rem;
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
  // Constant latency: K one-cycle digit steps, then `done` (start cycle + K
  // cycles + the done cycle). Special cases run the same countdown so the
  // latency does not depend on the operands.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state           <= ST_IDLE;
      busy            <= 1'b0;
      done            <= 1'b0;
      y               <= '0;
      flags           <= 5'd0;
      q               <= '0;
      rem             <= '0;
      pos             <= '0;
      count           <= '0;
      is_sqrt_r       <= 1'b0;
      rsign_r         <= 1'b0;
      a_ge_b_r        <= 1'b0;
      special_r       <= 1'b0;
      rm_r            <= 3'd0;
      e_res_r         <= '0;
      y_special_r     <= '0;
      flags_special_r <= 5'd0;
      b_al_r          <= '0;
      two_b_r         <= '0;
      three_b_r       <= '0;
      x_r             <= '0;
      a_r             <= '0;
      b_r             <= '0;
      a_al_p          <= '0;
      b_al_p          <= '0;
      two_a_p         <= '0;
      e_a_p           <= '0;
      e_b_p           <= '0;
      e_res_sqrt_p    <= '0;
      d0_sqrt_p       <= '0;
      rem0_sqrt_p     <= '0;
    end else begin
      done <= 1'b0;
      case (state)
        ST_IDLE: begin
          busy <= 1'b0;
          if (start) begin
            // Phase 1: latch the raw inputs only (short path from the ports).
            a_r       <= a;
            b_r       <= b;
            rm_r      <= rm;
            is_sqrt_r <= is_sqrt;
            state     <= ST_PREP1;
            busy      <= 1'b1;
          end
        end
        ST_PREP1: begin
          // Phase 2: classification, significands, exponents, alignment and
          // the sqrt preload (all shallow from the latched inputs).
          rsign_r         <= rsign;
          special_r       <= special_case;
          y_special_r     <= y_special;
          flags_special_r <= flags_special;
          b_al_r          <= b_al;
          two_b_r         <= two_b;
          three_b_r       <= three_b;
          x_r             <= X;
          a_al_p          <= a_al;
          b_al_p          <= b_al;
          two_a_p         <= two_a;
          e_a_p           <= e_a;
          e_b_p           <= e_b;
          e_res_sqrt_p    <= e_res_sqrt;
          d0_sqrt_p       <= d0_sqrt;
          rem0_sqrt_p     <= rem0_sqrt;
          state           <= ST_PREP2;
        end
        ST_PREP2: begin
          // Phase 3: the division digit selection / preload subtraction (the
          // widest arithmetic of the setup) is computed from the phase-1
          // latches.
          a_ge_b_r <= (a_al_p >= b_al_p);
          e_res_r  <= is_sqrt_r ? e_res_sqrt_p
                                : (W_EXP+4)'(e_a_p) - (W_EXP+4)'(e_b_p)
                                  - (W_EXP+4)'(a_al_p < b_al_p);
          q        <= is_sqrt_r ? (FW)'(d0_sqrt_p)
                                : (FW)'((two_a_p >= three_b_r) ? 2'd3
                                      : (two_a_p >= two_b_r)   ? 2'd2
                                      : (two_a_p >= b_al_r)    ? 2'd1 : 2'd0);
          rem      <= is_sqrt_r ? rem0_sqrt_p
                                : (R_W)'(two_a_p
                                   - (S_W+2)'((two_a_p >= three_b_r) ? 2'd3
                                            : (two_a_p >= two_b_r)   ? 2'd2
                                            : (two_a_p >= b_al_r)    ? 2'd1 : 2'd0)
                                   * (S_W+2)'(b_al_r));
          pos      <= POS_INIT;
          count    <= COUNT_W'(K - 1);
          state    <= ST_STEP;
        end
        ST_STEP: begin
          q     <= q_b;
          rem   <= rem_b;
          if (count == '0) begin
            // Last digit applied: publish the rounded result from the
            // registered quotient/root and remainder in the next cycle (the
            // publish cycle keeps the rounding off the digit-step path).
            state <= ST_PUB;
          end else begin
            pos   <= pos - (half_step ? (POS_W)'(2) : (POS_W)'(4));
            count <= count - 1'b1;
          end
        end
        ST_PUB: begin
          // Round and publish (or publish the latched special). The next
          // transaction may start on this same cycle (engine busy is low),
          // keeping back-to-back div/sqrt free of dead cycles.
          y      <= special_r ? y_special_r : y_result;
          flags  <= special_r ? flags_special_r : flags_result;
          state  <= ST_IDLE;
          busy   <= 1'b0;
          done   <= 1'b1;
        end
        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule
