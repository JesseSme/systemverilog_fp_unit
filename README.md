# IEEE 754-2019 floating-point unit (SystemVerilog) with cocotb verification

Parametrized, pipelined FPU with a fixed latency per operation and a
valid/ready request interface: `W_EXP` exponent bits and `W_MANT` fraction
bits (IEEE 754-2019 3.7 "extendable precision"; binary16/32/64 and odd sizes
are covered by the test matrix). Implements addition/subtraction,
multiplication, division, square root, fused multiply-add (5.4.1),
minimum/maximum (9.6), minimumNumber/maximumNumber and their Magnitude
variants (9.6), quiet comparison (5.11), roundToIntegral and
roundToIntegralExact (5.3.1, 5.9), totalOrder (5.10), nextUp/nextDown
(5.3.1), copy/negate/abs/copySign (5.5.1) and class (5.7.2), with all five
rounding-direction attributes (4.3), full subnormal support (3.3) and the
five exception flags (7.2-7.6, including divide-by-zero 7.3). The operation is
selected by the 4-bit `mode` input (`jsm_fp_pkg::op_t`, all 16 codes used).

**Integration guide and core reference: [docs/fp_unit_core.md](docs/fp_unit_core.md)**
(ports, handshake, opcodes, latencies, AXI register map, Vivado/block-design
use). Plain Verilog-2001 and VHDL tops of both the streaming core and the
AXI4-Lite wrapper are in `rtl/top/`, for Vivado block designs and VHDL
projects.

## Layout

    rtl/                jsm_fp_pkg.sv, jsm_fp_add.sv, jsm_fp_mul.sv, jsm_fp_div.sv, jsm_fp_sqrt.sv,
                        jsm_fp_divsqrt_iter.sv, jsm_fp_fma.sv, jsm_fp_minmax.sv, jsm_fp_cmp.sv,
                        jsm_fp_totalorder.sv, jsm_fp_roundint.sv, the *_e8m0.sv sibling
                        modules, the *_pipe.sv pipelined siblings, jsm_fp_mul_core.sv,
                        jsm_fp_div_srt.sv/jsm_fp_sqrt_srt.sv, jsm_fp_misc_pipe.sv,
                        jsm_fp_unit.sv (synthesizable SV),
                        jsm_fp_unit_axilite.sv (AXI4-Lite register wrapper),
                        jsm_fp_exp_seq.sv (fp32 exp), jsm_fp32_to_bf16_round.sv
    rtl/top/            Verilog-2001 / VHDL tops: jsm_fp_unit_top.v, jsm_fp_unit_vhd.vhd,
                        jsm_fp_unit_axilite_top.v, jsm_fp_unit_axilite_vhd.vhd, and
                        jsm_fp_unit_flat.sv (plain-vector shim over jsm_fp_unit)
    rtl/filelist.f      THE RTL file list (+ filelist_wrappers.f, filelist_vhdl.f);
                        every harness, the Makefile and syn/ read it
    docs/               fp_unit_core.md (user guide), proposals/ (design notes)
    syn/                fp_unit_timing.sv (I/O-registering OOC wrapper),
                        vivado-impl.tcl (make vivado), vivado-module.tcl,
                        vivado-top.tcl / vivado-bd-check.tcl (Verilog/VHDL tops)
    tests/reference/    bit-exact Python oracle (exact rational arithmetic)
    tests/test_fp_unit.py     cocotb tests (directed vectors + randomized)
    tests/test_fp_unit_axilite.py  cocotb AXI4-Lite register-map tests
    tests/run_regression.py   builds and runs the width matrix
    tests/exhaustive.py       exhaustive all-vectors sweep of every 8-bit format
    tests/soak.py             cross-width randomized soak (medium formats)
    tests/latency.py          per-op in_valid -> out_valid cycle-count probe
    tests/stream.py           back-to-back / mixed-op streaming test (tags)
    tests/bf16.py             jsm_fp32_to_bf16_round: all 2^32 inputs
    tests/test_fp_exp_seq.py  jsm_fp_exp_seq accuracy (cocotb)
    tests/metrics.py          area/timing proxies (yosys) + target runtimes
    tests/vivado/             xsim testbenches of the Verilog/VHDL tops (run_xsim.py)
    metrics/                  baseline/after metrics JSON (for --compare)
    formal/ + bmc_m6_*.sby    SymbiYosys formal property proofs of the M6 ops

## Running

    uv run python tests/run_regression.py            # default matrix
    uv run python tests/run_regression.py --all      # full 8-width matrix
    uv run python tests/run_regression.py --width 8 23
    FP_ITERS=200 uv run python tests/run_regression.py --width 8 23
    uv run python tests/exhaustive.py                # all 7 8-bit formats
    uv run python tests/soak.py                      # cross-width soak
    uv run python tests/exhaustive.py --iter         # DIVSQRT_IMPL=2 build
    uv run python tests/soak.py --iter               # DIVSQRT_IMPL=2 build
    make regress | make smoke | make soak | make lint
    make stream            # streaming + mixed-op test, OPS_EN subset build
    make bf16              # jsm_fp32_to_bf16_round over all 2^32 inputs
    make regress-exp       # jsm_fp_exp_seq accuracy
    make exhaustive-iter | make soak-iter | make stream-iter | make regress-axilite-iter
                           # the same on the iterative div/sqrt engine (DIVSQRT_IMPL=2)
    make check-ds3         # regression/exhaustive/soak/stream on DIVSQRT_IMPL=3
    uv run python verification/srt/run_diff.py [--param DPS=1 --param FOLD_STG=1]
                           # SRT div/sqrt modules vs combinational, streaming
    make vivado [VIVADO_ARGS="period W_EXP W_MANT DIVSQRT_IMPL"]   # OOC implementation
    make formal   # SymbiYosys BMC proofs (needs the oss-cad-suite)
    make formal-equiv      # add/mul pipelines == jsm_fp_add/jsm_fp_mul (BMC, ~15 min)
    make regress-tops      # cocotb suites through the Verilog-2001 tops
    make xsim-tops         # Verilog + VHDL tops in Vivado xsim vs the oracle
    make vivado-bd-check   # block-design module references of the tops
    make vivado-top TOP_ARGS="jsm_fp_unit_vhd 5.600 W_EXP=8 W_MANT=23"
    make metrics-area      # yosys cell count + ltp per format (baseline JSON)
    make metrics-runtime   # wall-clock of the standard targets
    make metrics-latency   # per-op in_valid -> out_valid cycle table
    make metrics-compare BEFORE=... AFTER=...

## Toolchain notes

- System Verilator is 5.020 (Debian), which requires cocotb < 2 (cocotb 2.x
  needs Verilator >= 5.036); pyproject pins `cocotb>=1.9.2,<2`.
- `tests/run_regression.py` patches cocotb 1.9.2's `verilator.cpp` on first
  run: it adds `Verilated::time(main_time)` so Verilator's internal clock
  advances; without this, every cocotb Timer wait stalls ~2 s and the sim
  occasionally hangs. The patch is idempotent and survives `uv sync`.
- The sim is still slow (~2 s/transaction) and occasionally hangs at startup;
  the regression runner retries timed-out widths and detects hangs via a
  per-attempt wall-clock timeout.
- The exhaustive sweep uses a standalone Verilator C++ harness (no cocotb);
  `FORCE_REBUILD=1` recompiles it after RTL/harness changes, and stale
  `exhaustive_build/*/expected.bin` files must be removed after changing the
  reference oracle (the binary detects a truncated file and fails loudly).
- The soak (`tests/soak.py`, `make soak`) replays a seeded stream of
  boundary-biased random vectors (all 11 ops, 5 rounding modes) through the
  same C++-driver approach at the medium widths (binary16/BF16/E4M3 default);
  the Python oracle generates the expected records at ~200k vec/s.
- The formal proofs (`make formal`, `bmc_m6_*.sby`) use SymbiYosys from the
  oss-cad-suite. BMC at depth 1 with free a/b/c/rm inputs proves the M6
  properties (comparison consistency, totalOrder ordering laws, roundToIntegral
  idempotence/sign/specials) for EVERY operand pair of binary16 (2^32 pairs),
  E4M3 and E7M0. The arithmetic-op laws (`formal/fp_arith_props.sv`:
  add/mul/fma/sqrt identities) are proven at E4M3/E5M2 and the division laws
  (`formal/fp_div_props.sv`) at E4M3/E5M2/binary16. The proofs target the
  combinational reference datapaths (`jsm_fp_add`, `jsm_fp_mul`, ...); the pipelined
  modules that `jsm_fp_unit` instantiates are tied to them bit-exactly by the
  exhaustive 8-bit sweep, the soak and the streaming test.

## Interface (`jsm_fp_unit`)

    parameter  W_EXP, W_MANT          format
    parameter  DIVSQRT_IMPL = 1       1 SRT pipelines (5.6 ns), 3 SRT 4.0 ns form,
                                      2 iterative engine, 0 combinational
    parameter  TAG_W = 1              request tag width
    parameter  OPS_EN = 16'hFFFF      bit i enables op_t value i
    input      clk, rst_n             rst_n synchronous, active low
    input      in_valid               request
    output     in_ready               request accepted on in_valid && in_ready
    input      mode (op_t), rm (rounding_t), a, b, c, in_tag
    output     y, cmp[1:0], flags[4:0] ({invalid, div0, overflow, underflow, inexact})
    output     out_valid, out_tag     one pulse per accepted request

- Hold `mode/rm/a/b/c/in_tag` stable while `in_valid && !in_ready`.
  `in_ready` depends on `mode` combinationally, never on `in_valid`.
- Every operation has a fixed latency (table below). All pipelines accept a
  request every cycle and share one result port; `in_ready` drops only if
  the requested op would finish in the same cycle as one already in flight
  (a result-port reservation vector), or, with `DIVSQRT_IMPL = 2`, for
  div/sqrt while the iterative engine is busy. Results return in completion
  order, so a later ADD can overtake an earlier SQRT; `out_tag` is the
  `in_tag` of the request that completes. A caller that issues one request
  and waits for `out_valid` always sees `in_ready = 1`.
- The non-rounding ops OP_SGNJ, OP_NEXT and OP_MINMAXNUM take their variant
  from the `rm` field (see "Semantics").
- `OPS_EN` leaves datapaths out of the build (a disabled op behaves as
  reserved: `y = 0`, invalid). This saves area when `mode` varies at run
  time but only some ops are needed: binary16 `jsm_fp_unit` is 33,637 Yosys
  generic cells (`synth -flatten -noabc`) with every op and 12,214 with only
  ADD/SUB/MUL/FMA (`OPS_EN = 16'h0027`). `jsm_fp_exp_seq` uses it to build only MUL
  and ADD/SUB; there its constant `mode` already let synthesis prune the
  rest (same Yosys cell count), so the mask only makes that explicit and
  speeds up elaboration (Yosys synth 12.4 s -> 3.1 s).
- Simulation assertions (Verilator `--assert`) check that `out_valid`
  matches the reservation and that no two pipelines ever deliver in the same
  cycle.

## Pipelined latency-optimized core (178.6 / 250 MHz on VU9P-2L)

The default configuration is fully pipelined with fixed, input-independent
latency per operation. Latencies in cycles (`make metrics-latency`; sgnj,
class, next and minmaxnum are 1 cycle; rndintx equals rndint):

    format   add  sub  mul  fma  div  sqrt  rndint  min/max/cmp/totalOrder/misc
    E4M3       3    3    4    7    4     5      2          1
    E5M2       3    3    4    7    4     4      2          1
    BF16       3    3    4    7    5     7      2          1
    binary16   3    3    4    7    6     8      2          1
    binary32   3    3    4    7    9    15      2          1
    binary64   3    3    5    8   17    29      2          1
    E8M0       1    1    1    1    1     1      1          1  (dedicated modules)

With `DIVSQRT_IMPL = 2` (iterative engine, one div/sqrt in flight) div and
sqrt take floor((W_MANT+3)/2) + 3 cycles: E5M2 5, E4M3 6, BF16 8, binary16 9,
binary32 16, binary64 30; everything else is unchanged.

With `DIVSQRT_IMPL = 3` (the SRT pipelines in their 4.0 ns form: one digit per
stage and a register after the final fold, still one start per cycle) div /
sqrt take E4M3 7/6, E5M2 7/5, BF16 9/8, binary16 11/9, binary32 17/16,
binary64 32/30 cycles; everything else is unchanged.

* `jsm_fp_add_pipe`: 3 stages. S1 unpacks/classifies and computes the per-operand
  alignment shift amounts (signed, from the exponent fields; the subnormal
  bit length is scanned on the mantissa bits so the leading-one scan runs in
  parallel with the classification). S2 aligns with a single bidirectional
  shift per operand (the alignment sticky is folded into the subtractor
  carry-in; the two difference directions are computed in parallel and
  selected by the borrow). S3 normalizes (leading-one + shift) and rounds;
  the subnormal candidate is shifted directly from the pre-normalization sum
  by (e_max - EMIN) - independent of the leading-one position - and the
  rounding increment, exponent and overflow candidates are computed in
  parallel with the GRS decision (carry-select).
* `jsm_fp_mul_core` + `jsm_fp_mul_pipe`: a LUT-only pipelined multiplier (no DSP
  inference), 2 stages for significand width W_MANT+1 <= 32 and 3 stages above (the final
  carry-propagate level is folded into the last tree stage), followed by the
  placement and round/encode stages; shared by the multiply and FMA
  pipelines. The synthesized design uses **0 DSPs**.
* `jsm_fp_div_srt` / `jsm_fp_sqrt_srt`: the generic-format div and sqrt datapaths are
  fully unrolled radix-4 SRT pipelines (carry-save remainder, one start per
  cycle, fixed latency). Division: u' = 4u - 4dD, d in {-2..2}, QST via 4
  precomputed thresholds per 1/32 divisor cell. Sqrt: R' = 16R + bits -
  d(8q+d), d in {-4..4}; the non-restoring |R| <= 2q invariant makes the
  digit round(p/(8q)) selectable from the carry-save estimate. Both use
  on-the-fly Q/QM conversion for negative digits and were validated
  bit-exactly against jsm_fp_div/jsm_fp_sqrt (verification/srt). The remainder is a
  **fixed-width** carry-save pair (S and C modulo 2^CSW, CSW = S_W+4 for
  div, 2*NDIG+5 for sqrt, the proven minimum plus at most one bit): the
  recurrence is linear, so S+C stays congruent to the true residual, the
  wrapped estimate window equals the exact one, and the residual is
  recovered once at the end. The sqrt update -d(8q+d) needs no adder:
  8q+d = {q, d} for d > 0 and {qm, 8-|d|} for d < 0, fed through two 3:2
  levels with the negation's +1s in the zero carry LSBs. Parameters: `DPS`
  digits per stage; `STAGE_FOLD` (default on for DPS >= 2) folds S+C at each
  stage boundary so the next stage's first estimate needs no add;
  `FOLD_STG` registers the final fold separately from the rounding (+1
  cycle). `DIVSQRT_IMPL = 1` uses div DPS 2 (folded) and sqrt DPS 1
  (unfolded); `DIVSQRT_IMPL = 3` uses DPS 1, no stage fold and FOLD_STG for
  both.
* `jsm_fp_divsqrt_iter` (`DIVSQRT_IMPL = 2`): the radix-4 iterative engine
  (latency K+3, one operation in flight); `DIVSQRT_IMPL = 0` selects the
  legacy combinational `jsm_fp_div`/`jsm_fp_sqrt`.
* `jsm_fp_fma_pipe`: 7 cycles for W_MANT+1 <= 32 (8 above). The subnormal-candidate
  shift is computed from the pre-normalization accumulator in the normalize
  stage (the jsm_fp_add_pipe placement-ahead trick), so round/encode is a single
  stage; it inherits the shorter shared multiplier core. That shift does not
  depend on the leading-one position, which forced the old two-part
  round/encode (F5a/F5b) split.
* `jsm_fp_roundint_pipe`: 2 stages (prepare/GRS/round fused); `jsm_fp_minmax_pipe`/
  `jsm_fp_cmp_pipe`/`jsm_fp_totalorder_pipe`: 1 stage (compare/select + register).

Measured with `make vivado` (`syn/vivado-impl.tcl`: non-project batch,
`synth_design -mode out_of_context`, opt, place, phys_opt, route, phys_opt;
I/O registered by `syn/fp_unit_timing.sv`) with Vivado 2026.1.1 on
**xcvu9p-flga2104-2L-e**, binary32, 2026-11-04:

    build                    clock     WNS      CLB LUTs  regs   DSP  limiting path
    DIVSQRT_IMPL=1 (default) 5.600 ns  +0.131   12,656   4,089   0   div SRT stage (2 digits)
    DIVSQRT_IMPL=3 (SRT)     4.000 ns  +0.001   13,368   5,143   0   all pipelines within 50 ps
    DIVSQRT_IMPL=2 (iter)    4.000 ns  +0.066    7,368   2,255   0   fma / iter / mul

(`make vivado VIVADO_ARGS="4.000 8 23 3"` for the second row, `"4.000 8 23
2"` for the third; `syn/vivado-module.tcl` times one datapath module.)
Before the fixed-width carry-save change the default build measured +0.055 ns
and 13,338 LUTs at commit `0c8b86f`, with the sqrt stage limiting; it does
not fit 4.0 ns.

Wall-clock latency at binary32: div 9 x 5.6 = 50 ns (`=1`), 17 x 4.0 = 68 ns
(`=3`), 16 x 4.0 = 64 ns but one at a time (`=2`); sqrt 84 / 64 / 64 ns;
every other operation is 1.4x faster at 4.0 ns. `DIVSQRT_IMPL = 3` is the
fastest choice unless division latency dominates; it costs 700 more LUTs
and 1,000 more registers than `=1`.

The progression: the original combinational design measured 17.6 ns
(~57 MHz); the Fmax pass pipelined every operation and closed at 4.00 ns with
5-cycle add/mul and a 2-cycle-per-digit div/sqrt engine. The latency pass cut
mul to 4 cycles, div/sqrt to one cycle per radix-4 digit (binary32 29 -> 17,
binary64 57 -> 31) and the ordering/roundint ops to 1-2 cycles; the add/sub
datapath was then restructured to 3 cycles (single-shift alignment, parallel
direction subtract, subnormal placement registered ahead of the normalize/
round stage), while re-closing the same 4.00 ns clock. A later FMA pass
computed the subnormal candidate from the pre-normalization accumulator (the
same placement-ahead trick) and merged the round/encode stages, taking FMA
8 -> 7 (binary64 9 -> 8), and aligned the FMA context with the core latency so
back-to-back start streams are correct; div/sqrt resolved the classifier in
the start cycle for K+3 (binary32 17 -> 16, binary64 31 -> 30). That pass
re-closed at +0.014 ns; the earlier FMA F1+F2 merge and the div/sqrt K+1
setup/publish folds were measured and rejected at 4.000 ns. The final pass
replaced the div/sqrt datapaths with the SRT pipelines above, cutting the
cycle counts (div 16 -> 9, sqrt 16 -> 15 at binary32) at the cost of the
operating clock (250 -> 178.6 MHz); the trade-offs are analysed above.
The fixed-width carry-save SRT pipelines (`DIVSQRT_IMPL = 3`) then brought
the fully pipelined div/sqrt back to 4.0 ns. `DIVSQRT_IMPL = 0` selects the
legacy combinational divider and square root (much longer critical path);
the other operations stay pipelined. The legacy modules are kept for the
formal property checks.

`tests/latency.py`
(`make metrics-latency`) prints the per-op cycle table above and checks that
every op has a constant latency across normal, subnormal and special vectors.

## Semantics (bit-exact vs tests/reference)

- NaN results: quiet NaN, sign 0, payload of the first NaN operand (6.2.3).
- Infinity (add): like-sign infinities sum to infinity; magnitude subtraction
  of infinities signals invalid (7.2d). Infinity (mul): the sign of a product
  of infinities is the XOR of the operand signs; inf x 0 signals invalid
  (7.2e). Infinity (div): inf / finite = inf and finite / inf = 0 (sign XOR);
  inf / inf signals invalid (7.2f).
- Zero (add): x + 0 = x; exact zero sums keep the like-sign operand sign,
  else +0 or -0 under roundTowardNegative (6.3). Zero (mul): the sign of a
  product of zeros is the XOR of the operand signs (6.3). Zero (div): 0 / x =
  0 and x / 0 = inf (7.3 divide-by-zero), both with the XOR sign; 0 / 0
  signals invalid (7.2f). Zero (sqrt): sqrt(+-0) = +-0.
- Square root (5.4.1): sqrt of a negative number (finite or infinite)
  signals invalid (7.2g); sqrt(+inf) = +inf; the root is computed by integer
  digit-by-digit square root with a sticky bit from the remainder.
- Fused multiply-add (5.4.1): (a x b) + c with a single rounding, computed in
  a wide accumulator (3p+6 bits) that holds the exact sum; inf x 0 (7.2e)
  and inf + -inf (7.2d) signal invalid. The `c` operand is a third input
  port.
- minimum/maximum (9.6): the smaller/larger operand is returned exactly
  (NaN propagates; minimum(-0,+0) = -0, maximum(-0,+0) = +0); no rounding.
- Quiet comparison (5.11): a 2-bit condition code is output on `cmp`
  (`jsm_fp_pkg::CMP_LT/CMP_EQ/CMP_GT/CMP_UN`); -0 equals +0, NaN is unordered,
  and only a signaling NaN signals invalid. The `y` output is 0.
- roundToIntegral (5.9): x rounded to an integral value per the rounding
  direction; NaN is quieted with its sign and payload preserved, infinity and
  zero (including its sign) are returned unchanged, and a fractional value
  that rounds to zero takes the sign of x (e.g. -0.4 under RNE -> -0).
  Inexact is never signaled. For the degenerate emax < p-1 formats the
  rounded integer can exceed the largest finite; that overflow follows 7.4.
- totalOrder (5.10): cmp[0] = 1 iff a precedes-or-equals b. It is a non-strict
  order over the canonical encodings (totalOrder(x, x) is true), orders
  -0 below +0, and orders NaNs (payload/quiet) as the sign-magnitude integer
  comparison of the encodings. It never signals, even for a signaling NaN.
- Overflow (7.4): flagged iff the unbounded-range rounded result exceeds the
  largest finite; RNE/RNA -> inf, RZ -> max finite, RP/RM by sign; inexact
  always set. (sqrt can never overflow or underflow: sqrt(2^emax) <=
  2^(emax/2) and sqrt(2^emin) >= 2^(emin/2).)
- roundToIntegralExact (OP_RNDINTX, 5.3.1): the roundToIntegral result,
  plus inexact whenever a finite operand is not already integral.
- Sign bit operations (OP_SGNJ, 5.5.1): `rm` 0 copy(a), 1 negate(a), 2
  abs(a), 3 copySign(a, b) (4: copy). Only the sign bit changes; NaNs are not
  quieted and nothing is ever signaled.
- class (OP_CLASS, 5.7.2): `y` = class index, zero-extended: 0
  signalingNaN, 1 quietNaN, 2 negativeInfinity, 3 negativeNormal, 4
  negativeSubnormal, 5 negativeZero, 6 positiveZero, 7 positiveSubnormal, 8
  positiveNormal, 9 positiveInfinity. Never signals.
- nextUp / nextDown (OP_NEXT, 5.3.1): `rm` 1 nextDown, any other value
  nextUp. nextUp(+-0) is the least positive number, nextUp(-least) = -0,
  nextUp(max finite) = +inf with no flags, nextUp(-inf) = -max finite;
  nextDown(x) = -nextUp(-x). A NaN gives the NaN result above; only a
  signaling NaN signals invalid.
- minimumNumber family (OP_MINMAXNUM, 9.6): `rm` 0 minimumNumber, 1
  maximumNumber, 2 minimumMagnitudeNumber, 3 maximumMagnitudeNumber (4:
  minimumNumber). With exactly one NaN operand the other operand is
  returned; with two NaNs, the NaN result above. Invalid iff either operand
  is a signaling NaN. -0 < +0. The Magnitude variants compare |a| and |b|
  and use the non-magnitude rule on a tie.
- Reserved encodings: rounding modes 5-7 behave as roundTiesToEven (and as
  sub-op 0 for the ops above); an opcode disabled by `OPS_EN` returns
  `y = 0` with the invalid flag after 1 cycle.
- Underflow (7.5): tininess detected after rounding; flagged iff the rounded
  result is a non-zero subnormal and the rounding is inexact. (For add/sub
  the exact result is always a multiple of the minimum subnormal, so the
  flag can never be raised there; mul, div and fma raise it for tiny results.)

## Helper modules

- `jsm_fp32_to_bf16_round`: binary32 -> bfloat16, roundTiesToEven, no flags.
  +-Inf passes through; a NaN becomes a quiet NaN keeping its sign and top 6
  payload bits (never infinity). Verified over all 2^32 inputs
  (`make bf16`).
- `jsm_fp_exp_seq`: fp32 exp(x) for x clamped to [-16, 16] (|x| > 16, +-Inf and
  NaN clamp to +-16), by x/32, a degree-6 polynomial and five squarings;
  87 cycles. Measured error vs the correctly rounded result: <= ~45 ulp
  (~5e-6 relative) for |x| <= 8, up to ~1.3k ulp (~1.5e-4) near |x| = 16
  (`make regress-exp`).
