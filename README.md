# IEEE 754-2019 floating-point unit (SystemVerilog) with cocotb verification

Parametrized combinational FPU: `W_EXP` exponent bits and `W_MANT` fraction
bits (IEEE 754-2019 3.7 "extendable precision"; binary16/32/64 and odd sizes
are covered by the test matrix). Implements addition/subtraction,
multiplication, division, square root, fused multiply-add, minimum/maximum
(5.4.1, 5.6.1), quiet comparison (5.11), roundToIntegral (5.9) and totalOrder
(5.10) with all five rounding-direction attributes (4.3), full subnormal
support (3.3) and the five exception flags (7.2-7.6, including divide-by-zero
7.3). The operation is selected by the 4-bit `mode` input (`fp_pkg::op_t`).

## Layout

    rtl/                fp_pkg.sv, fp_add.sv, fp_mul.sv, fp_div.sv, fp_sqrt.sv,
                        fp_divsqrt_iter.sv, fp_fma.sv, fp_minmax.sv, fp_cmp.sv,
                        fp_totalorder.sv, fp_roundint.sv, the *_e8m0.sv sibling
                        modules, the *_pipe.sv pipelined siblings and fp_mul_core.sv,
                        fp_unit.sv (synthesizable SV) and
                        fp_unit_axilite.sv (AXI4-Lite register wrapper)
    tests/reference/    bit-exact Python oracle (exact rational arithmetic)
    tests/test_fp_unit.py     cocotb tests (directed vectors + randomized)
    tests/test_fp_unit_axilite.py  cocotb AXI4-Lite register-map tests
    tests/run_regression.py   builds and runs the width matrix
    tests/exhaustive.py       exhaustive all-vectors sweep of every 8-bit format
    tests/soak.py             cross-width randomized soak (medium formats)
    tests/latency.py          per-op in_valid -> out_valid cycle-count probe
    tests/metrics.py          area/timing proxies (yosys) + target runtimes
    metrics/                  baseline/after metrics JSON (for --compare)
    formal/ + bmc_m6_*.sby    SymbiYosys formal property proofs of the M6 ops

## Running

    uv run python tests/run_regression.py            # default matrix
    uv run python tests/run_regression.py --all      # full 8-width matrix
    uv run python tests/run_regression.py --width 8 23
    FP_ITERS=200 uv run python tests/run_regression.py --width 8 23
    uv run python tests/exhaustive.py                # all 7 8-bit formats
    uv run python tests/soak.py                      # cross-width soak
    uv run python tests/exhaustive.py --iter         # iterative div/sqrt build
    uv run python tests/soak.py --iter               # iterative div/sqrt build
    make regress | make smoke | make soak | make lint
    make exhaustive-iter | make soak-iter            # ITER_DIVSQRT=1 builds
    make formal   # SymbiYosys BMC proofs (needs the oss-cad-suite)
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
  E4M3 and E7M0. The full RTL (all datapaths) is yosys-parseable; the
  arithmetic-op laws (`formal/fp_arith_props.sv`, `formal/fp_div_props.sv`)
  are written but currently blocked by a yosys 0.68 `write_smt2` bug that
  corrupts the model when several instances of the parameterized datapath
  modules coexist (see the HANDOFF notes). The RTL is verified bit-exact by
  the regression and the exhaustive sweep regardless.

## Pipelined latency-optimized core (250 MHz on VU9P-2L)

The default configuration is fully pipelined with fixed, input-independent
latency per operation. `in_valid` starts an operation (one pulse; ignored
while the same pipeline is busy) and `out_valid` pulses once with `y`/`flags`
(and `cmp`). Latencies in cycles:

    format   add  sub  mul  fma  div  sqrt  rndint  min/max/cmp/totalOrder
    E4M3       4    4    4    8    7     7      2          1
    E5M2       4    4    4    8    6     6      2          1
    BF16       4    4    4    8    9     9      2          1
    binary16   4    4    4    8   10    10      2          1
    binary32   4    4    4    8   17    17      2          1
    binary64   4    4    5    9   31    31      2          1
    E8M0       1    1    1    1    1     1      1          1  (dedicated modules)

* `fp_add_pipe`: 4 stages (unpack -> align -> add + subnormal placement ->
  normalize/round/encode). The subnormal candidate is shifted directly from
  the pre-normalization sum by (e_max - EMIN), which is independent of the
  leading-one position, so the subnormal path never waits for the normalize
  shift (and is computed in the add stage, in parallel with it).
* `fp_mul_core` + `fp_mul_pipe`: a LUT-only pipelined multiplier (no DSP
  inference), 2 stages for W <= 32 and 3 stages above (the final
  carry-propagate level is folded into the last tree stage), followed by the
  placement and round/encode stages; shared by the multiply and FMA
  pipelines. The synthesized design uses **0 DSPs**.
* `fp_divsqrt_iter`: radix-4 iterative engine, ONE digit per cycle (the
  digit-select compare, the multiple mux and the remainder subtraction are
  fused into a single registered step), plus a two-phase preload and a
  publish cycle: latency K+4 with K = ceil((W_MANT+3)/2). It is constant for
  every input, including special cases, and the restoring recurrence is
  unchanged, so the results stay bit-exact with fp_div/fp_sqrt.
* `fp_fma_pipe`: the wide-accumulator FMA is the longest of the add/mul/fma
  group (8 cycles for W <= 32, 9 above); it was left structurally unchanged
  and inherits the shorter shared multiplier core.
* `fp_roundint_pipe`: 2 stages (prepare/GRS/round fused); `fp_minmax_pipe`/
  `fp_cmp_pipe`/`fp_totalorder_pipe`: 1 stage (compare/select + register).

Measured with the single Vivado implementation run (non-project batch,
`synth_design -mode out_of_context`, 4.000 ns clock, `place_design`,
`route_design`) on **xcvu9p-flga2104-2L-e**:

    WNS +0.001 ns, TNS 0, 0 failing endpoints (3044)  -> 250 MHz met
    6974 CLB LUTs, 2301 CLB registers, 0 DSPs

The progression: the original combinational design measured 17.6 ns
(~57 MHz); the Fmax pass pipelined every operation and closed at 4.00 ns with
5-cycle add/mul and a 2-cycle-per-digit div/sqrt engine. The latency pass cut
add/sub/mul to 4 cycles, div/sqrt to one cycle per radix-4 digit (binary32
29 -> 17, binary64 57 -> 31) and the ordering/roundint ops to 1-2 cycles,
while re-closing the same 4.00 ns clock. `ITER_DIVSQRT = 0` selects the legacy
combinational divider and square root (much longer critical path); the other
operations stay pipelined. The legacy modules are kept for the formal
property checks.

The `--iter` harness flags and `FP_ITER_DIVSQRT=1` still exist and now select
the same default engine configuration. `tests/latency.py`
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
- minimum/maximum (5.6.1): the smaller/larger operand is returned exactly
  (NaN propagates; minimum(-0,+0) = -0, maximum(-0,+0) = +0); no rounding.
- Quiet comparison (5.11): a 2-bit condition code is output on `cmp`
  (`fp_pkg::CMP_LT/CMP_EQ/CMP_GT/CMP_UN`); -0 equals +0, NaN is unordered,
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
- Underflow (7.5): tininess detected after rounding; flagged iff the rounded
  result is a non-zero subnormal and the rounding is inexact. (For add/sub
  the exact result is always a multiple of the minimum subnormal, so the
  flag can never be raised there; mul, div and fma raise it for tiny results.)
