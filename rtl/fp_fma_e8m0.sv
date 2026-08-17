// IEEE 754-2025 E8M0 (microscaling shared-exponent format) fused multiply-add.
// Format: 1 sign bit + W_EXP exponent bits and NO significand bits, so every
// finite value is an exact power of two; there are no subnormals and no NaN
// encodings. (a x b) + c = 2^(e_a+e_b) + 2^e_c, i.e. an E8M0 addition of two
// powers of two with the product exponent; the p = 1 tie and rounding rules
// are exactly those of fp_add_e8m0.
//
// Semantics (bit-exact reference: tests/reference/ops.py):
//  - Infinity: inf x 0 (either order) signals invalid (7.2e); a product of
//    infinities added to an opposite-sign infinity signals invalid (7.2d);
//    otherwise infinities pass through with the appropriate sign. E8M0 has no
//    NaN encoding, so invalid results default to +infinity.
//  - Zero: a zero product plus a zero c follows 6.3 (opposite-signed zeros
//    give +0, or -0 under roundTowardNegative); zero product + c = c.
//  - Finite x finite + c: the exact sum 2^e_max + 2^e_min rounds to a power
//    of two with the p = 1 rules of fp_add_e8m0 (RNE/RNA ties to the larger
//    magnitude; RP/RM by sign). Overflow (7.4) saturates per attribute.
//
// This module exists because the generic fp_fma datapath cannot be elaborated
// by Verilator 5.020 at W_MANT = 0 (gate-optimizer internal fault), mirroring
// the E8M0 split already used for the other operations.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
// Int arithmetic is deliberately mixed with sized logic; every expression is
// bounded such that the truncation/extensions are exact.

module fp_fma_e8m0 #(
  parameter int W_EXP = 8
) (
  input  logic [W_EXP:0]    a,
  input  logic [W_EXP:0]    b,
  input  logic [W_EXP:0]    c,
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
  logic              a_sign, b_sign, c_sign;
  logic [W_EXP-1:0]  a_exp, b_exp, c_exp;
  assign a_sign = a[W_EXP];
  assign a_exp  = a[W_EXP-1:0];
  assign b_sign = b[W_EXP];
  assign b_exp  = b[W_EXP-1:0];
  assign c_sign = c[W_EXP];
  assign c_exp  = c[W_EXP-1:0];

  logic a_inf, b_inf, c_inf, a_zero, b_zero, c_zero;
  assign a_inf  = (a_exp == EXP_ALL[W_EXP-1:0]);
  assign b_inf  = (b_exp == EXP_ALL[W_EXP-1:0]);
  assign c_inf  = (c_exp == EXP_ALL[W_EXP-1:0]);
  assign a_zero = (a_exp == '0);
  assign b_zero = (b_exp == '0);
  assign c_zero = (c_exp == '0);

  logic prod_sign;
  assign prod_sign = a_sign ^ b_sign;

  // ------------------------------------------------------- special cases
  logic [W_EXP:0] y_special;
  logic [4:0]     flags_special;
  logic           special_case;
  always_comb begin
    y_special    = '0;
    flags_special = '0;
    special_case = 1'b0;
    if ((a_inf && b_zero) || (a_zero && b_inf)) begin
      // 7.2e: infinity x zero. E8M0 has no NaN encoding; +infinity is the
      // documented default result.
      y_special = {1'b0, EXP_ALL[W_EXP-1:0]};
      flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
      special_case = 1'b1;
    end else if (a_inf || b_inf) begin
      // Product is an infinity of sign prod_sign.
      if (c_inf && (c_sign != prod_sign)) begin
        // 7.2d: magnitude subtraction of infinities (inf + -inf).
        y_special = {1'b0, EXP_ALL[W_EXP-1:0]};
        flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
      end else begin
        y_special = {prod_sign, EXP_ALL[W_EXP-1:0]};
      end
      special_case = 1'b1;
    end else if (c_inf) begin
      // Finite product + infinity.
      y_special = {c_sign, EXP_ALL[W_EXP-1:0]};
      special_case = 1'b1;
    end else if (a_zero || b_zero) begin
      // Product is a zero of sign prod_sign.
      if (c_zero) begin
        // 6.3: like-sign zero sums keep that sign; opposite-sign zero sums
        // are +0, or -0 under roundTowardNegative.
        y_special = {(prod_sign == c_sign) ? prod_sign : (rm == fp_pkg::RM_RM),
                     {W_EXP{1'b0}}};
      end else begin
        y_special = c;  // 0 + c = c
      end
      special_case = 1'b1;
    end
  end

  // ----------------------------------------------------- finite datapath
  // Unbiased exponents; the product is exactly 2^(e_a+e_b).
  logic signed [W_EXP+2:0] e_a, e_b, e_c;
  logic signed [W_EXP+3:0] e_ab;
  assign e_a  = (W_EXP+3)'(a_exp - BIAS);
  assign e_b  = (W_EXP+3)'(b_exp - BIAS);
  assign e_c  = (W_EXP+3)'(c_exp - BIAS);
  assign e_ab = (W_EXP+4)'(e_a) + (W_EXP+4)'(e_b);

  logic signed [W_EXP+3:0] e_max;
  logic signed [W_EXP+1:0] e_min;
  assign e_max = (e_ab >= (W_EXP+4)'(e_c)) ? e_ab : (W_EXP+4)'(e_c);
  assign e_min = (e_ab >= (W_EXP+4)'(e_c)) ? (W_EXP+2)'(e_c) : (W_EXP+2)'(e_ab);

  logic d0, d1;  // exponent difference: 0, 1, >= 2
  assign d0  = (e_ab == (W_EXP+4)'(e_c));
  assign d1  = (e_ab - (W_EXP+4)'(e_c) == 1) || ((W_EXP+4)'(e_c) - e_ab == 1);

  logic same_sign;
  assign same_sign = (prod_sign == c_sign);

  // Rounding: e_lo/e_hi are the two candidate result exponents and `up`
  // selects e_hi. With p = 1 RNE ties resolve to the larger magnitude (4.3.1).
  logic [W_EXP+1:0]     e_lo, e_hi;
  logic                 up;
  logic                 inexact;
  logic                 rsign;      // sign of the magnitude result
  logic                 exact_zero; // exact cancellation (6.3)
  always_comb begin
    e_lo = '0;
    e_hi = '0;
    up   = 1'b0;
    inexact    = 1'b0;
    exact_zero = 1'b0;
    rsign      = prod_sign;
    if (c_zero) begin
      // product + 0 = product: 2^(e_a+e_b), exact (the overflow check below
      // still applies).
      e_lo = e_ab;
      e_hi = e_ab;
    end else if (same_sign) begin
      rsign = prod_sign;
      if (d0) begin
        // 2 x 2^e_max, exact
        e_lo = e_max + 1;
        e_hi = e_max + 1;
      end else if (d1) begin
        // 1.5 x 2^e_max: exact tie between 2^e_max and 2^(e_max+1).
        e_lo = e_max;
        e_hi = e_max + 1;
        up   = (rm == fp_pkg::RM_RNE) || (rm == fp_pkg::RM_RNA)
            || (rm == fp_pkg::RM_RP && ~rsign) || (rm == fp_pkg::RM_RM && rsign);
        inexact = 1'b1;
      end else begin
        e_lo = e_max;
        e_hi = e_max + 1;
        up   = (rm == fp_pkg::RM_RP && ~rsign) || (rm == fp_pkg::RM_RM && rsign);
        inexact = 1'b1;
      end
    end else begin
      // |product| - |c| (magnitude subtraction)
      if (d0) begin
        exact_zero = 1'b1;
      end else if (d1) begin
        rsign = (e_ab >= (W_EXP+4)'(e_c)) ? prod_sign : c_sign;
        e_lo = e_min;
        e_hi = e_min;
      end else begin
        rsign = (e_ab >= (W_EXP+4)'(e_c)) ? prod_sign : c_sign;
        e_lo = e_max - 1;
        e_hi = e_max;
        up   = (rm == fp_pkg::RM_RNE) || (rm == fp_pkg::RM_RNA)
            || (rm == fp_pkg::RM_RP && ~rsign) || (rm == fp_pkg::RM_RM && rsign);
        inexact = 1'b1;
      end
    end
  end

  // Overflow (7.4) and encoding of the normal result. A sum whose exact
  // magnitude is below 2^emin is tiny (products can shrink below emin even
  // though additions alone cannot): it rounds to either 0 or the smallest
  // normal number 2^emin, with p = 1 ties decided exactly (the only half-ulp
  // is an opposite-sign difference 2^e_max - 2^(e_max-1) = 2^(emin-1)).
  logic         tiny;
  logic         up_tiny;
  logic [W_EXP:0]       y_normal;
  logic [4:0]           flags_normal;
  logic [W_EXP-1:0]     exp_fld;
  logic [W_EXP+1:0]     e_rnd;
  always_comb begin
    e_rnd = up ? e_hi : e_lo;
    tiny = (same_sign && $signed(e_max) <= EMIN - 1)
        || (!same_sign && $signed(e_max) <= EMIN);
    up_tiny = (rm == fp_pkg::RM_RNE)
        ? ((same_sign && e_max == (W_EXP+4)'(EMIN - 1))
           || (!same_sign && e_max == (W_EXP+4)'(EMIN) && !d1))
        : (rm == fp_pkg::RM_RNA)
        ? ((same_sign && e_max == (W_EXP+4)'(EMIN - 1))
           || (!same_sign && e_max == (W_EXP+4)'(EMIN)))
        : (rm == fp_pkg::RM_RZ)
        ? 1'b0
        : (rm == fp_pkg::RM_RP)
        ? ~rsign
        : rsign;
    y_normal    = '0;
    flags_normal = 5'd0;
    exp_fld     = '0;
    if ($signed(e_rnd) > EMAX) begin
      // Overflow: the exact sum exceeds the largest finite number; inexact is
      // always signaled (7.4).
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
    end else if (tiny) begin
      // Tiny result: round to 0 or 2^emin (always inexact; no underflow flag,
      // tininess after rounding: the rounded result is zero or the non-tiny
      // smallest normal number).
      if (up_tiny) y_normal = {rsign, {W_EXP-1{1'b0}}, 1'b1};
      else         y_normal = {rsign, {W_EXP{1'b0}}};
      flags_normal = (1 << fp_pkg::FLAG_INEXACT);
    end else begin
      exp_fld = e_rnd[W_EXP-1:0] + BIAS[W_EXP-1:0];
      y_normal = {rsign, exp_fld};
      flags_normal = inexact ? (1 << fp_pkg::FLAG_INEXACT) : 5'd0;
    end
  end

  // --------------------------------------------------------------- result
  always_comb begin
    if (special_case) begin
      y     = y_special;
      flags = flags_special;
    end else if (exact_zero) begin
      // 6.3: exact zero sum of opposite-sign addends: +0, or -0 under RM.
      y     = {(rm == fp_pkg::RM_RM), {W_EXP{1'b0}}};
      flags = 5'd0;
    end else begin
      y     = y_normal;
      flags = flags_normal;
    end
  end

endmodule
