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
    OP_TOTALORDER = 4'd10, // totalOrder predicate (5.10): cmp[0] = a precedes-or-equals b
    // Non-rounding ops; the rm field selects the variant (see fp_misc_pipe).
    OP_SGNJ       = 4'd11, // copy / negate / abs / copySign (5.5.1), rm = 0..3
    OP_CLASS      = 4'd12, // class (5.7.2): y = class index 0..9
    OP_NEXT       = 4'd13, // nextUp (rm != 1) / nextDown (rm == 1) (5.3.1)
    OP_MINMAXNUM  = 4'd14, // minimumNumber / maximumNumber / ...Magnitude... (9.6), rm = 0..3
    OP_RNDINTX    = 4'd15  // roundToIntegralExact (5.3.1, 5.9): like OP_RNDINT + inexact
  } op_t;

  // Opcodes with a defined operation (everything else is reserved: fp_unit
  // returns y = 0 with the invalid flag). All 16 4-bit codes are defined;
  // the function remains the single place to change if op_t is widened.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic bit op_defined(input op_t op);
    op_defined = 1'b1;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

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

  // (Functions assign their name instead of using `return`: yosys 0.68,
  // used by the formal flow, does not parse `return`.)
  // ------------------------------------------------------------------
  // Pipeline latencies (cycles from an accepted request to out_valid) of the
  // generic-format (W_MANT > 0) datapaths. fp_unit uses these to schedule the
  // shared result port; they must match the pipeline structure exactly (the
  // fp_unit simulation assertion `out_valid == resv[0]` and tests/latency.py
  // check this).
  /* verilator lint_off UNUSEDPARAM */
  localparam int LAT_ADD    = 3;  // fp_add_pipe
  localparam int LAT_RNDINT = 2;  // fp_roundint_pipe
  /* verilator lint_on UNUSEDPARAM */

  // fp_mul_core uses 2 reduction stages when the significand width
  // W_MANT+1 <= 32, else 3.
  function automatic int lat_mul(input int w_mant);
    lat_mul = (w_mant + 1 <= 32) ? 4 : 5;
  endfunction

  function automatic int lat_fma(input int w_mant);
    lat_fma = (w_mant + 1 <= 32) ? 7 : 8;
  endfunction

  // fp_div_srt: NSTG + 2 + fold_stg with NSTG = ceil(NDIG / dps).
  function automatic int lat_div_srt(input int w_mant, input int dps,
                                     input int fold_stg);
    int s_w, target, ndig;
    s_w    = w_mant + 1;
    target = s_w + 2;
    ndig   = (target % 2 == 0) ? (target / 2 + 1) : ((target + 1) / 2 + 1);
    lat_div_srt = (ndig + dps - 1) / dps + 2 + fold_stg;
  endfunction

  // fp_sqrt_srt: NSTG + 2 + fold_stg with NDIG = (R_W + PAD - 4) / 4.
  function automatic int lat_sqrt_srt(input int w_mant, input int dps,
                                      input int fold_stg);
    int s_w, re, ndig;
    s_w  = w_mant + 1;
    re   = 2 * s_w + 6 + ((s_w % 2 == 0) ? 2 : 0);
    ndig = (re - 4) / 4;
    lat_sqrt_srt = (ndig + dps - 1) / dps + 2 + fold_stg;
  endfunction

  // fp_divsqrt_iter: K + 3 with K = floor((W_MANT+3)/2) (one op at a time).
  function automatic int lat_divsqrt_iter(input int w_mant);
    lat_divsqrt_iter = (w_mant + 3) / 2 + 3;
  endfunction

  function automatic int max_int(input int x, input int y);
    max_int = (x > y) ? x : y;
  endfunction

endpackage
