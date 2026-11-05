// Pipelined IEEE 754-2019 non-rounding operations (1 stage, format-generic).
//
// One registered stage serves four opcodes; the 3-bit `sub` input (the
// unit's rounding-mode field, which these ops do not need) selects the
// variant. Fixed latency: 1 cycle from `start` to `out_valid`. Valid for
// every format including W_MANT = 0 (E8M0: no NaN encodings, no
// subnormals), like jsm_fp_minmax_pipe.
//
//   OP_SGNJ (5.5.1 sign bit operations; never signal, NaNs untouched)
//     sub 0 copy(a)   1 negate(a)   2 abs(a)   3 copySign(a, b)   other: copy
//   OP_CLASS (5.7.2 class): y = class index, zero-extended
//     0 signalingNaN 1 quietNaN 2 negativeInfinity 3 negativeNormal
//     4 negativeSubnormal 5 negativeZero 6 positiveZero 7 positiveSubnormal
//     8 positiveNormal 9 positiveInfinity; flags 0
//   OP_NEXT (5.3.1 nextUp / nextDown)
//     sub 1 nextDown(a), any other value nextUp(a). Quiet except for a
//     signaling NaN (invalid). A NaN operand gives the unit's NaN result
//     (quiet, sign 0, payload of a). nextDown(x) = -nextUp(-x).
//   OP_MINMAXNUM (9.6)
//     sub 0 minimumNumber 1 maximumNumber 2 minimumMagnitudeNumber
//     3 maximumMagnitudeNumber, other: minimumNumber.
//     One NaN operand: the other operand is returned. Both NaN: the unit's
//     NaN result (quiet, sign 0, payload of the first NaN). Invalid iff
//     either operand is a signaling NaN. -0 < +0. The Magnitude variants
//     compare |a|, |b| and fall back to the non-magnitude rule on a tie.
//
// Semantics are bit-exact vs tests/reference/ops.py (fp_sgnj, fp_class,
// fp_next, fp_minmaxnum).

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SELRANGE */

module jsm_fp_misc_pipe #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23
) (
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
  input  jsm_fp_pkg::op_t               op,
  input  logic [2:0]                sub,
  input  logic                      clk,
  input  logic                      rst_n,
  input  logic                      start,
  output logic [1+W_EXP+W_MANT-1:0] y,
  output logic [4:0]                flags,
  output logic                      out_valid
);

  localparam int W       = 1 + W_EXP + W_MANT;
  localparam int MANT_W  = (W_MANT > 0) ? W_MANT : 1;
  localparam int EXP_ALL = (1 << W_EXP) - 1;
  localparam logic [MANT_W-1:0] QUIET = (MANT_W)'(1) << (MANT_W - 1);
  localparam logic [W-1:0] SIGN = {1'b1, {(W-1){1'b0}}};

  initial begin
    if (W < 4) $error("jsm_fp_misc_pipe: OP_CLASS needs a format width >= 4");
  end

  // ------------------------------------------------------- classification
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
  logic b_nan, b_snan, b_inf;
  assign a_nan  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant != '0);
  assign a_snan = a_nan && !a_mant[MANT_W-1];
  assign a_inf  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant == '0);
  assign a_zero = (a_exp == '0) && (a_mant == '0);
  assign a_sub  = (a_exp == '0) && (a_mant != '0);
  assign b_nan  = (b_exp == EXP_ALL[W_EXP-1:0]) && (b_mant != '0);
  assign b_snan = b_nan && !b_mant[MANT_W-1];
  assign b_inf  = (b_exp == EXP_ALL[W_EXP-1:0]) && (b_mant == '0);

  // NaN results under the unit's convention: quiet, sign 0, payload kept.
  logic [W-1:0] a_qnan, b_qnan;
  assign a_qnan = {1'b0, EXP_ALL[W_EXP-1:0], a_mant | QUIET};
  assign b_qnan = {1'b0, EXP_ALL[W_EXP-1:0], b_mant | QUIET};

  // ------------------------------------------------------------- OP_SGNJ
  logic [W-1:0] y_sgnj;
  always_comb begin
    case (sub)
      3'd1:    y_sgnj = a ^ SIGN;
      3'd2:    y_sgnj = a & ~SIGN;
      3'd3:    y_sgnj = {b_sign, a[W-2:0]};
      default: y_sgnj = a;
    endcase
  end

  // ------------------------------------------------------------ OP_CLASS
  logic [3:0] cls;
  always_comb begin
    if (a_snan)      cls = 4'd0;
    else if (a_nan)  cls = 4'd1;
    else if (a_inf)  cls = a_sign ? 4'd2 : 4'd9;
    else if (a_zero) cls = a_sign ? 4'd5 : 4'd6;
    else if (a_sub)  cls = a_sign ? 4'd4 : 4'd7;
    else             cls = a_sign ? 4'd3 : 4'd8;
  end
  logic [W-1:0] y_class;
  assign y_class = W'(cls);

  // ------------------------------------------------------------- OP_NEXT
  // nextUp on x' = a (nextUp) or -a (nextDown); the result is negated back
  // for nextDown. Positive finite: magnitude + 1 (max finite + 1 is +Inf);
  // negative finite non-zero: magnitude - 1 (-min positive - 1 = -0);
  // +-0: the least positive number (min subnormal, or 2^emin for E8M0);
  // +Inf: +Inf; -Inf: -max finite (magnitude - 1 again).
  localparam logic [W-1:0] MIN_POS = (W_MANT > 0) ? W'(1) : (W'(1) << W_MANT);
  logic         down;
  logic [W-1:0] xn, up_res, y_next;
  assign down = (sub == 3'd1);
  assign xn   = down ? (a ^ SIGN) : a;
  always_comb begin
    if ((xn[W-2:0] == '0))                       // +-0
      up_res = MIN_POS;
    else if (!xn[W-1] && a_inf)                  // +Inf
      up_res = xn;
    else if (!xn[W-1])                           // positive finite
      up_res = xn + W'(1);
    else                                         // negative, incl. -Inf
      up_res = xn - W'(1);
  end
  assign y_next = a_nan ? a_qnan : (down ? (up_res ^ SIGN) : up_res);

  // -------------------------------------------------------- OP_MINMAXNUM
  localparam logic [W_EXP+W_MANT-1:0] MAG_INF = '1;
  logic [W_EXP+W_MANT-1:0] mag_a, mag_b;
  assign mag_a = a_inf ? MAG_INF : ((W_EXP+W_MANT)'(a_exp) << W_MANT) | (W_EXP+W_MANT)'(a_mant);
  assign mag_b = b_inf ? MAG_INF : ((W_EXP+W_MANT)'(b_exp) << W_MANT) | (W_EXP+W_MANT)'(b_mant);

  // Signed order with -0 < +0 (sign first, then magnitude).
  logic a_lt_b, b_lt_a;
  always_comb begin
    if (a_sign != b_sign) begin
      a_lt_b = a_sign;
      b_lt_a = b_sign;
    end else if (a_sign) begin
      a_lt_b = (mag_a > mag_b);
      b_lt_a = (mag_b > mag_a);
    end else begin
      a_lt_b = (mag_a < mag_b);
      b_lt_a = (mag_b < mag_a);
    end
  end

  logic is_max, is_mag;
  assign is_max = (sub == 3'd1) || (sub == 3'd3);
  assign is_mag = (sub == 3'd2) || (sub == 3'd3);

  logic [W-1:0] y_mmn;
  always_comb begin
    if (a_nan && b_nan)  y_mmn = a_qnan;
    else if (a_nan)      y_mmn = b;
    else if (b_nan)      y_mmn = a;
    else if (is_mag && (mag_a < mag_b)) y_mmn = is_max ? b : a;
    else if (is_mag && (mag_b < mag_a)) y_mmn = is_max ? a : b;
    else if (a_lt_b)     y_mmn = is_max ? b : a;
    else if (b_lt_a)     y_mmn = is_max ? a : b;
    else                 y_mmn = a;
  end

  // ---------------------------------------------------------- result mux
  logic [W-1:0] y_c;
  logic [4:0]   flags_c;
  always_comb begin
    y_c     = '0;
    flags_c = 5'd0;
    case (op)
      jsm_fp_pkg::OP_SGNJ:  y_c = y_sgnj;
      jsm_fp_pkg::OP_CLASS: y_c = y_class;
      jsm_fp_pkg::OP_NEXT: begin
        y_c = y_next;
        flags_c[jsm_fp_pkg::FLAG_INVALID] = a_snan;
      end
      jsm_fp_pkg::OP_MINMAXNUM: begin
        y_c = y_mmn;
        flags_c[jsm_fp_pkg::FLAG_INVALID] = a_snan || b_snan;
      end
      default: ;
    endcase
  end

  logic [W-1:0] y_s1;
  logic [4:0]   flags_s1;
  logic         v1;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      y_s1     <= '0;
      flags_s1 <= 5'd0;
      v1       <= 1'b0;
    end else begin
      y_s1     <= y_c;
      flags_s1 <= flags_c;
      v1       <= start;
    end
  end

  assign y         = y_s1;
  assign flags     = flags_s1;
  assign out_valid = v1;

endmodule
