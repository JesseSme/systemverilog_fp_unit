// IEEE 754-2025 E8M0 (microscaling shared-exponent format) division.
// Format: 1 sign bit + W_EXP exponent bits and NO significand bits, so every
// finite value is an exact power of two; there are no subnormals and no NaN
// encodings.
//
// Semantics (bit-exact reference: tests/reference/ops.py):
//  - Infinity: inf / finite = inf and finite / inf = 0, the sign being the
//    XOR of the operand signs (6.3). Magnitude division of infinities
//    (inf / inf) signals invalid (7.2f) and returns +infinity, since E8M0
//    has no NaN encoding to use as the default invalid result.
//  - Zero: 0 / finite = 0 (sign XOR); finite / 0 signals divide-by-zero
//    (7.3) and returns infinity; 0 / 0 signals invalid (7.2f).
//  - Finite / finite: 2^e_a / 2^e_b = 2^(e_a-e_b), exact, except that the
//    result may leave the format's exponent range:
//      * e_a-e_b > emax: overflow (7.4). RNE/RNA saturate to infinity, RZ to
//        the largest finite number, RP/RM by sign; inexact is always signaled.
//      * e_a-e_b < emin: the exact power of two lies below 2^emin and rounds
//        to either 0 or 2^emin. With p = 1 the only half-ulp case is the
//        exact value 2^(emin-1): RNE rounds that tie to zero (significand 0
//        is even; 2^emin would have significand 1), RNA to 2^emin, and
//        RP/RM by sign. The result is always inexact; underflow is never
//        signaled because tininess is detected after rounding and the rounded
//        result is either zero or the (non-tiny) smallest normal number.
//
// This module exists because the generic fp_div datapath cannot be elaborated
// by Verilator 5.020 at W_MANT = 0 (gate-optimizer internal fault), mirroring
// the E8M0 split already used for addition and multiplication.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
// Int arithmetic is deliberately mixed with sized logic; every expression is
// bounded such that the truncation/extensions are exact.

module fp_div_e8m0 #(
  parameter int W_EXP = 8
) (
  input  logic [W_EXP:0]    a,
  input  logic [W_EXP:0]    b,
  input  fp_pkg::rounding_t rm,
  output logic [W_EXP:0]    y,
  output logic [4:0]        flags
);

  localparam int BIAS     = (1 << (W_EXP-1)) - 1;  // exponent bias
  localparam int EMAX     = BIAS;                  // largest exponent
  localparam int EMIN     = 1 - BIAS;              // smallest normal exponent
  localparam int EXP_ALL  = (1 << W_EXP) - 1;      // all-ones exponent field
  localparam int EXP_MAXF = (1 << W_EXP) - 2;      // exponent field of the largest finite

  // ------------------------------------------------------------- unpack
  logic              a_sign, b_sign;
  logic [W_EXP-1:0]  a_exp, b_exp;
  assign a_sign = a[W_EXP];
  assign a_exp  = a[W_EXP-1:0];
  assign b_sign = b[W_EXP];
  assign b_exp  = b[W_EXP-1:0];

  logic a_inf, b_inf, a_zero, b_zero;
  assign a_inf  = (a_exp == EXP_ALL[W_EXP-1:0]);
  assign b_inf  = (b_exp == EXP_ALL[W_EXP-1:0]);
  assign a_zero = (a_exp == '0);
  assign b_zero = (b_exp == '0);

  // ------------------------------------------------------- special cases
  logic [W_EXP:0] y_special;
  logic [4:0]     flags_special;
  logic           special_case;
  always_comb begin
    y_special    = '0;
    flags_special = '0;
    special_case = 1'b0;
    if (a_inf || b_inf) begin
      if (a_inf && b_inf) begin
        // 7.2f: magnitude division of infinities. E8M0 has no NaN encoding;
        // +infinity is the documented default result.
        y_special = {1'b0, EXP_ALL[W_EXP-1:0]};
        flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
      end else if (a_inf) begin
        // inf / finite = inf; sign XOR (6.3).
        y_special = {a_sign ^ b_sign, EXP_ALL[W_EXP-1:0]};
      end else begin
        // finite / inf = 0; sign XOR (6.3).
        y_special = {a_sign ^ b_sign, {W_EXP{1'b0}}};
      end
      special_case = 1'b1;
    end else if (a_zero || b_zero) begin
      if (a_zero && b_zero) begin
        // 7.2f: division of zero by zero. E8M0 has no NaN encoding.
        y_special = {1'b0, EXP_ALL[W_EXP-1:0]};
        flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
      end else if (a_zero) begin
        // 0 / finite = 0; sign XOR (6.3).
        y_special = {a_sign ^ b_sign, {W_EXP{1'b0}}};
      end else begin
        // finite / 0 = inf (7.3 divide-by-zero); sign XOR (6.3).
        y_special = {a_sign ^ b_sign, EXP_ALL[W_EXP-1:0]};
        flags_special[fp_pkg::FLAG_DIV0] = 1'b1;
      end
      special_case = 1'b1;
    end
  end

  // ----------------------------------------------------- finite datapath
  // Unbiased exponents (all finite values are exactly 2^e).
  logic signed [W_EXP+1:0] e_a, e_b;
  logic signed [W_EXP+1:0] e_res;
  assign e_a  = (W_EXP+2)'(a_exp - BIAS);
  assign e_b  = (W_EXP+2)'(b_exp - BIAS);
  assign e_res = e_a - e_b;

  logic rsign;  // sign of the quotient = XOR of the operand signs (6.3)
  assign rsign = a_sign ^ b_sign;

  // Overflow (7.4), tiny-rounding, and encoding of the normal result.
  logic [W_EXP:0]   y_normal;
  logic [4:0]       flags_normal;
  logic [W_EXP-1:0] exp_fld;
  always_comb begin
    logic up;
    y_normal    = '0;
    flags_normal = 5'd0;
    exp_fld     = '0;
    up          = 1'b0;
    if ($signed(e_res) > EMAX) begin
      // Overflow: the exact quotient 2^e_res exceeds the largest finite
      // number; inexact is always signaled (7.4).
      case (rm)
        fp_pkg::RM_RNE,
        fp_pkg::RM_RNA: y_normal = {rsign, EXP_ALL[W_EXP-1:0]};
        fp_pkg::RM_RZ:  y_normal = {rsign, EXP_MAXF[W_EXP-1:0]};
        fp_pkg::RM_RP:  y_normal = rsign ? {1'b1, EXP_MAXF[W_EXP-1:0]}
                                        : {1'b0, EXP_ALL[W_EXP-1:0]};
        fp_pkg::RM_RM:  y_normal = rsign ? {1'b1, EXP_ALL[W_EXP-1:0]}
                                        : {1'b0, EXP_MAXF[W_EXP-1:0]};
        default:        y_normal = {rsign, EXP_ALL[W_EXP-1:0]};
      endcase
      flags_normal = (1 << fp_pkg::FLAG_OVERFLOW) | (1 << fp_pkg::FLAG_INEXACT);
    end else if ($signed(e_res) < EMIN) begin
      // Tiny result: the exact value 2^e_res (e_res < emin) rounds to either
      // 0 or the smallest normal number 2^emin. With p = 1 the only tie is
      // the exact value 2^(emin-1) (half of 2^emin): RNE resolves it to zero
      // (significand 0 is even), RNA away to 2^emin, and RP/RM by sign.
      // Always inexact; underflow is never signaled (tininess after
      // rounding: the rounded result is zero or the smallest normal).
      up = (rm == fp_pkg::RM_RNA && e_res == (W_EXP+2)'(EMIN - 1))
        || (rm == fp_pkg::RM_RP && ~rsign)
        || (rm == fp_pkg::RM_RM && rsign);
      if (up) y_normal = {rsign, {W_EXP-1{1'b0}}, 1'b1};  // 2^emin
      else    y_normal = {rsign, {W_EXP{1'b0}}};          // +-0
      flags_normal = (1 << fp_pkg::FLAG_INEXACT);
    end else begin
      // Normal exact result: 2^e_res.
      exp_fld = e_res[W_EXP-1:0] + BIAS[W_EXP-1:0];
      y_normal = {rsign, exp_fld};
    end
  end

  // --------------------------------------------------------------- result
  always_comb begin
    if (special_case) begin
      y     = y_special;
      flags = flags_special;
    end else begin
      y     = y_normal;
      flags = flags_normal;
    end
  end

endmodule
