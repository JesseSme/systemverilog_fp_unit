// Two-stage pipelined binary floating-point multiplier (RM_RNE).
//
// Functionally identical to fp_mul with rm = RM_RNE (same unpack, special-case
// semantics, exact significand product, placement, rounding and
// overflow/underflow handling; y is bit-identical to fp_mul's y for the same
// operands), but with a register bank after the significand product and
// leading-one detection plus an output register, giving a documented 2-cycle
// latency:
//
//   operands present in cycle t  ->  y valid in cycle t + 2
//
// one result per cycle in steady state. a and b are sampled every cycle;
// there is no handshake.
//
// The internal cut matters when several independent MAC contexts interleave
// through the same multiplier (matrix_unit): the register-to-register path
// becomes
//
//   operands -> unpack / product / leading-one -> stage-1 register
//            -> placement / rounding / encode  -> output register
//
// instead of the full combinational fp_mul datapath. Placement depends on the
// leading-one position of the product, so both are kept on the stage-1 side of
// the cut; everything downstream of the (now registered) placed significand is
// purely rounding and encoding.
//
// Only the matrix_unit multiplier path uses this module, which always
// multiplies with roundTiesToEven and ignores the exception flags, so a/b/y is
// the whole interface (no rm/flags).

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
// Int arithmetic is deliberately mixed with sized logic; every expression is
// bounded such that the truncation/extensions are exact (same convention as
// fp_mul.sv).

module fp_mul_pipe2 #(
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
  localparam int TARGET  = S_W + 2;              // MSB position of the placed product
  localparam int FW      = S_W + 3;              // fixed-point width (sig + GRS)
  localparam int P_W     = 2 * S_W;              // exact product width
  localparam int EXP_ALL = (1 << W_EXP) - 1;     // all-ones exponent field
  // Quiet bit of a NaN payload. Sized to MANT_W: `int` arithmetic would
  // overflow for W_MANT >= 32 (e.g. binary64); for W_MANT = 0 (E8M0) the
  // NaN path is unreachable and this constant is never used.
  localparam logic [MANT_W-1:0] QUIET = (MANT_W)'(1) << (MANT_W - 1);
  // Signed versions of the exponent bounds for width-clean comparisons.
  localparam logic signed [W_EXP+4:0] EMAX_S = (W_EXP+4)'(EMAX);
  localparam logic signed [W_EXP+4:0] EMIN_S = (W_EXP+4)'(EMIN);

  // ================================================== stage 1 (combinational)
  // Unpack, special cases, exact significand product and leading-one position.

  logic              a_sign, b_sign;
  logic [W_EXP-1:0]  a_exp, b_exp;
  logic [MANT_W-1:0] a_mant, b_mant;
  assign a_sign = a[W-1];
  assign a_exp  = a[W-2 -: W_EXP];
  assign b_sign = b[W-1];
  assign b_exp  = b[W-2 -: W_EXP];
  // The mantissa field is empty for W_MANT = 0 (E8M0); the width guard keeps
  // the extraction from producing a negative index (constant condition, so the
  // dead branch is eliminated at elaboration).
  always_comb begin
    a_mant = '0;
    b_mant = '0;
    if (W_MANT > 0) begin
      a_mant = a[W_MANT-1:0];
      b_mant = b[W_MANT-1:0];
    end
  end

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

  // Special cases (6.x), specialized to RM_RNE exactly as fp_mul: NaN payloads,
  // infinity products and the zero cases. The flags are not observable here
  // (no flags output), so only y_special is computed.
  logic [W-1:0] y_special;
  logic         special_case;
  always_comb begin
    y_special    = '0;
    special_case = 1'b0;
    if (a_nan || b_nan) begin
      // 6.2.3: quiet NaN, payload of the first NaN operand.
      // Unreachable for W_MANT = 0 (E8M0 has no NaN encodings).
      y_special = {1'b0, EXP_ALL[W_EXP-1:0], (a_nan ? a_mant : b_mant) | QUIET};
      special_case = 1'b1;
    end else if (a_inf || b_inf) begin
      // Sign of an infinity product is the XOR of the operand signs (6.3).
      if (a_inf && b_inf) begin
        y_special = {a_sign ^ b_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
      end else if (a_inf) begin
        if (b_zero) begin
          // 7.2e: infinity x zero returns a quiet NaN.
          y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
        end else begin
          y_special = {a_sign ^ b_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        end
      end else begin
        if (a_zero) begin
          // 7.2e: zero x infinity returns a quiet NaN.
          y_special = {1'b0, EXP_ALL[W_EXP-1:0], QUIET};
        end else begin
          y_special = {a_sign ^ b_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
        end
      end
      special_case = 1'b1;
    end else if (a_zero || b_zero) begin
      // 6.3: a product of zeros has the XOR of the operand signs.
      y_special = {a_sign ^ b_sign, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
      special_case = 1'b1;
    end
  end

  // Significands with implicit bit (3.3). Both operands are non-zero here (the
  // zero cases are special-cased above), so the implicit bit is always set and
  // the protected implicit-bit OR form keeps the width exactly S_W.
  logic [S_W-1:0] s_a, s_b;
  assign s_a = a_sub ? {1'b0, a_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, a_mant};
  assign s_b = b_sub ? {1'b0, b_mant} : ((S_W)'(1'b1) << W_MANT) | {1'b0, b_mant};

  // Bit length of x (leading-one position + 1); 0 if x is zero.
  // Balanced leading-one encoder (same algorithm as fp_mul.sv): a one-hot
  // prefix reduction marks the highest set bit, then constant masks reduce it
  // to the integer index.
  localparam int BL_IW = $clog2(S_W + 1);  // bits needed for a value <= S_W

  function automatic int unsigned bitlen(input logic [S_W-1:0] x);
    logic [S_W-1:0]             lead;   // one-hot highest set bit
    logic [BL_IW-1:0][S_W-1:0]  vmask;  // vmask[k][i] = bit k of (i+1)
    logic [S_W-1:0]             amask;  // bits strictly above position i
    bitlen = '0;
    for (int i = 0; i < S_W; i++) begin
      amask   = ~(((S_W)'(1) << (i + 1)) - (S_W)'(1));
      lead[i] = x[i] & ~(|(x & amask));
    end
    for (int k = 0; k < BL_IW; k++)
      for (int i = 0; i < S_W; i++)
        vmask[k][i] = ((i + 1) >> k) & 1'b1;
    for (int k = 0; k < BL_IW; k++)
      bitlen[k] = |(lead & vmask[k]);
  endfunction

  // Bit length of the exact product.
  localparam int PB_IW = $clog2(P_W + 1);  // bits needed for a value <= P_W

  function automatic int unsigned pbitlen(input logic [P_W-1:0] x);
    logic [P_W-1:0]             lead;   // one-hot highest set bit
    logic [PB_IW-1:0][P_W-1:0]  vmask;  // vmask[k][i] = bit k of (i+1)
    logic [P_W-1:0]             amask;  // bits strictly above position i
    pbitlen = '0;
    for (int i = 0; i < P_W; i++) begin
      amask    = ~(((P_W)'(1) << (i + 1)) - (P_W)'(1));
      lead[i]  = x[i] & ~(|(x & amask));
    end
    for (int k = 0; k < PB_IW; k++)
      for (int i = 0; i < P_W; i++)
        vmask[k][i] = ((i + 1) >> k) & 1'b1;
    for (int k = 0; k < PB_IW; k++)
      pbitlen[k] = |(lead & vmask[k]);
  endfunction

  // Significand bit lengths (32-bit as in fp_mul: the subnormal exponent
  // adjustment needs $signed(bl_a), which a narrow vector would misread).
  // Bitlen is computed unconditionally in one place (yosys would otherwise
  // leave a don't-care anyseq on a branch that does not call it, corrupting the
  // formal model when multiple instances are elaborated).
  int bl_a, bl_b;
  always_comb begin
    bl_a = int'(bitlen(s_a));
    bl_b = int'(bitlen(s_b));
  end

  // Leading-bit exponents: value = s * 2^e (same as fp_mul).
  logic signed [W_EXP+2:0] e_a, e_b;
  always_comb begin
    e_a = (W_EXP+3)'(a_exp - BIAS);
    if (a_sub) e_a = (W_EXP+3)'((1 - BIAS) - W_MANT + $signed(bl_a) - 1);
    e_b = (W_EXP+3)'(b_exp - BIAS);
    if (b_sub) e_b = (W_EXP+3)'((1 - BIAS) - W_MANT + $signed(bl_b) - 1);
  end

  // Exact 2*S_W-bit significand product and its leading-one position; the
  // result exponent follows from the operands' bit lengths. All of this is
  // stage 1, so the stage-1 register also absorbs the reduction tree.
  logic [P_W-1:0]          P;
  logic [PB_IW-1:0]        PB;     // pbitlen(P)
  logic signed [W_EXP+3:0] e_res;
  always_comb begin
    P = (P_W)'(s_a) * (P_W)'(s_b);
    PB = PB_IW'(pbitlen(P));
    e_res = (W_EXP+4)'(e_a) + (W_EXP+4)'(e_b)
          + (W_EXP+4)'((int'(PB)) == (int'(bl_a) + int'(bl_b)));
  end

  logic rsign;  // sign of the product = XOR of the operand signs (6.3)
  assign rsign = a_sign ^ b_sign;

  // ================================================= stage 1 -> stage 2 regs
  logic [P_W-1:0]          P_q;
  logic [PB_IW-1:0]        PB_q;
  logic signed [W_EXP+3:0] e_res_q;
  logic                    rsign_q;
  logic [W-1:0]            y_special_q;
  logic                    special_case_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      P_q            <= '0;
      PB_q           <= '0;
      e_res_q        <= '0;
      rsign_q        <= 1'b0;
      y_special_q    <= '0;
      special_case_q <= 1'b0;
    end else begin
      P_q            <= P;
      PB_q           <= PB;
      e_res_q        <= e_res;
      rsign_q        <= rsign;
      y_special_q    <= y_special;
      special_case_q <= special_case;
    end
  end

  // ==================================================== stage 2 (combinational)
  // Placement, normalization, rounding (RNE) and result selection: the same
  // equations as fp_mul's main path with rm = RM_RNE.

  // Place the product: bring its MSB to bit TARGET inside the FW-bit field.
  // If P is wider than FW (always the case for two normal significands), keep
  // only the top FW bits and OR the dropped ones into norm_sticky; if P is
  // narrower (subnormal operands), left-shift it up (no bits lost).
  logic [FW-1:0] placed;
  logic          norm_sticky;
  always_comb begin
    int B_int;
    B_int = int'(PB_q);
    norm_sticky = 1'b0;
    if (B_int == 0) begin
      // Defensive: P = 0 cannot occur here (zero operands are special cases).
      placed = '0;
      norm_sticky = 1'b0;
    end else if (B_int <= FW) begin
      placed = FW'(P_q) << (FW - B_int);
      norm_sticky = 1'b0;
    end else begin
      placed = FW'(P_q >> (B_int - FW));
      // OR of the dropped low bits, as a mask reduction (no accumulation loop).
      norm_sticky = |(P_q & (((P_W)'(1) << (B_int - FW)) - 1));
    end
  end

  // ------------------------------------------- rounding, normal path (4.3).
  logic [S_W-1:0] sig;
  logic           g, r, s_bit, round_up, carry;
  /* verilator lint_off UNUSEDSIGNAL */
  // sig_rnd[S_W-1] is the implicit (leading) bit, always 1 after
  // normalization; only the W_MANT explicit bits are emitted in y_normal.
  logic [S_W-1:0] sig_rnd;
  /* verilator lint_on UNUSEDSIGNAL */
  logic signed [W_EXP+3:0] e_rnd;
  logic [W-1:0]   y_normal;
  always_comb begin
    logic [W_EXP-1:0] exp_fld;
    sig     = placed[TARGET -: S_W];
    g       = placed[2];
    r       = placed[1];
    s_bit   = placed[0] | norm_sticky;
    round_up = g & (r | s_bit) | (g & ~r & ~s_bit & sig[0]);  // RNE
    carry = round_up && (sig == {S_W{1'b1}});
    if (carry) begin
      sig_rnd = {1'b1, {W_MANT{1'b0}}};  // renormalized after the carry
      e_rnd   = e_res_q + 1;
    end else begin
      sig_rnd = sig + { {S_W-1{1'b0}}, round_up };
      e_rnd   = e_res_q;
    end
    exp_fld = e_rnd[W_EXP-1:0] + BIAS[W_EXP-1:0];
    if ($signed(e_rnd) > EMAX_S) begin
      // Overflow (7.4) under RNE: infinity.
      y_normal = {rsign_q, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
    end else begin
      y_normal = {rsign_q, exp_fld, sig_rnd[MANT_W-1:0]};
    end
  end

  // ----------------------------------------------------- rounding, subnormal
  // path (RNE). For W_MANT = 0 (E8M0) the subnormal path is unreachable (no
  // subnormal encodings exist); the generate guard also avoids a Verilator
  // 5.020 gate optimization bug that faults on this block at W_MANT = 0.
  logic [W-1:0] y_sub;
  generate
    if (W_MANT > 0) begin : g_subnormal
      always_comb begin
        // shift must be signed: when the result is normal (e_res >= EMIN) it
        // is negative, and an unsigned wrap would make the sticky loop below
        // iterate ~2^32 times.
        int signed          shift;
        logic [FW-1:0]      shifted;
        logic [S_W-1:0]     sig_s;
        logic               gs, rs, ss, up_s;
        logic [S_W-1:0]     sig_s2;
        shift = int'(EMIN - int'(e_res_q));
        if (shift > 0) shifted = placed >> shift;
        else           shifted = '0;
        sig_s  = shifted[TARGET -: S_W];
        gs     = shifted[2];
        rs     = shifted[1];
        ss     = shifted[0] | norm_sticky
               // OR of the low shift bits of placed (mask reduction; when
               // shift exceeds FW the mask is all ones, i.e. every bit sticky).
               | |(placed & (((FW)'(1) << (shift > 0 ? shift : 0)) - 1));
        up_s   = gs & (rs | ss) | (gs & ~rs & ~ss & sig_s[0]);  // RNE
        sig_s2 = sig_s + { {S_W-1{1'b0}}, up_s };
        if (sig_s2 == {1'b1, {W_MANT{1'b0}}}) begin
          // Rounded up to the smallest normal number. For a degenerate
          // exponent range (W_EXP = 1, EMIN > EMAX) the p-bit rounding can
          // overflow past the largest finite (7.4) whenever guard+round carry
          // for RNE.
          if (EMIN > EMAX && gs && rs)
            y_sub = {rsign_q, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
          else
            y_sub = {rsign_q, {W_EXP-1{1'b0}}, 1'b1, {W_MANT{1'b0}}};
        end else if (sig_s2 == '0) begin
          // Rounded to zero; keeps the sign of the exact result.
          y_sub = {rsign_q, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
        end else begin
          y_sub = {rsign_q, {W_EXP{1'b0}}, sig_s2[MANT_W-1:0]};
        end
      end
    end else begin : g_no_subnormal
      // Unreachable: no subnormal encodings exist for W_MANT = 0.
      assign y_sub = {rsign_q, {W_EXP{1'b0}}};
    end
  endgenerate

  // --------------------------------------------------------------- result
  logic [W-1:0] y_next;
  always_comb begin
    if (special_case_q) begin
      y_next = y_special_q;
    end else if ($signed(e_res_q) >= EMIN_S) begin
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
