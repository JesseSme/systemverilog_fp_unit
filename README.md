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

## Optimization: iterative div/sqrt (`ITER_DIVSQRT`)

`fp_unit` takes a third parameter `ITER_DIVSQRT` (default 0). With
`ITER_DIVSQRT = 1` (W_MANT > 0) the combinational `fp_div`/`fp_sqrt` datapaths
are replaced by the shared multi-cycle engine `fp_divsqrt_iter`, which
produces one quotient bit (division) or one root bit per two radicand bits
(sqrt) per cycle using a single adder/subtractor. Semantics are bit-exact with
the combinational modules (verified by the exhaustive 8-bit sweeps and the
medium-width soaks in `--iter` mode).

Handshake: pulse `in_valid` together with a/b/c/mode/rm (ignored while the
engine is busy); `out_valid` pulses one cycle with the registered `y`/`flags`.
Single-cycle operations keep the original 1-cycle latency. The AXI-Lite
wrapper takes the same parameter and waits on `out_valid`.

Measured with `make metrics-area` (yosys `synth -noabc`, generic-gate cells /
longest topological path):

    format   default cells  ITER cells   default ltp  ITER ltp
    E4M3          9,437        7,913        165/160*      60
    binary16     22,987       16,012        397/309*      68
    BF16         17,698       13,534        251*          67
    binary32     63,685       35,143        965/657*      78

    * combinational fp_div / fp_sqrt (the largest contributor; fp_sqrt also
      dropped ~25-28% from taking its sticky bit from the isqrt remainder)

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
