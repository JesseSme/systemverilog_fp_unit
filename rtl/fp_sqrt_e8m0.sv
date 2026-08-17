// IEEE 754-2025 E8M0 (microscaling shared-exponent format) square root.
// Format: 1 sign bit + W_EXP exponent bits and NO significand bits, so every
// finite value is an exact power of two; there are no subnormals and no NaN
// encodings.
//
// Semantics (bit-exact reference: tests/reference/ops.py):
//  - Infinity: sqrt(+inf) = +inf; sqrt(-inf) signals invalid (7.2g) and
//    returns +infinity, since E8M0 has no NaN encoding to use as the default
//    invalid result.
//  - Zero: sqrt(+-0) = +-0 (6.3).
//  - Negative numbers signal invalid (7.2g) and return +infinity.
//  - Finite positive 2^e:
//      * e even: sqrt(2^e) = 2^(e/2), exact.
//      * e odd:  sqrt(2^e) = 2^((e-1)/2) * sqrt(2), and sqrt(2) ~ 1.414 < 1.5
//        is nearer to 2^((e-1)/2) than to 2^((e+1)/2), so RNE/RNA/RZ/RM round
//        down to 2^((e-1)/2) and RP (positive result) rounds up to
//        2^((e+1)/2). Always inexact.
//  - The result is always within the normal exponent range (no overflow, no
//    underflow): e/2 and (e-1)/2 stay in [emin, emax] for e in [emin, emax].
//
// This module exists because the generic fp_sqrt datapath cannot be
// elaborated by Verilator 5.020 at W_MANT = 0 (gate-optimizer internal
// fault), mirroring the E8M0 split already used for the other operations.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
// Int arithmetic is deliberately mixed with sized logic; every expression is
// bounded such that the truncation/extensions are exact.

module fp_sqrt_e8m0 #(
  parameter int W_EXP = 8
) (
  input  logic [W_EXP:0]    a,
  input  fp_pkg::rounding_t rm,
  output logic [W_EXP:0]    y,
  output logic [4:0]        flags
);

  localparam int BIAS     = (1 << (W_EXP-1)) - 1;  // exponent bias
  localparam int EXP_ALL  = (1 << W_EXP) - 1;      // all-ones exponent field

  // ------------------------------------------------------------- unpack
  logic              a_sign;
  logic [W_EXP-1:0]  a_exp;
  assign a_sign = a[W_EXP];
  assign a_exp  = a[W_EXP-1:0];

  logic a_inf, a_zero;
  assign a_inf  = (a_exp == EXP_ALL[W_EXP-1:0]);
  assign a_zero = (a_exp == '0);

  // ------------------------------------------------------- special cases
  logic [W_EXP:0] y_special;
  logic [4:0]     flags_special;
  logic           special_case;
  always_comb begin
    y_special    = '0;
    flags_special = '0;
    special_case = 1'b0;
    if (a_inf) begin
      if (a_sign) begin
        // 7.2g: sqrt of negative infinity. E8M0 has no NaN encoding;
        // +infinity is the documented default result.
        y_special = {1'b0, EXP_ALL[W_EXP-1:0]};
        flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
      end else begin
        y_special = {1'b0, EXP_ALL[W_EXP-1:0]};
      end
      special_case = 1'b1;
    end else if (a_zero) begin
      // 6.3: sqrt(+-0) = +-0.
      y_special = {a_sign, {W_EXP{1'b0}}};
      special_case = 1'b1;
    end else if (a_sign) begin
      // 7.2g: sqrt of a negative finite number.
      y_special = {1'b0, EXP_ALL[W_EXP-1:0]};
      flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
      special_case = 1'b1;
    end
  end

  // ----------------------------------------------------- finite datapath
  // Unbiased exponent (all finite values are exactly 2^e).
  logic signed [W_EXP+1:0] e;
  assign e = (W_EXP+2)'(a_exp - BIAS);

  // Result exponent 2^e_res = 2^(e/2): even e is exact; odd e rounds down to
  // 2^((e-1)/2) for RNE/RNA/RZ/RM and up to 2^((e+1)/2) for RP.
  logic [W_EXP:0]   y_normal;
  logic [4:0]       flags_normal;
  logic [W_EXP-1:0] exp_fld;
  always_comb begin
    logic signed [W_EXP+1:0] e_rnd;
    /* verilator lint_off UNUSEDSIGNAL */
    // e_half's top bits (above W_EXP-1) are never read: only the W_EXP-bit
    // exponent field is consumed via exp_fld.
    logic signed [W_EXP+1:0] e_half;
    /* verilator lint_on UNUSEDSIGNAL */
    y_normal    = '0;
    flags_normal = 5'd0;
    e_rnd  = '0;
    e_half = '0;
    if (e[0]) begin
      // Odd exponent: round up only for RP (rsign is always 0).
      e_rnd  = (rm == fp_pkg::RM_RP) ? (e + 1) : (e - 1);
      e_half = e_rnd >>> 1;
      exp_fld = e_half[W_EXP-1:0] + BIAS[W_EXP-1:0];
      y_normal = {1'b0, exp_fld};
      flags_normal = (1 << fp_pkg::FLAG_INEXACT);
    end else begin
      e_half = e >>> 1;
      exp_fld = e_half[W_EXP-1:0] + BIAS[W_EXP-1:0];
      y_normal = {1'b0, exp_fld};
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
