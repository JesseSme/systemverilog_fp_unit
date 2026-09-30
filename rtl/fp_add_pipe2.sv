// Two-stage pipelined binary floating-point adder (OP_ADD, RM_RNE).
//
// Functionally identical to fp_add with op = OP_ADD and rm = RM_RNE (same
// alignment, sign-magnitude add, normalization, rounding, subnormal and
// special-case semantics; y is bit-identical to fp_add's y for the same
// operands), but with a register bank after the exponent alignment and an
// output register, giving a documented 2-cycle latency:
//
//   operands present in cycle t  ->  y valid in cycle t + 2
//
// one result per cycle in steady state. a and b are sampled every cycle;
// there is no handshake.
//
// The internal cut matters when several independent accumulation contexts
// interleave through the same adder (matrix_unit): the register-to-register
// feedback path becomes
//
//   y -> operand mux -> unpack / leading-one / align -> stage-1 register
//
// instead of the original single-cycle accumulation loop
// y -> full fp_add datapath -> y.
//
// Only the matrix_unit accumulator path uses this module, which always adds
// with roundTiesToEven, so a/b/y is the whole interface (no rm/op/flags).

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
// Int arithmetic is deliberately mixed with sized logic; every expression is
// bounded such that the truncation/extensions are exact (same convention as
// fp_add.sv).

module fp_add_pipe2 #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23
) (
  input  logic                      clk,
  input  logic                      rst_n,
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
  output logic [1+W_EXP+W_MANT-1:0] y
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
  // Quiet bit of a NaN payload. Sized to MANT_W: `int` arithmetic would
  // overflow for W_MANT >= 32 (e.g. binary64); for W_MANT = 0 (E8M0) the
  // NaN path is unreachable and this constant is never used.
  localparam logic [MANT_W-1:0] QUIET = (MANT_W)'(1) << (MANT_W - 1);
  // Signed versions of the exponent bounds for width-clean comparisons.
  localparam logic signed [W_EXP+4:0] EMAX_S = (W_EXP+4)'(EMAX);
  localparam logic signed [W_EXP+4:0] EMIN_S = (W_EXP+4)'(EMIN);

  // ================================================== stage 1 (combinational)
  // Unpack, special cases, leading-bit exponents and exponent alignment.

  logic              a_sign, b_sign;
  logic [W_EXP-1:0]  a_exp, b_exp;
  logic [MANT_W-1:0] a_mant, b_mant;
  assign a_sign = a[W-1];
  assign a_exp  = a[W-2 -: W_EXP];
  assign b_sign = b[W-1];
  assign b_exp  = b[W-2 -: W_EXP];
  // The mantissa field is empty for W_MANT = 0 (E8M0); the width guard keeps
  // the extraction from producing a negative index (constant condition, so
  // the dead branch is eliminated at elaboration).
  always_comb begin
    a_mant = '0;
    b_mant = '0;
    if (W_MANT > 0) begin
      a_mant = a[W_MANT-1:0];
      b_mant = b[W_MANT-1:0];
    end
  end

  // Signaling-NaN detection is not needed here (no flags output).
  logic a_nan, a_inf, a_zero, a_sub;
  logic b_nan, b_inf, b_zero, b_sub;
  assign a_nan  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant != '0);
  assign a_inf  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant == '0);
  assign a_zero = (a_exp == '0) && (a_mant == '0);
  assign a_sub  = (a_exp == '0) && (a_mant != '0);
  assign b_nan  = (b_exp == EXP_ALL[W_EXP-1:0]) && (b_mant != '0);
  assign b_inf  = (b_exp == EXP_ALL[W_EXP-1:0]) && (b_mant == '0);
  assign b_zero = (b_exp == '0) && (b_mant == '0);
  assign b_sub  = (b_exp == '0) && (b_mant != '0);

  // Special cases (6.x), specialized to OP_ADD/RM_RNE exactly as fp_add:
  // NaN payloads, infinity sums, and the zero cases (the roundTowardNegative
  // -0 quirk of fp_add does not apply under RNE: opposite-sign zero addends
  // give +0).
  logic [W-1:0] y_special;
  logic         special_case;
  always_comb begin
    y_special    = '0;
    special_case = 1'b0;
    if (a_nan || b_nan) begin
      // 6.2.3: quiet NaN, payload of the first NaN operand (7.2a invalid has
      // no observable effect here: no flags output).
      y_special = {1'b0, EXP_ALL[W_EXP-1:0], (a_nan ? a_mant : b_mant) | QUIET};
      special_case = 1'b1;
    end else if (a_inf || b_inf) begin
      if (a_inf && b_inf) begin
        if (a_sign == b_sign)
          y_special = {a_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        else
          // 7.2d: magnitude subtraction of infinities.
          y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
      end else if (a_inf) begin
        y_special = {a_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      end else begin
        y_special = {b_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      end
      special_case = 1'b1;
    end else if (a_zero && b_zero) begin
      // 6.3 under RNE: opposite-sign zeros sum to +0.
      y_special = {(a_sign == b_sign) ? a_sign : 1'b0,
                   {W_EXP{1'b0}}, {W_MANT{1'b0}}};
      special_case = 1'b1;
    end else if (a_zero) begin
      y_special = {b_sign, b_exp, b_mant};  // 0 + b = b
      special_case = 1'b1;
    end else if (b_zero) begin
      y_special = a;                        // a + 0 = a
      special_case = 1'b1;
    end
  end

  // Significands with implicit bit (3.3); same OR form as fp_add (keeps the
  // width exactly S_W even for W_MANT = 0).
  logic [S_W-1:0] s_a, s_b;
  assign s_a = a_sub ? {1'b0, a_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, a_mant};
  assign s_b = b_sub ? {1'b0, b_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, b_mant};

  // Balanced leading-one encoder (same algorithm as fp_add.sv): a one-hot
  // prefix reduction marks the highest set bit, then constant masks reduce it
  // to the integer index (no loop-carried accumulator, log-depth logic).
  localparam int BL_IW = $clog2(S_W + 1);

  function automatic int unsigned bitlen(input logic [S_W-1:0] x);
    logic [S_W-1:0]              lead;   // one-hot highest set bit
    logic [BL_IW-1:0][S_W-1:0]   vmask;  // vmask[k][i] = bit k of (i+1)
    logic [S_W-1:0]              amask;  // bits strictly above position i
    bitlen = '0;
    for (int i = 0; i < S_W; i++) begin
      // Bit i is the leading one iff no bit above it is set. At i = S_W-1 the
      // shift by S_W yields zero, so amask = 0 and no special case is needed.
      amask   = ~(((S_W)'(1) << (i + 1)) - (S_W)'(1));
      lead[i] = x[i] & ~(|(x & amask));
    end
    for (int k = 0; k < BL_IW; k++)
      for (int i = 0; i < S_W; i++)
        vmask[k][i] = ((i + 1) >> k) & 1'b1;
    for (int k = 0; k < BL_IW; k++)
      bitlen[k] = |(lead & vmask[k]);
  endfunction

  // Leading-one position of x; 0 if x is zero.
  localparam int LP_IW = $clog2(SUM_W + 1);

  function automatic int unsigned lpos(input logic [SUM_W-1:0] x);
    logic [SUM_W-1:0]            lead;   // one-hot highest set bit
    logic [LP_IW-1:0][SUM_W-1:0] vmask;  // vmask[k][i] = bit k of i
    logic [SUM_W-1:0]            amask;  // bits strictly above position i
    lpos = '0;
    for (int i = 0; i < SUM_W; i++) begin
      amask   = ~(((SUM_W)'(1) << (i + 1)) - (SUM_W)'(1));
      lead[i] = x[i] & ~(|(x & amask));
    end
    for (int k = 0; k < LP_IW; k++)
      for (int i = 0; i < SUM_W; i++)
        vmask[k][i] = (i >> k) & 1'b1;
    for (int k = 0; k < LP_IW; k++)
      lpos[k] = |(lead & vmask[k]);
  endfunction

  // Leading-bit exponents: value = s * 2^e (same as fp_add; the exponent
  // fields are unsigned and the signed BIAS promotes the subtraction).
  logic signed [W_EXP+2:0] e_a, e_b;
  always_comb begin
    // bitlen is computed unconditionally (yosys would otherwise leave a
    // don't-care anyseq on the branch that does not call it, corrupting the
    // formal model when multiple instances are elaborated).
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

  // Align the smaller-magnitude significand to the larger exponent (the
  // alignment stage is where the pipeline register bank is inserted).
  logic [FW-1:0] fp_a, fp_b;
  logic          shift_sticky_a, shift_sticky_b;
  logic          align_sticky;
  assign align_sticky = shift_sticky_a | shift_sticky_b;
  always_comb begin
    int rshift;
    logic [FW-1:0] placed;
    rshift = int'(e_max - e_a);
    placed = FW'($unsigned(s_a)) << (TARGET - bitlen(s_a) + 1);
    if (rshift >= FW) begin
      fp_a = '0;
      shift_sticky_a = |placed;
    end else begin
      fp_a = FW'(placed >> rshift);
      shift_sticky_a = |(placed & ((FW)'(1) << rshift) - 1);
    end
    rshift = int'(e_max - e_b);
    placed = FW'($unsigned(s_b)) << (TARGET - bitlen(s_b) + 1);
    if (rshift >= FW) begin
      fp_b = '0;
      shift_sticky_b = |placed;
    end else begin
      fp_b = placed >> rshift;
      shift_sticky_b = |(placed & ((FW)'(1) << rshift) - 1);
    end
  end

  // Sign-magnitude comparison is independent of the add/sub choice, so it is
  // computed on the stage-1 side of the register and only ge is carried over.
  logic ge, same_sign;
  assign ge        = ({1'b0, fp_a} >= {1'b0, fp_b});
  assign same_sign = (a_sign == b_sign);

  // ================================================= stage 1 -> stage 2 regs
  logic [FW-1:0]           fp_a_q, fp_b_q;
  logic                    align_sticky_q;
  logic                    same_sign_q;
  logic                    ge_q;
  logic                    a_sign_q, b_sign_q;
  logic signed [W_EXP+2:0] e_max_q;
  logic [W-1:0]            y_special_q;
  logic                    special_case_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fp_a_q         <= '0;
      fp_b_q         <= '0;
      align_sticky_q <= 1'b0;
      same_sign_q    <= 1'b0;
      ge_q           <= 1'b0;
      a_sign_q       <= 1'b0;
      b_sign_q       <= 1'b0;
      e_max_q        <= '0;
      y_special_q    <= '0;
      special_case_q <= 1'b0;
    end else begin
      fp_a_q         <= fp_a;
      fp_b_q         <= fp_b;
      align_sticky_q <= align_sticky;
      same_sign_q    <= same_sign;
      ge_q           <= ge;
      a_sign_q       <= a_sign;
      b_sign_q       <= b_sign;
      e_max_q        <= e_max;
      y_special_q    <= y_special;
      special_case_q <= special_case;
    end
  end

  // ==================================================== stage 2 (combinational)
  // Sign-magnitude addition, normalization, rounding and result selection:
  // the same equations as fp_add's main path with rm = RM_RNE.

  logic [SUM_W-1:0] mag;
  logic             rsign;
  logic             cancel;      // exact cancellation to zero (6.3)
  logic             diff_sticky; // effective subtraction with lost bits
  always_comb begin
    if (same_sign_q) begin
      mag         = {1'b0, fp_a_q} + {1'b0, fp_b_q};
      rsign       = a_sign_q;
      cancel      = 1'b0;
      diff_sticky = 1'b0;
    end else if (ge_q) begin
      mag         = {1'b0, fp_a_q} - {1'b0, fp_b_q};
      rsign       = a_sign_q;
      cancel      = (mag == '0);
      diff_sticky = align_sticky_q;
      if (diff_sticky) mag = mag - 1;
    end else begin
      mag         = {1'b0, fp_b_q} - {1'b0, fp_a_q};
      rsign       = b_sign_q;
      cancel      = (mag == '0);
      diff_sticky = align_sticky_q;
      if (diff_sticky) mag = mag - 1;
    end
  end

  // Normalize: bring the leading one to bit TARGET; exponent of the result.
  int                    p0;
  logic [NORM_W-1:0]     norm;
  logic                  norm_sticky;
  logic signed [W_EXP+3:0] e_res;
  always_comb begin
    p0 = int'(lpos(mag));
    norm_sticky = align_sticky_q;  // sticky bits lost during operand alignment
    if (p0 > TARGET) begin
      // Carry out of the significand field: shift right one, bump exponent.
      norm = {(NORM_W-SUM_W+1)'(1'b0), mag} >> 1;
      norm_sticky |= mag[0];
      e_res = (W_EXP+4)'(e_max_q) + 1;
    end else if (p0 < TARGET) begin
      // Left-normalize (no bits lost: the field is wide enough).
      norm = {(NORM_W-SUM_W)'(1'b0), mag} << (TARGET - p0);
      e_res = (W_EXP+4)'(e_max_q) + (W_EXP+4)'($signed(p0) - TARGET);
    end else begin
      norm = {(NORM_W-SUM_W)'(1'b0), mag};
      e_res = (W_EXP+4)'(e_max_q);
    end
  end

  // Rounding, normal path (4.3), RM_RNE only.
  logic [S_W-1:0] sig;
  logic           g, r, s_bit, lsb, round_up, carry;
  /* verilator lint_off UNUSEDSIGNAL */
  // sig_rnd[S_W-1] is the implicit (leading) bit, always 1 after
  // normalization; only the W_MANT explicit bits are emitted in y_normal.
  logic [S_W-1:0] sig_rnd;
  /* verilator lint_on UNUSEDSIGNAL */
  logic signed [W_EXP+3:0] e_rnd;
  logic [W-1:0]   y_normal;
  always_comb begin
    logic [W_EXP-1:0] exp_fld;
    sig     = norm[TARGET -: S_W];
    g       = norm[2];
    r       = norm[1];
    s_bit   = norm[0] | norm_sticky;
    lsb     = sig[0];
    round_up = g & (r | s_bit) | (g & ~r & ~s_bit & lsb);
    carry = round_up && (sig == {S_W{1'b1}});
    if (carry) begin
      sig_rnd = {1'b1, {W_MANT{1'b0}}};  // renormalized after the carry
      e_rnd   = e_res + 1;
    end else begin
      sig_rnd = sig + { {S_W-1{1'b0}}, round_up };
      e_rnd   = e_res;
    end
    exp_fld = e_rnd[W_EXP-1:0] + BIAS[W_EXP-1:0];
    if ($signed(e_rnd) > EMAX_S) begin
      // Overflow (7.4) under RNE: infinity.
      y_normal = {rsign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
    end else begin
      y_normal = {rsign, exp_fld, sig_rnd[MANT_W-1:0]};
    end
  end

  // Rounding, subnormal path (e_res < EMIN), RM_RNE only. Same structure and
  // generate guard as fp_add (including the degenerate-emax overflow case).
  logic [W-1:0] y_sub;
  generate
    if (W_MANT > 0) begin : g_subnormal
      always_comb begin
        // shift must be signed: when the result is normal it is negative,
        // and an unsigned wrap would make the sticky loop iterate 2^32 times.
        int signed          shift;
        /* verilator lint_off UNUSEDSIGNAL */
        logic [NORM_W-1:0]  shifted;
        /* verilator lint_on UNUSEDSIGNAL */
        logic [S_W-1:0]     sig_s;
        logic               gs, rs, ss, up_s;
        logic [S_W-1:0]     sig_s2;
        shift = int'(EMIN - int'(e_res));
        if (shift > 0) shifted = norm >> shift;
        else           shifted = '0;
        sig_s  = shifted[TARGET -: S_W];
        gs     = shifted[2];
        rs     = shifted[1];
        ss     = shifted[0] | norm_sticky
               | |(norm & (((NORM_W)'(1) << (shift > 0 ? shift : 0)) - 1));
        up_s   = gs & (rs | ss) | (gs & ~rs & ~ss & sig_s[0]);  // RNE
        sig_s2 = sig_s + { {S_W-1{1'b0}}, up_s };
        if (sig_s2 == {1'b1, {W_MANT{1'b0}}}) begin
          // Rounded up to the smallest normal number; for a degenerate
          // exponent range (W_EXP = 1, EMIN > EMAX) the p-bit rounding can
          // overflow past the largest finite (7.4) whenever guard+round
          // carry for RNE.
          if (EMIN > EMAX && gs && rs)
            y_sub = {rsign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
          else
            y_sub = {rsign, {W_EXP-1{1'b0}}, 1'b1, {W_MANT{1'b0}}};
        end else if (sig_s2 == '0) begin
          // Rounded to zero; keeps the sign of the exact result.
          y_sub = {rsign, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
        end else begin
          y_sub = {rsign, {W_EXP{1'b0}}, sig_s2[MANT_W-1:0]};
        end
      end
    end else begin : g_no_subnormal
      // Unreachable: no subnormal encodings exist for W_MANT = 0.
      assign y_sub = {rsign, {W_EXP{1'b0}}};
    end
  endgenerate

  // --------------------------------------------------------------- result
  logic [W-1:0] y_next;
  always_comb begin
    if (special_case_q) begin
      y_next = y_special_q;
    end else if (cancel) begin
      y_next = '0;  // RNE: the roundTowardNegative -0 case cannot occur
    end else if ($signed(e_res) >= EMIN_S) begin
      y_next = y_normal;
    end else begin
      y_next = y_sub;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) y <= '0;
    else        y <= y_next;
  end

endmodule
