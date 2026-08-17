// IEEE 754-2025 E8M0 (microscaling shared-exponent format) addition/subtraction.
// Format: 1 sign bit + W_EXP exponent bits and NO significand bits, so every
// finite value is an exact power of two; there are no subnormals and no NaN
// encodings.
//
// Semantics (bit-exact reference: tests/reference/ops.py):
//  - Infinity: like-sign infinities sum to infinity; magnitude subtraction of
//    infinities signals invalid (7.2d) and returns +infinity, since E8M0 has
//    no NaN encoding to use as the default invalid result.
//  - Zero: x + 0 = x exactly. An exact zero sum of like-sign addends keeps
//    that sign; of opposite-sign addends it is +0, or -0 under
//    roundTowardNegative (6.3).
//  - Finite + finite: the exact result (a sum or difference of two powers of
//    two) rounds to the nearest power of two. With p = 1 both tie candidates
//    have the significand 1.0, which is odd, so per 4.3.1 roundTiesToEven
//    delivers the larger magnitude on ties.
//  - Overflow (7.4): flagged iff the unbounded-range rounded result exceeds
//    2^emax; RNE/RNA saturate to infinity, RZ to the largest finite number,
//    RP/RM by sign; inexact is always signaled.
//  - Underflow and inexact: underflow can never occur (no subnormals);
//    inexact is signaled whenever the exact result is not a power of two.
//
// This module exists because the generic fp_add datapath cannot be elaborated
// by Verilator 5.020 at W_MANT = 0 (gate-optimizer internal fault), and the
// p = 1 tie rules deserve an explicit implementation.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
// Int arithmetic is deliberately mixed with sized logic; every expression is
// bounded such that the truncation/extensions are exact.

module fp_add_e8m0 #(
  parameter int W_EXP = 8
) (
  input  logic [W_EXP:0]    a,
  input  logic [W_EXP:0]    b,
  input  fp_pkg::rounding_t rm,
  input  fp_pkg::op_t       op,
  output logic [W_EXP:0]    y,
  output logic [4:0]        flags
);

  localparam int BIAS     = (1 << (W_EXP-1)) - 1;  // exponent bias
  localparam int EMAX     = BIAS;                  // largest exponent
  localparam int EXP_ALL  = (1 << W_EXP) - 1;      // all-ones exponent field
  localparam int EXP_MAXF = (1 << W_EXP) - 2;      // exponent field of the largest finite

  // ------------------------------------------------------------- unpack
  logic              a_sign, b_sign, b_sign_eff;
  logic [W_EXP-1:0]  a_exp, b_exp;
  assign a_sign = a[W_EXP];
  assign a_exp  = a[W_EXP-1:0];
  assign b_sign = b[W_EXP];
  assign b_exp  = b[W_EXP-1:0];
  assign b_sign_eff = b_sign ^ (op == fp_pkg::OP_SUB);

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
        if (a_sign == b_sign_eff)
          y_special = {a_sign, EXP_ALL[W_EXP-1:0]};
        else begin
          // 7.2d: magnitude subtraction of infinities. E8M0 has no NaN
          // encoding; +infinity is the documented default result.
          y_special = {1'b0, EXP_ALL[W_EXP-1:0]};
          flags_special[fp_pkg::FLAG_INVALID] = 1'b1;
        end
      end else if (a_inf) begin
        y_special = {a_sign, EXP_ALL[W_EXP-1:0]};
      end else begin
        y_special = {b_sign_eff, EXP_ALL[W_EXP-1:0]};
      end
      special_case = 1'b1;
    end else if (a_zero && b_zero) begin
      // 6.3: like-sign zero sums keep that sign; opposite-sign zero sums are
      // +0, or -0 under roundTowardNegative.
      y_special = {(a_sign == b_sign_eff) ? a_sign : (rm == fp_pkg::RM_RM),
                   {W_EXP{1'b0}}};
      special_case = 1'b1;
    end else if (a_zero) begin
      y_special = {b_sign_eff, b_exp};  // 0 + b = b, 0 - b = -b
      special_case = 1'b1;
    end else if (b_zero) begin
      y_special = a;                    // a + 0 = a, a - 0 = a
      special_case = 1'b1;
    end
  end

  // ----------------------------------------------------- finite datapath
  // Unbiased exponents (all finite values are exactly 2^e).
  logic signed [W_EXP+2:0] e_a, e_b;
  logic signed [W_EXP+2:0] e_max;
  /* verilator lint_off UNUSEDSIGNAL */
  // e_min's MSB (sign extension above W_EXP+1 bits) is never read: it is only
  // consumed via e_lo/e_hi, which are W_EXP+1 bits wide.
  logic signed [W_EXP+2:0] e_min;
  /* verilator lint_on UNUSEDSIGNAL */
  assign e_a = (W_EXP+3)'(a_exp - BIAS);
  assign e_b = (W_EXP+3)'(b_exp - BIAS);
  assign e_max = (e_a >= e_b) ? e_a : e_b;
  assign e_min = (e_a >= e_b) ? e_b : e_a;

  logic d0, d1;  // exponent difference: 0, 1, >= 2
  assign d0  = (e_a == e_b);
  assign d1  = (e_a - e_b == 1) || (e_b - e_a == 1);

  logic same_sign;
  assign same_sign = (a_sign == b_sign_eff);

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
    rsign      = a_sign;
    if (same_sign) begin
      // |a| + |b| = 2^e_max + 2^e_min
      rsign = a_sign;
      if (d0) begin
        // 2 x 2^e_max, exact
        e_lo = e_max + 1;
        e_hi = e_max + 1;
      end else if (d1) begin
        // 1.5 x 2^e_max: exact tie between 2^e_max and 2^(e_max+1).
        // RNE/RNA resolve ties to the larger magnitude (p = 1, 4.3.1);
        // RP/RM round by sign (toward +inf/-inf).
        e_lo = e_max;
        e_hi = e_max + 1;
        up   = (rm == fp_pkg::RM_RNE) || (rm == fp_pkg::RM_RNA)
            || (rm == fp_pkg::RM_RP && ~rsign) || (rm == fp_pkg::RM_RM && rsign);
        inexact = 1'b1;
      end else begin
        // 2^e_max + 2^e_min in (2^e_max, 1.25 x 2^e_max): nearest candidate is
        // 2^e_max; only RP (positive result) and RM (negative result) round up.
        e_lo = e_max;
        e_hi = e_max + 1;
        up   = (rm == fp_pkg::RM_RP && ~rsign) || (rm == fp_pkg::RM_RM && rsign);
        inexact = 1'b1;
      end
    end else begin
      // |a| - |b| (magnitude subtraction)
      if (d0) begin
        exact_zero = 1'b1;
      end else if (d1) begin
        // 2^e_max - 2^e_min = 2^e_min, exact; sign of the larger operand
        rsign = (e_a >= e_b) ? a_sign : b_sign_eff;
        e_lo = e_min;
        e_hi = e_min;
      end else begin
        // 2^e_max - 2^e_min: tie at d = 2, otherwise nearest to 2^e_max.
        // RNE/RNA give the larger magnitude; RP/RM round by sign.
        rsign = (e_a >= e_b) ? a_sign : b_sign_eff;
        e_lo = e_max - 1;
        e_hi = e_max;
        up   = (rm == fp_pkg::RM_RNE) || (rm == fp_pkg::RM_RNA)
            || (rm == fp_pkg::RM_RP && ~rsign) || (rm == fp_pkg::RM_RM && rsign);
        inexact = 1'b1;
      end
    end
  end

  // Overflow (7.4) and encoding of the normal result.
  logic [W_EXP+1:0]     e_rnd;
  logic [W_EXP:0]       y_normal;
  logic [4:0]           flags_normal;
  logic [W_EXP-1:0]     exp_fld;
  always_comb begin
    e_rnd = up ? e_hi : e_lo;
    exp_fld = e_rnd[W_EXP-1:0] + BIAS[W_EXP-1:0];
    if ($signed(e_rnd) > EMAX) begin
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
    end else begin
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
