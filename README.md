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
                        modules, fp_unit.sv (synthesizable SV) and
                        fp_unit_axilite.sv (AXI4-Lite register wrapper)
    tests/reference/    bit-exact Python oracle (exact rational arithmetic)
    tests/test_fp_unit.py     cocotb tests (directed vectors + randomized)
    tests/test_fp_unit_axilite.py  cocotb AXI4-Lite register-map tests
    tests/run_regression.py   builds and runs the width matrix
    tests/exhaustive.py       exhaustive all-vectors sweep of every 8-bit format
    tests/soak.py             cross-width randomized soak (medium formats)
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

## Pipelined Fmax-optimized core (250 MHz on VU9P-2L)

The default configuration is fully pipelined with fixed, input-independent
latency per operation. `in_valid` starts an operation (one pulse; ignored
while the same pipeline is busy) and `out_valid` pulses once with `y`/`flags`
(and `cmp`). Latencies in cycles:

    format   add  sub  mul  fma  div  sqrt  rndint  min/max/cmp/totalOrder
    E4M3       5    5    5    9    9     9      3          2
    E5M2       5    5    5    9    7     7      3          2
    BF16       5    5    5    9   13    13      3          2
    binary16   5    5    5    9   15    15      3          2
    binary32   5    5    5    9   29    29      3          2
    binary64   5    5    5    9   57    57      3          2
    E8M0       1    1    1    1    1     1      1          1  (dedicated modules)

* `fp_add_pipe`/`fp_mul_pipe`/`fp_fma_pipe`/`fp_roundint_pipe`: the rounding
  datapaths split into registered stages (align -> add -> normalize -> round).
* `fp_mul_core`: a LUT-only pipelined (24x24) multiplier (carry-save adder
  tree, no DSP inference), shared by the multiply and FMA pipelines; the
  synthesized design uses **0 DSPs**.
* `fp_divsqrt_iter`: radix-4 iterative engine, two cycles per digit step (a
  digit-select phase and an apply phase) plus a two-phase preload; the
  latency is constant for every input, including special cases.
* `fp_minmax_pipe`/`fp_cmp_pipe`/`fp_totalorder_pipe`: 2-stage versions of the
  ordering datapaths.

Measured with the single Vivado implementation run (non-project batch,
`synth_design -mode out_of_context`, 4.000 ns clock, `place_design`,
`route_design`) on **xcvu9p-flga2104-2L-e**:

    WNS +0.022 ns, TNS 0, 0 failing endpoints (3495)  -> 250 MHz met
    6994 CLB LUTs, 2625 CLB registers, 0 DSPs

The progression: the original combinational design measured 17.6 ns
(~57 MHz); after the pipelined add/mul/fma it was 5.0 ns, after the roundint
and small-op pipes 4.65 ns, and after splitting the div/sqrt engine steps and
preload it closed at 4.00 ns. `ITER_DIVSQRT = 0` selects the legacy
combinational divider and square root (much longer critical path); the other
operations stay pipelined. The legacy modules are kept for the formal
property checks.

The `--iter` harness flags and `FP_ITER_DIVSQRT=1` still exist and now select
the same default engine configuration.

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
