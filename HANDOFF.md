# FP Unit — Handoff Report

## Project

IEEE 754-2019 floating-point unit in SystemVerilog, verified against a
bit-exact Python oracle (exact rational arithmetic, clause 4.3 rounding) via
cocotb randomized regression plus exhaustive all-vector checks of every 8-bit
format.

## Toolchain (pinned, per user instruction)

- **Verilator 5.020** (Debian system package `/usr/bin/verilator`)
- **cocotb 1.9.2** (`pyproject.toml` pins `cocotb>=1.9.2,<2`; cocotb 2.x
  requires Verilator ≥5.036 which is not available)
- **Python 3.13** (uv-managed, `.venv`)
- **uv** for dependency management (`uv sync`, `uv run`)
- **SymbiYosys 0.68 / Yosys** (formal verification only; from the
  oss-cad-suite at `/home/jesse/Documents/oss-cad-suite-linux-x64-20260813`,
  `make formal` prepends `$(OSS)/bin` to PATH)

### Toolchain quirks (workarounds in place)

1. **cocotb 1.9.2's `verilator.cpp` does not advance Verilator's internal
   clock.** Without the patch, every `await Timer(1, "ns")` stalls for ~2
   seconds. `tests/run_regression.py` patches the venv's
   `cocotb/share/lib/verilator/verilator.cpp` on every run (idempotent):
   adds `Verilated::time(main_time);` after `main_time = next_time;`.
   The patch bumps the file mtime by 2 seconds to force `make` to recompile
   `verilator.o` (avoids the equal-mtime pitfall).

2. **The sim occasionally hangs at startup** (cocotb 1.9.2 + Verilator 5.020
   race). `run_regression.py` retries each width up to 3 times on timeout
   (default 1800 s per attempt).

3. **`pkill -f "path/fp_unit"` kills its own shell** (the pattern matches the
   shell's command line). Use `kill -9 $(pgrep -x fp_unit)` instead.

> Former quirk: the sim used to take ~2 s/transaction, blamed on cocotb's VPI
> overhead. This turned out to be an RTL bug (bug 14 below): a subnormal-path
> loop ran 2^32 iterations per normal-path transaction. Fixed — the full
> 8-width regression now runs in ~1 s.

## Repository layout

```
rtl/
  fp_pkg.sv           Package: rounding-mode/opcode enums, flag bit positions
  fp_add.sv           Generic add/sub (W_MANT > 0): align → GRS add → round
  fp_mul.sv           Generic mul (W_MANT > 0): 2p-bit product → place → round
  fp_div.sv           Generic div (W_MANT > 0): long division → place → round
  fp_sqrt.sv          Generic sqrt (W_MANT > 0): digit-by-digit isqrt → round
  fp_fma.sv           Generic fma (W_MANT > 0): wide-accumulator exact sum → round
  fp_minmax.sv        Generic min/max (format-generic; used at every width)
  fp_add_e8m0.sv      Dedicated E8M0 add/sub (W_MANT = 0): power-of-two logic
  fp_mul_e8m0.sv      Dedicated E8M0 mul (W_MANT = 0): exact 2^(e_a+e_b) logic
  fp_div_e8m0.sv      Dedicated E8M0 div (W_MANT = 0): exact 2^(e_a-e_b) logic
  fp_sqrt_e8m0.sv     Dedicated E8M0 sqrt (W_MANT = 0): even/odd exponent logic
  fp_fma_e8m0.sv      Dedicated E8M0 fma (W_MANT = 0): 2^(e_a+e_b) + 2^e_c logic
  fp_cmp.sv           Format-generic quiet comparison (5.11): LT/EQ/GT/UN code
  fp_totalorder.sv    Format-generic totalOrder (5.10): sign-magnitude key
  fp_roundint.sv      Generic roundToIntegral (5.9): GRS at the binary point
  fp_roundint_e8m0.sv Dedicated E8M0 roundToIntegral: 2^e < 1 -> 0 or 1
  fp_unit.sv          Top: generate-switch between the *_e8m0 and generic ops
tests/
  reference/
    formats.py        BinFormat dataclass, encode/decode/classify
    rounding.py       round_to_format (exact rational → bits + flags)
    ops.py            fp_add/mul/div/sqrt/fma/min/max references (specials + rounding)
    gen.py            Random input generators (uniform, boundary, subnormal…)
  test_fp_unit.py     Cocotb tests: directed vectors + randomized regression
  run_regression.py   Build + run loop with timeout/retry, self-patching
  exhaustive_main.cpp Standalone Verilator C++ harness (fast all-vectors check)
  exhaustive.py       Driver: reference expected vectors + build/run exhaustive
  soak_main.cpp       Standalone Verilator C++ harness (fast random soak)
  soak.py             Driver: seeded random soak at medium widths (make soak)
formal/
  fp_m6_props.sv      Formal properties: comparison/totalOrder/roundToIntegral
  fp_m6_props_e8m0.sv Formal properties for the E8M0 M6 datapaths
bmc_m6_*.sby          SymbiYosys BMC configs (binary16, E4M3, E7M0)
Makefile              Convenience targets: regress, regress-all, smoke, soak,
                      formal, lint
pyproject.toml        cocotb>=1.9.2,<2 dependency
README.md             Usage and semantics documentation
```

Build artifacts (`sim_build/`, `exhaustive_build/`, `soak_build/`, `obj_dir/`,
the sby `*_bmc/` work dirs) and the vendored `cocotb/`/`verilator/` source
trees are gitignored.

## FPU features (current state)

### Implemented (M1-M5: add/sub, mul, div, sqrt, FMA + min/max; M6: comparisons,
### roundToIntegral, totalOrder)

- **Operation**: addition, subtraction, multiplication, division, square root,
  fused multiply-add, minimum/maximum (5.4.1, 5.6.1), quiet comparison (5.11),
  roundToIntegral (5.9) and the totalOrder predicate (5.10). `OP_SUB` is
  `OP_ADD` with the second operand's effective sign flipped. `op_t` is now a
  4-bit enum: `OP_ADD`/`OP_SUB`/`OP_MUL`/`OP_DIV`/`OP_SQRT`/`OP_FMA`/`OP_MIN`/
  `OP_MAX`/`OP_CMP`/`OP_RNDINT`/`OP_TOTALORDER`. `fp_unit.sv` muxes the result
  on the opcode, defaulting to the add datapaths. sqrt ignores `b`; FMA uses a
  third input port `c`; the compare/totalOrder ops drive a 2-bit `cmp` output
  (condition code for OP_CMP, totalOrder boolean for OP_TOTALORDER; 0 for all
  other ops).
- **Parameterized format**: `W_EXP` exponent bits + `W_MANT` fraction bits,
  any width (verified 8-bit family through binary64). Significand is
  `1 + W_MANT` bits, implicit bit (3.3/3.7).
- **Microscaling formats** (`W_MANT = 0`): dedicated `fp_{add,mul,div,sqrt,fma}_e8m0`
  datapaths for shared-exponent formats (E8M0, E7M0, …) with `p = 1` semantics;
  `fp_minmax` is format-generic and used for both branches.
- **All five rounding-direction attributes** (4.3): RNE, RNA, RZ, RP, RM.
- **Full subnormal support** (3.3): subnormal operands, subnormal results,
  tininess-after-rounding underflow detection (7.5). Mul/div/fma underflow
  for tiny results; sqrt never underflows.
- **Special values** (6.x): qNaN/sNaN (invalid signaling, quiet bit, payload
  of the first NaN operand; any sNaN operand signals invalid), infinities
  (7.2d magnitude-subtraction → invalid for add; 7.2e inf × 0 → invalid for
  mul/fma; 7.2f inf/inf and 0/0 → invalid for div; 7.2g sqrt of a negative
  number → invalid), ±0 with clause 6.3 sign rules (products/quotients use
  the XOR sign; sqrt(±0) = ±0; minimum(-0,+0) = -0 and maximum(-0,+0) = +0
  per 5.6.1).
- **FMA** (5.4.1): (a × b) + c computed in a wide accumulator (3p+6 bits)
  that holds the exact sum with a single GRS rounding — no double rounding.
- **Division by zero** (7.3): finite-nonzero / 0 → ±inf with `FLAG_DIV0`.
  0/0 is invalid (7.2f), not divide-by-zero.
- **Exception flags** (7): invalid, div-by-zero, overflow, underflow, inexact
  are all signaled.
- **Overflow semantics** (7.4): rounded-unbounded-result detection; RNE/RNA →
  ±inf, RZ → ±max finite, RP/RM → ±inf or ±max finite by sign; inexact always
  accompanies overflow. The mul/div/fma/sqrt datapaths also handle the
  degenerate exponent-range corner (W_EXP = 1, EMIN > EMAX): a subnormal
  result that rounds up to the smallest normal 2^emin, which already exceeds
  the largest finite, signals overflow per 7.4. roundToIntegral never
  overflows for conforming formats (emax ≥ p-1); the degenerate corner is
  handled per 7.4 with OF+INE.
- **Quiet comparison** (5.11, `fp_cmp.sv`, format-generic): a 2-bit condition
  code (CMP_LT/EQ/GT/UN) on the `cmp` output; -0 compares equal to +0, NaN is
  unordered, only a signaling NaN signals invalid. `y` is 0.
- **roundToIntegral** (5.9, `fp_roundint.sv` + `fp_roundint_e8m0.sv`): rounds
  to an integral value per the rounding-direction attribute; a NaN is quieted
  with its sign and payload preserved (differs from the arithmetic ops' sign-0
  NaN convention), infinity and zero are returned unchanged, a fractional
  value that rounds to zero keeps the sign of x, and inexact is never
  signaled. The generic datapath rounds a fixed-point significand at the
  binary point (guard/round/sticky) and re-encodes the integer result.
- **totalOrder** (5.10, `fp_totalorder.sv`, format-generic): cmp[0] = 1 iff a
  precedes-or-equals b. Non-strict (totalOrder(x, x) is true), -0 below +0,
  NaNs ordered by the sign-magnitude integer comparison of the encodings
  (payload ordering is a valid 754-2019 choice and satisfies 754-2008);
  never signals, even for a signaling NaN.

### Missing (future milestones)

- **Microarchitecture**: the datapath is combinational (single `always_comb`
  block, no clock/pipeline). Pipelining, a clocked register interface, and a
  wider opcode space (`op_t` is now 4 bits with 5 values free) would be needed
  for more operations and higher throughput.

## What works (regression-verified)

### Full op set — all 8 widths pass 20/20 test suites

| W_EXP | W_MANT | Format       | Dir | DirMul | DirDiv | DirSqrt | DirFma | DirMM | DirCmp | DirTot | DirRnd | Random | MulRnd | DivRnd | SqrtRnd | FmaRnd | MmRnd | CmpRnd | TotRnd | RndRnd | Cancel | Boundary |
|-------|--------|--------------|-----|--------|--------|---------|--------|-------|--------|--------|--------|--------|--------|--------|---------|--------|-------|--------|--------|--------|-------|----------|
| 4     | 3      | F8 E4M3      | P   | P      | P      | P       | P      | P     | P      | P      | P      | P      | P      | P      | P       | P      | P     | P      | P      | P     | P     | P        |
| 5     | 10     | binary16     | P   | P      | P      | P       | P      | P     | P      | P      | P      | P      | P      | P      | P       | P      | P     | P      | P      | P     | P     | P        |
| 8     | 23     | binary32     | P   | P      | P      | P       | P      | P     | P      | P      | P      | P      | P      | P      | P       | P      | P     | P      | P      | P     | P     | P        |
| 11    | 52     | binary64     | P   | P      | P      | P       | P      | P     | P      | P      | P      | P      | P      | P      | P       | P      | P     | P      | P      | P     | P     | P        |
| 6     | 16     | odd          | P   | P      | P      | P       | P      | P     | P      | P      | P      | P      | P      | P      | P       | P      | P     | P      | P      | P     | P     | P        |
| 10    | 40     | odd          | P   | P      | P      | P       | P      | P     | P      | P      | P      | P      | P      | P      | P       | P      | P     | P      | P      | P     | P     | P        |
| 8     | 0      | F8 E8M0      | P   | P      | P      | P       | P      | P     | P      | P      | P      | P      | P      | P      | P       | P      | P     | P      | P      | P     | P     | P        |
| 8     | 7      | BF16         | P   | P      | P      | P       | P      | P     | P      | P      | P      | P      | P      | P      | P       | P      | P     | P      | P      | P     | P     | P        |

All widths pass the full randomized regression at `FP_ITERS=100` (binary16 and
binary32 also at `FP_ITERS=500`).

### Exhaustive 8-bit verification (all 11 ops)

Every `(op, rm, a, b)` combination — op ∈ {add, sub, mul, div, sqrt, fma,
min, max, cmp, rndint, totalorder}, all five rounding modes, all 2^8 values
per operand — is checked against the reference oracle for each of the
**7 eight-bit formats** (1+W_EXP+W_MANT == 8). The FMA op uses a fixed `c` per
format (1.0); the other ops ignore `c`:

| W_EXP | W_MANT | Format                | Vectors    | Result |
|-------|--------|-----------------------|------------|--------|
| 1     | 6      | (p=7, emax=0)         | 3,604,480  | PASS   |
| 2     | 5      | (p=6)                 | 3,604,480  | PASS   |
| 3     | 4      | (p=5)                 | 3,604,480  | PASS   |
| 4     | 3      | F8 E4M3               | 3,604,480  | PASS   |
| 5     | 2      | F8 E5M2               | 3,604,480  | PASS   |
| 6     | 1      | (p=2)                 | 3,604,480  | PASS   |
| 7     | 0      | E7M0 microscaling     | 3,604,480  | PASS   |

**25,231,360 vectors total, 0 mismatches.** The harness is a standalone
Verilator C++ driver (`tests/exhaustive_main.cpp`) driven by
`tests/exhaustive.py`, which precomputes the expected results with
`tests/reference/ops.py`. It bypasses cocotb entirely, so the whole sweep runs
in ~3-4 min. The expected records are now 3 bytes `(y, flags, cmp)`. Since the
datapath is identical at every width, exhaustive coverage of the 8-bit family
gives high confidence for the larger formats too. Note the harness caches its
binary and expected files: after RTL/reference changes run `FORCE_REBUILD=1`
and delete stale `exhaustive_build/*/expected.bin` (the binary fails with
"truncated expected file" if they are out of sync).

### Cross-width soak (medium formats)

`tests/soak.py` drives a seeded stream of boundary-biased random operands
through all 11 ops at widths where exhaustive enumeration is infeasible.
Default run (5M vectors x binary16, BF16, E4M3):

| Format | Vectors   | Result |
|--------|-----------|--------|
| binary16 (5,10) | 5,000,000 | PASS   |
| BF16 (8,7)      | 5,000,000 | PASS   |
| E4M3 (4,3)      | 5,000,000 | PASS   |

binary32 also passes (soak at `--width 8 23`). The Python oracle generates the
expected stream at ~200k vec/s, then the C++ harness replays it at full speed.

### Formal BMC proofs (M6 datapaths + arithmetic/division laws, sby depth 1)

SymbiYosys BMC over free `a`/`b`/`c`/`rm` inputs proves each property for
EVERY operand pair of the format (2^32 pairs at binary16 — beyond the
exhaustive sweep's reach):

| Config            | Width  | Properties proven                                   | Result |
|-------------------|--------|------------------------------------------------------|--------|
| `bmc_m6_b16.sby`  | (5,10) | cmp symmetry/NaN/-0==+0/sNaN-invalid; totalOrder reflexive/total/antisym/transitive/-0<+0; roundToIntegral idempotent/sign/specials; min/max agreement | PASS |
| `bmc_m6_e4m3.sby` | (4,3)  | same property set                                     | PASS |
| `bmc_m6_e7m0.sby` | (7,0)  | E8M0 roundToIntegral idempotent/sign/integral-powers; cmp never unordered; totalOrder laws | PASS |
| `bmc_arith_e4m3.sby` | (4,3) | add/mul commutativity (excl. both-NaN); a+0==a, a*1==a (finite nz); a+(-a)==±0; OP_SUB==sign-flip; a*0 sign; fma(a,b,0)==mul, fma(a,1,c)==add; fma comm; sqrt>=0 | PASS |
| `bmc_arith_e5m2.sby` | (5,2) | same arithmetic law set                              | PASS |
| `bmc_div_e4m3.sby` | (4,3) | a/a==1, a/1==a (finite / NaN-quieted)               | PASS |
| `bmc_div_e5m2.sby` | (5,2) | same division laws                                   | PASS |
| `bmc_div_b16.sby`  | (5,10)| same division laws at binary16 (2^32 pairs)          | PASS |

`make formal` runs all eight (needs the oss-cad-suite `sby`/`yosys`). The
harness was validated against a deliberately false property (it reports FAIL
with a counterexample), so the passes are not vacuous.

> **Arithmetic-op proofs unblocked (item 3).** The arithmetic and division
> laws now PROVE at the 8-bit widths (and division at binary16). The earlier
> "write_smt2 corruption" diagnosis (bug 23) was a red herring: the properties
> themselves were subtly wrong, not the SMT model. `write_smt2` (yosys 0.68)
> is faithful — the "spurious counterexamples" were legitimate IEEE cases the
> laws failed to guard: first-NaN payload propagation breaks `add`/`mul`
> commutativity when both operands are NaN; `-0 + +0 = +0` breaks `a + 0 == a`
> for `a = -0` and `fma(a,b,0) == mul(a,b)` for opposite-sign-zero/infinity
> products; a quiet-NaN's sign is not preserved by the arithmetic ops. The
> laws are now guarded for exactly those cases (see the STATUS header in
> `formal/fp_arith_props.sv`). The full 8-bit family is additionally verified
> bit-exact by the regression and the exhaustive sweep. binary16 arithmetic is
> infeasible for the SMT solver in reasonable time (2^32 pairs with the fma
> wide accumulator), so the arithmetic laws are proven at E4M3/E5M2 only;
> division, which closes instantly, is proven through binary16.

## Bugs found and fixed during development

1. **`$signed(a_exp)` misread exponent fields ≥ 2^(W_EXP-1)** as negative.
   Fix: plain `a_exp - BIAS` (unsigned field promoted by signed 32-bit BIAS).

2. **Off-by-one size cast** `(W_EXP+2)'(...)` truncated the sign bit of
   `e_a`/`e_b`. Fix: cast to `(W_EXP+3)` bits.

3. **Alignment sticky never propagated** into `norm_sticky`. Fix: initialize
   `norm_sticky = align_sticky` at the top of the normalize block.

4. **Effective-subtraction sticky sign** — for opposite-sign adds, the
   alignment sticky must be *subtracted* (borrowed), not added. Fix: `mag =
   mag - 1` when `diff_sticky` is set (complement trick for GRS).

5. **Bogus sticky loop in left-normalize** — the loop `for (i < TARGET-p0)
   norm_sticky |= mag[i]` ORed the leading bit into the sticky. Fix: removed
   the loop (left-normalize loses no bits; the field is wide enough).

6. **`QUIET` 32-bit overflow** for W_MANT ≥ 32 (binary64). Fix: sized
   `localparam logic [MANT_W-1:0] QUIET = (MANT_W)'(1) << (MANT_W - 1)`.

7. **Reference-model RM rounding bug** — `_round_up` returned `True`
   unconditionally for `MODE_RM` regardless of sign. Fix: `return sign == 1`.

8. **Verilator 5.020 V3Gate internal fault at W_MANT = 0** — gate optimizer
   crashes on the generic datapath's subnormal block at 1-bit widths. Fix:
   dedicated `fp_add_e8m0.sv` module for W_MANT = 0, selected via `generate`
   in `fp_unit.sv`.

9. **Verilator 5.020 parse limitation** — replications with non-literal
   counts cannot appear as first/middle items in a concatenation. Fix:
   replaced `{(S_W-MANT_W){1'b1}, a_mant}` with `((S_W)'(1'b1) << W_MANT) |
   {1'b0, a_mant}`.

10. **Verilator equal-mtime pitfall** — patching `verilator.cpp` in the same
    second as the build caused `make` to skip recompilation. Fix: bump mtime
    by 2 seconds in the patch function.

11. **`gen.py` negative shift at W_MANT = 0** — `_mantissa(extreme=True)`
    computed `1 << (W_MANT - 1)`, raising `ValueError: negative shift count`
    in the random/boundary tests for E8M0. Fix: early `return 0` when
    `fmt.W_MANT == 0` (the only mantissa value is 0).

12. **E8M0 RP/RM rounding was sign-blind** — the `up` (round up to the larger
    magnitude) decisions in the same-sign d1/d2p and opposite-sign d2p cases
    treated RP/RM like RNE. RM of a negative result therefore rounded toward
    zero instead of −∞ (e.g. `-2^-50 + -2^-60` under RM gave `-2^-50` instead
    of `-2^-51`). Fix: `RP -> up iff rsign == 0`, `RM -> up iff rsign == 1`
    in all three rounding-decision sites of `fp_add_e8m0.sv`.

13. **E8M0 opposite-sign d1 never set `rsign`** — magnitude subtraction with
    exponent difference 1 gives the exact value `2^e_min` with the sign of the
    larger-magnitude operand, but `rsign` defaulted to `a_sign` (e.g.
    `2^-26 - 2^-25` gave `+2^-26` instead of `-2^-26`). Fix: `rsign = (e_a >=
    e_b) ? a_sign : b_sign_eff` in the d1 branch.

14. **Subnormal block `int unsigned shift` → 2^32-iteration loop** — the
    subnormal `always_comb` evaluates for every input, but its outputs are
    only selected when `e_res < EMIN`. `shift = EMIN - e_res` goes negative
    for a normal result and, as `int unsigned`, wraps to ~4.3 billion; the
    sticky loop `for (i < shift)` then iterated 2^32 times per normal-path
    transaction. This was the real cause of the "~2 s/transaction" slowness
    (not cocotb VPI overhead, as previously assumed). Fix: `int signed shift`
    plus a `shift > 0` guard. The full 8-width regression dropped from ~1 h
    to ~1 s.

15. **M2: product-exponent carry missing** — `e_res = e_a + e_b` was off by
    one whenever the significand product carried out of its own grid
    (`bitlen(P) == bitlen(s_a) + bitlen(s_b)`, i.e. two normal significands
    whose product is ≥ 2^(2·S_W-1)). Found by the binary16 regression
    (e.g. `-3.328 × 1002` came out as `-1667` instead of `-3334`). Fix:
    `e_res = e_a + e_b + (pbitlen(P) == bitlen(s_a) + bitlen(s_b))` in
    `fp_mul.sv`.

16. **M2: subnormal round-up past the largest finite never overflowed** — for
    the degenerate W_EXP = 1 range (EMIN = 1 > EMAX = 0, where every finite
    value is a subnormal and the smallest normal 2^emin = 2 already exceeds
    max finite 1.984), a subnormal product rounding up to the min normal must
    signal overflow per 7.4. Found by the exhaustive (1,6) sweep (80
    vectors, e.g. `1.031 × 1.9375 → 2`, flags `0x01` vs want `0x05`). The
    carry of the p-bit unbounded rounding is detected on the subnormal grid:
    RNE/RNA need guard+round (`gs & rs`), RP/RM (which round up for any
    inexact, by sign) need just the guard bit. Fix: an overflow
    saturation branch in the subnormal path's "round up to min normal" case
    when `EMIN > EMAX` (constant-false for all non-degenerate formats).

17. **M2: directed-vector encoding errors** (test bugs, caught against the
    RTL) — `(1+2^-m)^2 → 1+2^-(m-1)` is mantissa `2`, not `1 << (m-1)`;
    RP rounds a positive inexact result up (mantissa 3); `max sub × 2`
    encodes as `encode_finite(0, 1, maxm-1)` and is subnormal-only (E8M0 has
    no subnormals); the E8M0 half-2^emin tie needs `e_a + e_b = emin - 1`
    with `e_b = e_a - 1` (not `-2`).

18. **M3: no RTL bugs found — the division datapath passed the exhaustive
    sweep on its first run.** The only fixes were test/reference-side:
    - `1/(1+2^-m)`: on the [0.5,1) grid the value is `2^m - 2 + 2^-m` ulps,
      so RP rounds up to `1 - 2^-(m+1)`, not 1.0; the "below 1" encoding is
      `encode_finite(0, bias-1, 2^m - 2)`, not `(bias, 2^m - 1)` (which is
      `2 - 2^-m`).
    - The binary32 `2/3` vector had a stray hex digit (`0x3F2AAAAAB` vs
      `0x3F2AAAAB`); the generic `1/3` vector depends on `W_MANT` parity and
      was replaced by the `1/(1+2^-m)` family.
    - E8M0 division tie exponents: `e_a - e_b = emin - 1` with `e_b = e_a +
      emax` (not `+ emax + 1`).
    - The NaN directed vectors are meaningless for E8M0 (no NaN encodings)
      and the `div_close` pair generator shifted by `W_MANT-1` (guarded for
      `W_MANT = 0`).
    The divide algorithm itself (aligned-significand restoring division,
    `e_res = e_a - e_b - (a_al < b_al)`, remainder → sticky) matched the
    oracle across all 9,175,040 exhaustive vectors.

19. **M4: no RTL bugs found — the square-root datapath (digit-by-digit
    integer isqrt, `X = s_a << (2*TARGET + (e_a mod 2) - bitlen(s_a) + 1)`,
    `e_res = e_a >>> 1`, remainder → sticky) passed the exhaustive sweep on
    its first run.** The fixes were all test/reference-side:
    - `9.0` encodes as `encode_finite(0, bias+3, 1 << (m0-3))` (1.125·2^3),
      not `1 << (m0-1)` (that was 12.0 = 1.5·2^3).
    - The reference `_sqrt_round` initially used `p < q << (2*n)` which
      raises `ValueError: negative shift count` for tiny radicands (negative
      n); the exponent search now uses exact Fraction comparisons. It also
      needed `_round_up`, `encode_finite` and the underflow/overflow flag
      constants imported into `ops.py`.
    - The binary16 sqrt(2) vectors were guarded by `w == 16`, which also
      matches BF16 (1+8+7 = 16 bits) but whose 7-bit mantissa needs a
      different value; the guard is now `W_EXP == 5 and W_MANT == 10`.
    The reference sqrt uses exact integer arithmetic throughout (`_isqrt_scaled`
    plus squared-remainder comparisons against 0 and the half-way point), so
    ties (perfect-square radicands) are decided exactly, never approximated.

20. **M5: FMA and min/max bugs** (RTL and reference, all found by the
    exhaustive sweep / regression):
    - **fp_fma: `shift_c` placed c's LSB instead of its MSB** — the shift was
      `PTOP - top + e_c` rather than `PTOP - top + e_c - bitlen_c + 1`, so a
      c larger than the product lost its top bits (e.g. 1.0 × -1.997 + a
      huge negative c returned just the product). Fix: the LSB-shift formula.
    - **fp_fma: tiny sums (e_max below emin) went through the normal encoder**
      — the accumulator and add rounding are only valid above 2^emin; the
      module now has an explicit tiny branch (round to 0 or 2^emin) covering
      both same-sign and opposite-sign sums, with exact half-way handling
      (the only half-ulp is `2^e - 2^(e-1) = 2^(emin-1)`).
    - **fp_minmax: `{a_exp, a_mant}` magnitude key broke E8M0** — with
      W_MANT = 0 the 1-bit `a_mant` shifted the exponent field; the key is
      now `(exp << W_MANT) | mant`.
    - **fp_minmax: only the first NaN's sNaN flag was checked** — an sNaN in
      the second operand missed the invalid signal; both branches now use
      `a_snan || b_snan`.
    - **fp_fma_e8m0: c = 0 was treated as a tiny addend** — product + 0 must
      be exactly the product (with the overflow check); a `c_zero` branch was
      added, plus the tiny (0/2^emin) rounding that products below emin
      require (additions alone can never go below emin, but products can).
    - **Reference `_minmax` ordering key**: zeros decode to `v = None`, so the
      original sentinel key treated -0/+0 as ±infinity and used ±2 for
      infinities (finite values beyond ±2 broke the order); the key is now a
      `(rank, value)` tuple. The equal-zeros rule also had to branch on the
      class (`a_cls == ZERO`), not `a_v == 0`.
    - **Reference `fp_fma` NaN flags**: only the first NaN's sNaN was
      checked; now any of the three operands being an sNaN signals invalid.
    - Test-side: several directed-vector flag/encoding errors (e.g. `-0×2+0`
      is +0 under RNE, the E8M0 24-tie resolves to 2^5 = larger magnitude,
      and `2^2×2^2+2^2` = 20 rounds to 16 with inexact).

21. **M6: roundToIntegral encode and test bugs** (all found during
    development of comparisons/roundToIntegral/totalOrder):
    - **Integer re-encode was missing the (W_MANT - ey) left shift** — the
      normal encode stored `int_part - 2^ey` directly, but the fraction below
      the implicit bit is `(int_part - 2^ey) << (W_MANT - ey)`; with ey <
      W_MANT this encoded 2.0625 instead of 3.0 in the (2,5) format (both RTL
      and reference, found by a hand-checked reference sanity run). Fix: the
      left shift in `fp_roundint.sv` and `((y - 2^ey) << W_MANT) >> ey` in
      the oracle.
    - **Test: the 2.5 directed vector used the 0.5 mantissa bit** (`1 <<
      (m0-1)`, i.e. 3.0) instead of the 0.25 bit (`1 << (m0-2)`, i.e. 2.5);
      the RTL correctly returned 2.5 unchanged. Found by the (4,3) regression.
    - **Test: `1 << (m0-1)` helpers were unguarded for W_MANT = 0** — the
      `m3`/`snan`/`qnan` helpers raised `ValueError: negative shift count`
      at E8M0. Fix: compute 3.0 lazily behind the `m0 >= 2` guard and gate the
      NaN vectors on `W_MANT > 0`.
    - The comparison and totalOrder datapaths passed the exhaustive sweep on
      their first run; the roundToIntegral overflow corner (non-conforming
      emax < p-1 formats (1,6)/(2,5)/(3,4)) follows 7.4 and matched the oracle
      across all exhaustive vectors.

22. **M7: soak/formal harness and yosys-compat findings**:
    - **Yosys requires constant loop bounds and rejects `break`** — the
      generic datapaths' `for (i < runtime)` loops and `break` statements
      cannot be read by yosys (needed for the sby frontend). `fp_roundint`'s
      sticky loop (runtime `k` bound) and leading-bit loop (`break`) were
      rewritten as constant-bound loops (`for (i < S_W)` with a guard, and a
      last-set-bit-wins scan). Semantically identical — re-verified by the
      full regression and the exhaustive sweep. The other generic datapaths
      (add/mul/div/sqrt/fma) still use runtime loops and are not yet
      yosys-parsable.
    - **Soak harness bugs** (all harness-side, found against the RTL): (a) the
      expected record packed `y` as a single byte instead of `opbytes` (a
      16-bit result was truncated); (b) the C++ driver read `top->y` into a
      `uint8_t`, truncating binary16 results; (c) the driver never set
      `top->mode`/`top->rm`, so every vector silently ran as OP_ADD. Fixes:
      `opbytes`-wide `y` in the record, `uint64_t y`, and storing op/rm in the
      record.
    - **sby BMC `depth 0` does not check assertions** — a deliberately false
      property reported PASS (vacuous); `depth 1` is required and correctly
      produces a counterexample. The formal proofs run at depth 1 (the design
      is combinational, so depth 1 covers all inputs and actually checks).
      Also: yosys rejects `->` implication in `assert property` (rewrite as
      `!A || B`), and module instances must not share dummy output wires
      ("multiple drivers").

23. **M7 follow-up: yosys-compat refactor of the arithmetic datapaths, and a
    yosys 0.68 formal limitation**:
    - **Parseability refactor (delivered, verified)**: all five generic
      datapaths (fp_add/fp_mul/fp_div/fp_sqrt/fp_fma) plus fp_roundint now
      elaborate cleanly through yosys: `break` removed from every leading-bit
      scan (last-set-bit-wins loops), all runtime-bounded `for` loops made
      constant-bound, and every sticky-accumulation loop (`x |= v[i]`)
      replaced by a mask reduction `|(V & (2^n - 1))`. The full design
      (including fp_unit) passes `read_verilog` + `hierarchy` in yosys.
      Verified bit-exact after each change: `make lint`, the full 8-width
      regression (20/20) and the exhaustive sweep (25M vectors, 0 mismatches).
    - **Sticky-mask precedence bug** (found while refactoring, caught by the
      regression): in SystemVerilog additive `+`/`-` bind TIGHTER than shift
      `<<`, so `(P_W)'(1) << (B - FW) - 1` parsed as `1 << (B-FW-1)`; the
      explicit `((P_W)'(1) << (B-FW)) - 1` is required. Only one site lacked
      the parentheses; it dropped the inexact flag for some products.
    - **yosys 0.68 formal "write_smt2" bug — RESOLVED (item 3)**: the
      `setundef -undriven -anyseq` step sby runs after `prep` turns yosys's
      don't-care handling of `|=`-in-loop accumulations into free `anyseq`
      variables that leak into real logic, producing spurious counterexamples
      (e.g. `add(-0, +0)` reporting inexact). Removing all accumulation loops
      (mask reductions) brought the anyseq count to zero. A SECOND reported
      bug — `write_smt2` corrupting the SMT model when several instances of a
      parameterized datapath module connect their ports differently (a spurious
      counterexample claiming `add(7.5, -0.117)` and `add(-0.117, 7.5)` get
      different flags) — turned out NOT to be a yosys bug. Re-examining the
      counterexamples showed `write_smt2` was faithful: the failures were
      genuine IEEE cases the property laws failed to guard (both-NaN
      first-payload ordering, `-0 + +0 = +0`, the sign of a quiet-NaN result,
      and opposite-sign-zero products in `fma(a,b,0)`). With those laws fixed
      (see the STATUS header in `formal/fp_arith_props.sv`), the full
      arithmetic law set now proves at E4M3/E5M2 and division at
      E4M3/E5M2/binary16. `make formal` runs the M6 configs plus these.

## Format-specific notes

### E8M0 (W_MANT = 0, 1 sign + W_EXP exponent + 0 mantissa)

- IEEE 754-2025 microscaling shared-exponent format (all finite values are
  exact powers of two; no subnormals, no NaN encodings).
- `p = 1` tie rule (4.3.1): both candidates have significand 1.0 (odd), so
  `roundTiesToEven` delivers the larger magnitude. Implemented explicitly in
  `fp_add_e8m0.sv`.
- Rounding-direction handling for RP/RM is sign-dependent (see bug 12), and
  the opposite-sign d1 subtraction sign is fixed (bug 13); both were found by
  the E8M0 sim, which had never been run before.
- Invalid (inf + -inf, inf × 0, inf/inf, 0/0) → +infinity (no NaN encoding
  exists); documented in the modules and the reference (`encode_nan` returns
  `encode_inf(0, fmt)` when `W_MANT == 0`).
- **Multiplication** (`fp_mul_e8m0.sv`): the product 2^e_a × 2^e_b = 2^(e_a+e_b)
  is exact, but may leave the exponent range. Overflow (e_a+e_b > emax)
  saturates per attribute with overflow+inexact. Tiny results (e_a+e_b < emin)
  round to 0 or 2^emin with inexact only — underflow is never signaled
  (tininess after rounding; the rounded result is zero or the non-tiny
  smallest normal). The only tie is the exact value 2^(emin-1): RNE → 0
  (significand 0 even), RNA → 2^emin, RP/RM by sign.
- **Division** (`fp_div_e8m0.sv`): the quotient 2^e_a / 2^e_b = 2^(e_a-e_b)
  is exact, with the same overflow/tiny/rounding behavior as multiplication
  (the tie is again 2^(emin-1) with e_a - e_b = emin - 1). Division by zero
  (finite / 0) returns infinity with the divide-by-zero flag (7.3);
  0/0 and inf/inf are invalid (7.2f) → +infinity.
- **Square root** (`fp_sqrt_e8m0.sv`): sqrt(2^e) = 2^(e/2) is exact for even
  e; for odd e it is 2^((e-1)/2)·√2 with √2 ≈ 1.414 < 1.5, so RNE/RNA/RZ/RM
  round down to 2^((e-1)/2) and RP (positive) up to 2^((e+1)/2) — always
  inexact. The result always lies within the normal exponent range (no
  overflow/underflow). sqrt of a negative value is invalid (7.2g) → +infinity.
- **Fused multiply-add** (`fp_fma_e8m0.sv`): (2^e_a × 2^e_b) + 2^e_c =
  2^(e_a+e_b) + 2^e_c is an E8M0 addition of two powers of two with the
  product exponent — same p = 1 rounding rules as add. A zero `c` is an
  exact addend (the product alone, which can overflow); a sum below 2^emin
  (products can shrink below emin, additions cannot) rounds to 0 or 2^emin
  with the only half-ulp being `2^e - 2^(e-1) = 2^(emin-1)`. inf × 0 (7.2e)
  and inf + -inf (7.2d) are invalid → +infinity.
- `fp_add_e8m0.sv` has `/* verilator lint_off WIDTHEXPAND */` and
  `WIDTHTRUNC` (same as `fp_add.sv`) — int/width mixing in exponent
  arithmetic.
- **Comparison** (`fp_cmp.sv`, format-generic): no NaN encodings, so CMP_UN
  never occurs; -0 equals +0 (5.11). Powers of two compare by exponent then
  sign.
- **totalOrder** (`fp_totalorder.sv`, format-generic): the sign-magnitude key
  on the raw bits orders 2^e by exponent with -0 below +0 (5.10); never
  signals.
- **roundToIntegral** (`fp_roundint_e8m0.sv`): 2^e for e >= 0 is already
  integral (returned unchanged); 2^e for e < 0 lies in (0,1) and rounds to 0
  or 1 — the only tie is 2^-1 (RNE -> 0, RNA/RP (positive) -> 1, RM (positive)
  -> 0, and for negative operands RP -> -0, RM -> -1), with the sign of x
  preserved on a zero result. Never signals.

### BF16 (W_EXP=8, W_MANT=7)

- Standard bfloat16: bias 127, emax 127. No RTL changes needed — the generic
  `fp_add` handles it. Sim-verified (4/4).

### F8 E4M3 (W_EXP=4, W_MANT=3)

- Already in the original matrix and passing. No changes needed.

## How to run

```bash
# Default matrix (6 widths: b16, b32, b64, E4M3, BF16, E8M0)
uv run python tests/run_regression.py

# Full matrix (adds odd widths 6/16 and 10/40)
uv run python tests/run_regression.py --all

# Single width
uv run python tests/run_regression.py --width 8 0

# Exhaustive all-vectors check of all 7 eight-bit formats (~3-4 min total)
uv run python tests/exhaustive.py

# Exhaustive check of a single 8-bit format
uv run python tests/exhaustive.py --width 4 3

# Rebuild the exhaustive binary after RTL/harness changes
FORCE_REBUILD=1 uv run python tests/exhaustive.py --width 4 3

# Cross-width randomized soak (binary16, BF16, E4M3; 5M vectors each)
uv run python tests/soak.py
uv run python tests/soak.py --width 8 23 --vectors 10000000

# Formal BMC proofs of the M6 properties (needs the oss-cad-suite sby)
make formal
sby -f bmc_m6_b16.sby      # single config

# Lint only (generic datapaths + E8M0 modules, all -Wall clean)
make lint
```

The regression is now fast (~1 s for the full 8-width matrix at
`FP_ITERS=100`), so `FP_ITERS` can be raised freely for extra volume.

## What remains to do

### Immediate

- **Done**: M5 FMA + min/max (wide-accumulator single-rounding FMA, generic
  min/max, dedicated E8M0 FMA, reference oracles, directed/random tests,
  exhaustive all-8-op sweep). All five arithmetic ops plus min/max are
  implemented and bit-exact against the reference.
- **Done**: M6 comparisons, roundToIntegral, totalOrder (format-generic
  `fp_cmp`/`fp_totalorder`, generic + E8M0 `fp_roundint`, `op_t` widened to 4
  bits, new `cmp` output, reference oracles, directed/random tests, exhaustive
  all-11-op sweep).
- **Done**: M7 cross-width soak + formal (seeded random soak harness
  `tests/soak.py`/`soak_main.cpp` for the medium widths; SymbiYosys BMC
  property proofs of the M6 datapaths at binary16/E4M3/E7M0).

### Future milestones (from the original plan)

- **Coverage and formal depth**: Verilator line/toggle coverage is collected
  from the soak harness (`make coverage`, ~86% line coverage at the medium
  widths). The formal suite now includes the arithmetic-op and division laws
  (`make formal` runs 8 configs); the arithmetic laws at binary16 (2^32
  pairs, fma wide accumulator) remain too heavy for the SMT solver to close
  in reasonable time.

### Known limitations

1. **Flaky startup hang**: the retry loop in `run_regression.py` handles it,
   but it adds ~30% overhead on affected runs.

2. **No CI**: the regression is run manually. A GitHub Actions workflow or
   `Makefile`-driven CI would automate the full matrix + exhaustive sweep.

3. **No git baseline**: the repository has no commits yet; everything is
   untracked. Consider an initial commit before further milestones.

4. **Exhaustive harness caching**: `exhaustive_build/*` caches the Verilator
   binary and `expected.bin`; after RTL/reference changes, rebuild with
   `FORCE_REBUILD=1` and delete the stale `expected.bin` files (the binary
   reports "truncated expected file" when they are out of sync).

## File-level change summary (M5: FMA + min/max, vs. M4 square root)

| File | Change |
|------|--------|
| `rtl/fp_pkg.sv` | `OP_FMA = 3'd5`, `OP_MIN = 3'd6`, `OP_MAX = 3'd7` added to `op_t` (fills the 3-bit space) |
| `rtl/fp_fma.sv` | **New**: generic fused multiply-add (3p+6-bit exact-sum accumulator anchored at the larger leading exponent, operand tails below bit 0 captured as sticky, single GRS rounding; bugs 20) |
| `rtl/fp_fma_e8m0.sv` | **New**: E8M0 FMA (2^(e_a+e_b) + 2^e_c with the fp_add_e8m0 p=1 rules plus c=0 and tiny 0/2^emin handling) |
| `rtl/fp_minmax.sv` | **New**: generic minimum/maximum (NaN propagation, -0/+0 rule per 5.6.1, no rounding; format-generic, no E8M0 split) |
| `rtl/fp_unit.sv` | Add `c` input port; instantiate `fp_fma`/`fp_fma_e8m0` and `fp_minmax`; mux on OP_FMA/OP_MIN/OP_MAX |
| `tests/reference/ops.py` | `fp_fma` (3-operand specials incl. 7.2e/7.2d, exact `a*b+c`), `fp_min`/`fp_max` (5.6.1, tuple ordering keys) |
| `tests/test_fp_unit.py` | `OP_FMA/MIN/MAX`; `check()` drives `c`; `_directed_fma_vectors`/`_directed_minmax_vectors` + `test_directed_fma`/`test_directed_minmax`; `test_fma_random`/`test_minmax_random`; `test_random_mixed` dispatches all 8 ops |
| `tests/run_regression.py` | RTL list adds `fp_fma.sv`, `fp_fma_e8m0.sv`, `fp_minmax.sv` |
| `tests/exhaustive.py` | RTL list adds the fma/minmax files; expected generation loops over op ∈ {0..7}; FMA uses a fixed per-format `c` |
| `tests/exhaustive_main.cpp` | op loop 0..7; vector count 8·5·A·A; drives `top->c` from a CLI argument |
| `Makefile` | lint targets include `fp_fma.sv`/`fp_fma_e8m0.sv`/`fp_minmax.sv` |
| `README.md` | Document FMA (single rounding, c port) and min/max (5.6.1) semantics |
| `HANDOFF.md` | This document |

## File-level change summary (M6: comparisons, roundToIntegral, totalOrder,
vs. M5 FMA + min/max)

| File | Change |
|------|--------|
| `rtl/fp_pkg.sv` | `op_t` widened to `logic [3:0]`: `OP_CMP = 4'd8`, `OP_RNDINT = 4'd9`, `OP_TOTALORDER = 4'd10` added; `CMP_LT/CMP_EQ/CMP_GT/CMP_UN` localparams (the 2-bit `cmp` output encoding) |
| `rtl/fp_cmp.sv` | **New**: format-generic quiet comparison (5.11); magnitude-key ordering with -0 == +0, NaN unordered; `cmp[1:0]` condition code, `y` = 0; sNaN -> invalid only |
| `rtl/fp_totalorder.sv` | **New**: format-generic totalOrder (5.10); sign-magnitude type-pun key (`~a \| SIGN` for negatives) compared as signed two's complement; `cmp[0]` = a precedes-or-equals b (non-strict); never signals |
| `rtl/fp_roundint.sv` | **New**: generic roundToIntegral (5.9); NaN quieted with sign+payload, GRS rounding at the binary point, integer re-encode, 7.4 overflow corner, no inexact flag |
| `rtl/fp_roundint_e8m0.sv` | **New**: E8M0 roundToIntegral (2^e >= 1 unchanged; 2^e < 1 -> 0 or 1; 0.5 the only tie) |
| `rtl/fp_unit.sv` | `mode` now 4-bit `op_t`; new `cmp[1:0]` output; instantiate `fp_cmp`/`fp_totalorder` (both generate branches) and `fp_roundint`/`fp_roundint_e8m0`; mux the three new ops |
| `tests/reference/formats.py` | `CMP_LT/CMP_EQ/CMP_GT/CMP_UN` constants (sync with fp_pkg) |
| `tests/reference/ops.py` | `fp_cmp` (5.11, condition code), `fp_totalorder` (5.10, sign-magnitude key), `fp_roundint` (5.9, `_round_up` to an integer + 7.4 overflow corner) |
| `tests/test_fp_unit.py` | `OP_CMP/RNDINT/TOTALORDER` constants; `check()` compares the `cmp` output; `_directed_cmp_vectors`/`_directed_totalorder_vectors`/`_directed_rndint_vectors` + `test_directed_cmp/totalorder/rndint`; `test_cmp_random`/`test_totalorder_random`/`test_rndint_random`; `test_random_mixed` dispatches all 11 ops |
| `tests/run_regression.py` | RTL list adds `fp_cmp.sv`, `fp_totalorder.sv`, `fp_roundint.sv`, `fp_roundint_e8m0.sv` |
| `tests/exhaustive.py` | RTL list adds the four new files; op loop 0..10; expected records now 3 bytes `(y, flags, cmp)` |
| `tests/exhaustive_main.cpp` | op loop 0..10; vector count 11\*5\*A\*A; reads and compares the `cmp` byte |
| `Makefile` | lint targets include the four new modules |
| `README.md` | Document comparison (5.11), roundToIntegral (5.9), totalOrder (5.10), the `cmp` output |
| `HANDOFF.md` | This document |

## File-level change summary (M7: cross-width soak + formal, vs. M6)

| File | Change |
|------|--------|
| `rtl/fp_add.sv`, `rtl/fp_mul.sv`, `rtl/fp_div.sv`, `rtl/fp_sqrt.sv`, `rtl/fp_fma.sv`, `rtl/fp_roundint.sv` | Yosys compatibility: `break` removed from every leading-bit scan; runtime-bounded `for` loops made constant-bound; sticky-accumulation loops replaced by mask reductions (see bug 23). Semantics unchanged (re-verified by regression + exhaustive). |
| `tests/soak.py` | **New**: seeded random soak driver (boundary-biased operand pairs, all 11 ops, 5 rounding modes); writes `(a, b, y, flags, cmp, op, rm)` records to `soak_build/*/expected.bin`; builds and runs the C++ harness |
| `tests/soak_main.cpp` | **New**: replay the soak vector stream through `fp_unit` and compare against the oracle records |
| `formal/fp_m6_props.sv` | **New**: width-parameterized formal properties for fp_cmp (antisymmetry, NaN-unordered, -0==+0, sNaN-invalid), fp_totalorder (reflexive/total/antisymmetric/transitive, -0<+0, agreement with LT), fp_roundint (idempotent, sign-preserving, specials, no-inexact) plus min/max cross-checks; concrete binary16/E4M3 wrappers |
| `formal/fp_m6_props_e8m0.sv` | **New**: E8M0 (W_MANT=0) formal properties for fp_roundint_e8m0 (idempotent, sign-preserving, integral powers unchanged, no flags) and the format-generic fp_cmp/fp_totalorder; E7M0 wrapper |
| `formal/fp_arith_props.sv` | **New**: parameterized property module for the arithmetic laws (add/mul/fma/sqrt identities, commutativity, sub=add-sign-flip); guards added for NaN-payload / zero-sign edge cases, **proven** at E4M3/E5M2 (see bug 23) |
| `formal/fp_div_props.sv` | **New**: parameterized division laws (a/a==1, a/1==a); **proven** at E4M3/E5M2/binary16 |
| `bmc_m6_b16.sby`, `bmc_m6_e4m3.sby`, `bmc_m6_e7m0.sby` | SymbiYosys BMC configs (`smtbmc`, depth 1) for the M6 proofs |
| `Makefile` | `soak` and `formal` targets (the latter runs the M6 configs with the oss-cad-suite `sby`) |
| `.gitignore` | Ignore `soak_build/` and the sby `bmc_*_bmc/` work dirs |
| `README.md` | Document the soak and formal targets |
| `HANDOFF.md` | This document |
