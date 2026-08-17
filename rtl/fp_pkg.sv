// IEEE 754-2019 floating-point helper definitions.
//
// Types and constants shared by the datapath modules. The bit positions of
// the exception flags and the enum values must stay in sync with
// tests/reference/formats.py (bit-exact oracle).

package fp_pkg;

  // Rounding-direction attributes (clause 4.3).
  typedef enum logic [2:0] {
    RM_RNE = 3'd0,  // roundTiesToEven (4.3.1)
    RM_RNA = 3'd1,  // roundTiesToAway (4.3.1)
    RM_RZ  = 3'd2,  // roundTowardZero (4.3.2)
    RM_RP  = 3'd3,  // roundTowardPositive (4.3.2)
    RM_RM  = 3'd4   // roundTowardNegative (4.3.2)
  } rounding_t;

  // Operations (clause 5.4.1; comparisons 5.11; totalOrder 5.10; roundToIntegral
  // 5.9). OP_SUB is OP_ADD with the second operand's effective sign flipped;
  // the compare/totalOrder ops drive the 2-bit `cmp` output of the unit, and
  // OP_RNDINT returns an integral value in the result field.
  typedef enum logic [3:0] {
    OP_ADD        = 4'd0,  // addition
    OP_SUB        = 4'd1,  // subtraction
    OP_MUL        = 4'd2,  // multiplication
    OP_DIV        = 4'd3,  // division
    OP_SQRT       = 4'd4,  // square root
    OP_FMA        = 4'd5,  // fused multiply-add (5.4.1)
    OP_MIN        = 4'd6,  // minimum (5.6.1)
    OP_MAX        = 4'd7,  // maximum (5.6.1)
    OP_CMP        = 4'd8,  // quiet comparison (5.11): 2-bit condition code in cmp
    OP_RNDINT     = 4'd9,  // roundToIntegral (5.9)
    OP_TOTALORDER = 4'd10  // totalOrder predicate (5.10): cmp[0] = a precedes-or-equals b
  } op_t;

  // Comparison condition codes (clause 5.11), encoding of the 2-bit cmp output.
  // Mirrored in tests/reference/formats.py. OP_TOTALORDER uses cmp[0] only
  // (a precedes-or-equals b); all other ops drive cmp = 0.
  /* verilator lint_off UNUSEDPARAM */
  localparam logic [1:0] CMP_LT = 2'd0;  // a < b
  localparam logic [1:0] CMP_EQ = 2'd1;  // a == b
  localparam logic [1:0] CMP_GT = 2'd2;  // a > b
  localparam logic [1:0] CMP_UN = 2'd3;  // unordered (a NaN operand)
  /* verilator lint_on UNUSEDPARAM */

  // Exception flags (clause 7), bit positions of the 5-bit flags output.
  // These are the package's public flag API (mirrored in
  // tests/reference/formats.py). Each op uses a subset, so Verilator flags
  // unused constants per instance; that is expected and not a defect.
  /* verilator lint_off UNUSEDPARAM */
  localparam int FLAG_INVALID   = 4;  // 7.2
  localparam int FLAG_DIV0      = 3;  // 7.3
  localparam int FLAG_OVERFLOW  = 2;  // 7.4
  localparam int FLAG_UNDERFLOW = 1;  // 7.5
  localparam int FLAG_INEXACT   = 0;  // 7.6
  /* verilator lint_on UNUSEDPARAM */

endpackage
