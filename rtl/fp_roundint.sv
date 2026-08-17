// IEEE 754-2019 roundToIntegral (5.9).
//
// Combinational, parameterized by the format: W_EXP exponent bits and W_MANT
// fraction bits (3.3, 3.7 "extendable precision"). W_MANT > 0 only (the
// W_MANT = 0 case is a dedicated E8M0 module; see fp_unit.sv). Rounds the
// operand to an integral value per the rounding-direction attribute (4.3).
//
// Semantics (bit-exact reference: tests/reference/ops.py):
//   * NaN: the operand itself quieted -- the sign and payload are preserved
//     and the quiet bit is forced (5.9: "that quiet NaN" / "the corresponding
//     quiet NaN"); a signaling NaN signals invalid (7.2a). This differs from
//     the arithmetic ops, whose NaN result has sign 0 (6.2.3 first-NaN
//     payload convention).
//   * Infinity and zero: returned unchanged, including the sign of zero.
//   * Finite values: rounded to an integral value. roundToIntegral does NOT
//     signal inexact (only roundToIntegralExact does). A fractional value
//     that rounds to zero takes the sign of x (e.g. -0.4 under RNE -> -0).
//   * Overflow (7.4): for conforming formats (emax >= p-1) the correctly
//     rounded integral value is always representable, so this never fires.
//     For the degenerate emax < p-1 corner (e.g. the exhaustive (1,6)/(2,5)/
//     (3,4) formats) the rounded integer can exceed the largest finite; that
//     is handled per 7.4 (RNE/RNA -> infinity, RZ -> largest finite, RP/RM by
//     sign, with overflow and inexact), mirroring round_to_format.
//
// Datapath: unpack -> specials -> value = M * 2^e0 with M the p-bit
// significand -> if e0 >= 0 the value is already integral (return unchanged)
// -> otherwise extract integer part + guard/round/sticky at the binary point,
// round per attribute, and re-encode the rounded integer.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off SELRANGE */
// Int arithmetic is deliberately mixed with sized logic; every expression is
// bounded such that the truncation/extensions are exact. The mantissa slice
// is dead (guarded) for W_MANT = 0 but Verilator still lints the
// constant-false range.

module fp_roundint #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23
) (
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  fp_pkg::rounding_t         rm,
  output logic [1+W_EXP+W_MANT-1:0] y,
  output logic [4:0]                flags
);

  localparam int W       = 1 + W_EXP + W_MANT;   // total width
  localparam int BIAS    = (1 << (W_EXP-1)) - 1; // exponent bias (3.3)
  localparam int EMAX    = BIAS;                 // largest exponent
  localparam int EMIN    = 1 - BIAS;             // smallest normal exponent
  localparam int S_W     = W_MANT + 1;           // significand width incl. implicit bit
  localparam int MANT_W  = (W_MANT > 0) ? W_MANT : 1;  // internal mantissa width
  localparam int EXP_ALL = (1 << W_EXP) - 1;     // all-ones exponent field
  localparam int EXP_MAXF = (1 << W_EXP) - 2;    // exponent field of the largest finite
  // Quiet bit of a NaN payload (unreachable for W_MANT = 0, kept for lint).
  localparam logic [MANT_W-1:0] QUIET = (MANT_W)'(1) << (MANT_W - 1);

  // ------------------------------------------------------------- unpack (3.3)
  logic              a_sign;
  logic [W_EXP-1:0]  a_exp;
  logic [MANT_W-1:0] a_mant;
  assign a_sign = a[W-1];
  assign a_exp  = a[W-2 -: W_EXP];
  always_comb begin
    a_mant = '0;
    if (W_MANT > 0)
      a_mant = a[W_MANT-1:0];
  end

  logic a_nan, a_snan, a_inf, a_zero, a_sub;
  assign a_nan  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant != '0);
  assign a_snan = a_nan && !a_mant[MANT_W-1];
  assign a_inf  = (a_exp == EXP_ALL[W_EXP-1:0]) && (a_mant == '0);
  assign a_zero = (a_exp == '0) && (a_mant == '0);
  assign a_sub  = (a_exp == '0) && (a_mant != '0);

  // ------------------------------------------------------- special cases (5.9)
  logic [W-1:0] y_special;
  logic [4:0]   flags_special;
  logic         special_case;
  always_comb begin
    y_special    = '0;
    flags_special = '0;
    special_case = 1'b0;
    if (a_nan) begin
      // 5.9: quiet NaN with the sign and payload of x; 7.2a: sNaN -> invalid.
      // Unreachable for W_MANT = 0 (E8M0 has no NaN encodings).
      y_special = {a_sign, EXP_ALL[W_EXP-1:0], a_mant | QUIET};
      flags_special[fp_pkg::FLAG_INVALID] = a_snan;
      special_case = 1'b1;
    end else if (a_inf || a_zero) begin
      y_special = a;  // infinity or zero returned unchanged (sign preserved)
      special_case = 1'b1;
    end
  end

  // -------------------------------------------------- finite datapath
  // value = M * 2^e0. For normals M = {1'b1, mant} and e0 = e - W_MANT
  // (e = unbiased exponent); for subnormals M = {1'b0, mant} and e0 = EMIN -
  // W_MANT. The binary point of the integral rounding sits between bit e0 and
  // bit e0-1 of M: the value is already integral iff e0 >= 0.
  logic [S_W-1:0]      M;
  logic signed [W_EXP+3:0] e0;
  always_comb begin
    if (a_sub) begin
      M  = {1'b0, a_mant};
      e0 = (W_EXP+4)'(EMIN - W_MANT);
    end else begin
      M  = ((S_W)'(1'b1) << W_MANT) | {1'b0, a_mant};
      e0 = (W_EXP+4)'(a_exp - BIAS - W_MANT);
    end
  end

  logic [W-1:0] y_fin;
  logic [4:0]   flags_fin;
  always_comb begin
    int             k;
    logic [S_W-1:0] int_part;
    logic           g, r, s_bit, inexact, up;
    int             ey;
    y_fin    = '0;
    flags_fin = 5'd0;
    k        = 0;
    int_part = '0;
    g        = 1'b0;
    r        = 1'b0;
    s_bit    = 1'b0;
    inexact  = 1'b0;
    up       = 1'b0;
    ey       = 0;
    if ($signed(e0) < 0) begin
      // Round M * 2^e0 (k = -e0 fractional bits below the binary point).
      k = int'(-e0);
      int_part = '0;
      g = 1'b0;
      r = 1'b0;
      s_bit = 1'b0;
      if (k > S_W) begin
        // All significand bits lie strictly below the halfway point: the
        // integer part is 0, guard/round are 0, everything is sticky.
        s_bit = |M;
      end else begin
        int_part = M >> k;
        g = M[k-1];
        if (k >= 2) r = M[k-2];
        // OR of the low (k-2) bits of M, as a mask reduction (no accumulation
        // loop: yosys's proc turns `|=` self-reference into spurious anyseqs).
        s_bit = |(M & (((S_W)'(1) << (k >= 3 ? k - 2 : 0)) - 1));
      end
      inexact = g | r | s_bit;
      case (rm)
        fp_pkg::RM_RNE: up = g & (r | s_bit) | (g & ~r & ~s_bit & int_part[0]);
        fp_pkg::RM_RNA: up = g;
        fp_pkg::RM_RZ:  up = 1'b0;
        fp_pkg::RM_RP:  up = ~a_sign & inexact;
        fp_pkg::RM_RM:  up = a_sign & inexact;
        default:        up = 1'b0;
      endcase
      int_part = int_part + { {S_W-1{1'b0}}, up };  // rounded integer magnitude
      if (int_part == '0) begin
        // Rounded to zero; keeps the sign of x (5.9).
        y_fin = {a_sign, {W_EXP{1'b0}}, {W_MANT{1'b0}}};
      end else begin
        // Leading exponent ey of the rounded integer (<= W_MANT here, since
        // int_part <= 2^W_MANT; int_part[W_MANT] is the carry-out position).
        // The last set bit index wins, i.e. the highest set bit (no break:
        // yosys does not support `break` in for loops).
        ey = 0;
        for (int i = 0; i < S_W; i++)
          if (int_part[i]) ey = i;
        if (ey > EMAX) begin
          // Overflow (7.4): only the degenerate emax < p-1 corner (the rounded
          // integer 2^(EMAX+1) exceeds the largest finite).
          case (rm)
            fp_pkg::RM_RNE,
            fp_pkg::RM_RNA: y_fin = {a_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
            fp_pkg::RM_RZ:  y_fin = {a_sign, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
            fp_pkg::RM_RP:  y_fin = a_sign ? {1'b1, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}}
                                           : {1'b0, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
            fp_pkg::RM_RM:  y_fin = a_sign ? {1'b1, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}}
                                           : {1'b0, EXP_MAXF[W_EXP-1:0], {W_MANT{1'b1}}};
            default:        y_fin = {a_sign, EXP_ALL[W_EXP-1:0], {W_MANT{1'b0}}};
          endcase
          flags_fin = (1 << fp_pkg::FLAG_OVERFLOW) | (1 << fp_pkg::FLAG_INEXACT);
        end else if (ey >= EMIN) begin
          // Normal encoding: value = (2^W_MANT | mant) * 2^(ey-W_MANT), so the
          // fraction below the implicit bit is (int_part - 2^ey) left-shifted
          // by (W_MANT - ey) (ey <= W_MANT always: int_part <= 2^W_MANT).
          y_fin = {a_sign, (W_EXP)'(ey + BIAS),
                   (W_MANT)'((int_part - ((S_W)'(1) << ey)) << (W_MANT - ey))};
        end else begin
          // Subnormal encoding (non-conforming corner only): value = m * 2^(EMIN-W_MANT).
          y_fin = {a_sign, {W_EXP{1'b0}},
                   (W_MANT)'(int_part) << (W_MANT - EMIN)};
        end
      end
    end
  end

  // --------------------------------------------------------------- result
  always_comb begin
    if (special_case) begin
      y     = y_special;
      flags = flags_special;
    end else if ($signed(e0) >= 0) begin
      y     = a;  // already integral: returned unchanged
      flags = 5'd0;
    end else begin
      y     = y_fin;
      flags = flags_fin;
    end
  end

endmodule
