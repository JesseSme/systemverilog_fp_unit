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
  latency_main.cpp    Per-op in_valid -> out_valid cycle-count harness
  latency.py          Driver: per-format latency table (make metrics-latency)
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
  fused multiply-add, minimum/maximum (754-2019 9.6), quiet comparison (5.11),
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
  per 754-2019 9.6).
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

- **Microarchitecture**: (superseded) the unit is now fully pipelined with
  fixed per-op latencies; see the optimization-pass notes below and
  IMPROVEMENT_PLAN.md for the remaining interface work.

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

**Pipeline equivalence** (`make formal-equiv`, `formal/fp_pipe_equiv.sv`):
`fp_add_pipe` / `fp_mul_pipe` against the combinational `fp_add` / `fp_mul`
on the same free a/b/rm/op stream (start free every cycle), reference
delayed by the latency, BMC depth latency + 2 (reset, issue, drain).

| Config | Width | Result (bitwuzla) |
|--------|-------|-------------------|
| `bmc_equiv_add_e4m3.sby` / `bmc_equiv_mul_e4m3.sby` | (4,3) | PASS, < 1 s |
| `bmc_equiv_add_bf16.sby` / `bmc_equiv_mul_bf16.sby` | (8,7) | PASS, 4 s / 14 s |
| `bmc_equiv_add_b16.sby` | (5,10) | PASS, 10 s |
| `bmc_equiv_mul_b16.sby` | (5,10) | PASS, 12-13 min |

Validated with RTL mutants (a one-bit output flip for one result value in
`fp_add_pipe`, at E4M3 and binary16): both FAIL at step 4 with a
counterexample.

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
  by `make coverage`, which runs a 1M-vector soak at the medium widths plus an
  E8M0 soak and the full exhaustive all-8-bit-format sweep, then merges and
  annotates every module. Refreshed 2026-11-04 (plan P4.4) after Phases 0-4,
  from the default and `DIVSQRT_IMPL=3` soak (binary16, BF16, E4M3, E8M0,
  binary64) and exhaustive builds plus the iterative-engine (`--iter`)
  exhaustive and soak, merged from fresh runs only. Line coverage (lines
  hit at least once, from `coverage.info`):

  | module | lines | % | module | lines | % |
  |--------|------:|--:|--------|------:|--:|
  | fp_add_pipe | 332/349 | 95.1 | fp_mul_pipe | 289/314 | 92.0 |
  | fp_mul_core | 78/85 | 91.8 | fp_fma_pipe | 474/553 | 85.7 |
  | fp_div_srt | 363/403 | 90.1 | fp_sqrt_srt | 504/573 | 88.0 |
  | fp_divsqrt_iter | 318/348 | 91.4 | fp_roundint_pipe | 127/144 | 88.2 |
  | fp_misc_pipe | 98/100 | 98.0 | fp_minmax_pipe | 58/59 | 98.3 |
  | fp_cmp_pipe | 62/66 | 93.9 | fp_totalorder_pipe | 18/23 | 78.3 |
  | fp_unit | 94/101 | 93.1 | fp_*_e8m0 (6 modules) | 453/474 | 91.5-98.3 |
  | **total** | **3268/3592** | **91.0** | | | |

  (`verilator_coverage --annotate` reports 62 % because it counts a point as
  covered only at >= 10 hits and includes toggle points.) The remaining
  gaps are mostly defensive / constant-generate paths unreachable even by
  the exhaustive sweep (e.g. the `W_MANT > 0` guard inside the generic
  datapaths, which is always true when they are instantiated, and the
  DPS/FOLD_STG/STAGE_FOLD branches a given build does not select).
  `make coverage` now deletes old `coverage.dat` files first: merging data
  from build directories it does not rerun (e.g. `*_iter`) mixed in stale
  line numbers (an unfiltered merge today read 84.9 %). The formal suite runs 8 configs; the arithmetic laws
  at binary16 (2^32 pairs, fma wide accumulator) remain too heavy for the SMT
  solver to close in reasonable time.

### Optimization pass (area/Fmax + measurement infra)

`tests/metrics.py` (+ `make metrics-area|metrics-runtime|metrics-compare`)
measures yosys `synth -noabc` generic-gate cell counts and `ltp` logic-level
depth per format, and times the standard make targets. Baselines live in
`metrics/area-baseline.json` / `metrics/runtime-baseline.json`; each
optimization captures `metrics/area-after*.json` and diffs with
`uv run python tests/metrics.py --compare BEFORE AFTER`. Notes:

- `synth -noabc` is used because abc does not close on the combinational
  divider/square root at binary32 (it ran >10 min on fp_sqrt alone).
- Landed: `fp_sqrt` takes its sticky bit from the isqrt remainder instead of a
  second squaring multiply (-25..28% cells); `fp_fma` normalize no longer
  re-assigns `e_res` per branch.
- Landed: `ITER_DIVSQRT` (default 0), selecting the shared multi-cycle
  `fp_divsqrt_iter` engine in `fp_unit`/`fp_unit_axilite` with an
  in_valid/out_valid handshake. binary32 unit: 63,685 -> 38,988 cells (-39%),
  critical path from fp_div's 965 levels to fp_fma's 324; the engine itself is
  7,513 cells / ltp 94.
- Landed: the engine is radix-4 (two quotient/root bits per cycle) with the
  top digit precomputed in the start cycle and a radix-2 half-step for odd
  W_MANT. The div/sqrt latency is CONSTANT for every input, including special
  cases: K+1 cycles with K = floor((W_MANT+3)/2) (binary32: 14, binary64: 28,
  vs 52/29 and 110/58 before). The fp_unit output register is bypassed for
  engine results and the engine accepts a new start in the done cycle, so
  back-to-back div/sqrt have no dead cycle. The `--iter` harnesses now assert
  these cycle counts on every vector (latency errors reported separately).
  Verified bit-exact + constant-latency by `tests/exhaustive.py --iter`
  (all 7 eight-bit formats), `tests/soak.py --iter` (binary16/BF16/E4M3) and
  the AXI-Lite tests with `FP_ITER_DIVSQRT=1`.
- Rejected after measurement: replacing `rem = num % b_al` with
  `num - q_raw*b_al` (+14% cells) and an unrolled restoring divider for `/`
  (+46% cells, +105 ltp levels). `$clog2`-based parallel leading-zero counts
  are not viable on yosys 0.68 (non-constant `$clog2` is unsupported) and loop
  accumulators are formal-hostile (see the fp_add notes).
- Landed (Fmax pass, 250 MHz on xcvu9p-flga2104-2L-e): all generic-format
  operations are now pipelined with fixed per-op latencies (add/sub/mul 5,
  fma 9, roundint 3, min/max/cmp/totalOrder 2, div/sqrt 2K+3 cycles). New
  modules: fp_add_pipe, fp_mul_pipe + fp_mul_core (LUT-only pipelined
  multiplier, zero DSP inference), fp_fma_pipe, fp_roundint_pipe,
  fp_minmax_pipe, fp_cmp_pipe, fp_totalorder_pipe; fp_divsqrt_iter now runs
  two cycles per radix-4 digit step with a two-phase preload; fp_unit is a
  per-op start/out_valid dispatcher. Measured with the single non-project
  Vivado run (now `syn/vivado-impl.tcl`, `synth_design -mode
  out_of_context` + place/route on a 4.000 ns clock): WNS +0.022 ns, 0
  failing endpoints, 6994 LUTs, 2625 FFs, 0 DSPs. The harnesses assert
  constant per-op latency on every vector; fp_exp_seq was re-sequenced to
  issue one operation at a time and wait for out_valid (~110 cycles per exp).
- Landed (latency pass, 250 MHz re-closed on xcvu9p-flga2104-2L-e): the
  fixed per-op latencies were cut while every stage stays inside the 4.000 ns
  clock. New latencies (binary32): add/sub 3, mul 4, fma 8, div/sqrt 17,
  rndint 2, min/max/cmp/totalOrder 1 (binary64: mul 5, fma 9, div/sqrt 31;
  binary16 div/sqrt 10; E8M0 stays 1 cycle). Changes:
  * add/sub 5 -> 4: normalize and round/encode are fused into one stage; the
    subnormal candidate is shifted directly from the pre-normalization sum by
    (e_max - EMIN), which is independent of the leading-one position, and is
    computed/registered in the add stage, so the normalize/round stage only
    carries the normal path.
  * add/sub 4 -> 3 (3-stage pipeline): S1 unpack/classify + per-operand
    signed alignment shifts; S2 single bidirectional shift per operand +
    sign-magnitude add/sub; S3 normalize + round/encode. Key points: the
    subnormal bit length is scanned on the mantissa bits (the leading-one
    scan no longer waits for the significand mux); the alignment shift
    amounts are converted in S1 into clamped direction-split selects (S2's
    shifter sees short registered selects); the alignment sticky is folded
    into the subtractor carry-in and the two difference directions are
    computed in parallel, selected by the borrow; the subnormal placement
    shift amounts and the special/cancel bypass are registered in S2; the
    rounding increment, exponent and overflow candidates are computed in
    parallel with the GRS decision (carry-select). All three stages land at
    <= 3.85 ns, so the add pipe is no longer the critical path.
  * mul 5 -> 4 (significand width S_W = W_MANT+1 <= 32): fp_mul_core uses 2 stages for S_W <= 32 (the final
    carry-propagate level is folded into the last tree stage) and keeps 3 for
    binary64; FMA inherits the shorter core (8 cycles for W <= 32, 9 for
    binary64).
  * div/sqrt: one radix-4 digit per cycle (the digit-select compare, the
    multiple mux and the remainder subtraction are fused into one registered
    step) plus a publish cycle: latency K+4 with K = floor((W_MANT+3)/2)
    (binary32 29 -> 17, binary64 57 -> 31). The restoring recurrence is
    unchanged, so bit-exactness is structural. The publish cycle rounds the
    *registered* quotient/root and remainder: reading the step's next-state
    values (q_b/rem_b) re-enters the digit-step path in static timing and cost
    ~1 ns of slack in the first attempt.
  * roundToIntegral 3 -> 2 (prepare/GRS/round fused); min/max/cmp/totalOrder
    2 -> 1 (compare/select + a single register stage).
  * New `tests/latency.py` + `tests/latency_main.cpp` (`make metrics-latency`):
    per-op in_valid -> out_valid cycle probe over normal/subnormal/zero/inf/
    NaN vectors; asserts a constant per-op latency and writes
    metrics/latency-after.json (baseline: metrics/latency-before.json).
  Measured (final, after the 3-stage add): WNS +0.015 ns, 0 failing endpoints
  (2897), 6992 LUTs, 2188 registers, 0 DSPs. The critical path is the FMA
  round/encode stage again (as in the Fmax pass); the add stages measure
  ~3.35 ns (S1), ~3.61 ns (S2 sticky select) and ~3.85 ns (S3 normalize/
  round). Verified after the pass: `make regress`, `make regress-all` (8
  widths), `make regress-axilite`, `make exhaustive-iter` (all 7 eight-bit
  formats, 25.2M vectors), `make soak-iter` (15M vectors at binary16/BF16/
  E4M3), plus the latency probe; every op keeps a constant per-op latency
  across the streams. (Note: the exhaustive sweep caught a width bug in the
  first subnormal-amount precompute - the clamped amounts need SUM_W range,
  not the narrower alignment widths.)
- Landed (FMA latency + streaming pass, 250 MHz re-closed on xcvu9p-2L):
  binary32 fma 8 -> 7, div/sqrt 17 -> 16 (binary64 fma 9 -> 8, div/sqrt
  31 -> 30; E4M3 div/sqrt 7 -> 6, E5M2 6 -> 5, BF16 9 -> 8, binary16
  10 -> 9). Changes:
  * fp_fma_pipe: the subnormal-candidate shift is computed from the
    pre-normalization accumulator (the fp_add_pipe placement-ahead trick):
    value = acc * 2^(top_f3-PTOP), so the shift to the subnormal grid is
    W_MANT+3+top_f3-PTOP-EMIN and does not depend on the leading-one
    position. That removed the F5 variable shifter from the critical path
    (Vivado WNS +0.015 -> +0.023; critical path moved from F5 to F1). The
    product/c placement stickies are not in acc and must feed the subnormal
    sticky directly (caught by the differential harness).
  * fp_fma_pipe: with the subnormal shift precomputed in F4, F5a/F5b merge
    into one round/encode stage; FMA 8 -> 7 (W <= 32), 9 -> 8 (binary64).
    WNS +0.009 ns (the mul round/encode is then the critical path).
  * fp_fma_pipe: the F1 context is pipelined s1 -> s2 -> s3 and selected by
    the core latency (CORE_TWO_STAGE), fixing back-to-back start streams
    exactly like the fp_mul_pipe M1 fix (was ~99% wrong at binary32 with one
    start per cycle; the one-transaction-at-a-time harness never caught it).
    WNS +0.090 ns.
  * fp_divsqrt_iter: classification/significands/exponents resolve in the
    start cycle (former IDLE+PREP1 merged; the raw-input latch is gone), so
    the setup is one cycle shorter: K+4 -> K+3. WNS +0.043 ns; the radix-4
    digit step (pos -> rem, 3.939 ns) is now the critical path.
  * Rejected at the 4.000 ns clock (measured, not merged):
    - FMA F1+F2 merge with product-MSB anticipation (pbitlen =
      bl_a+bl_b-1+P[bl_a+bl_b-1] => prod_top = e_a+e_b+msb): -0.866 ns, 308
      failing endpoints (patch archived at
      /tmp/opencode/a3-f1f2-merge-attempt.patch; no longer available).
    - div/sqrt publish folded into the last step, and the preload merged into
      the start cycle (K+1): functionally correct (exhaustive/soak PASS) but
      -0.674 ns.
  * New scratch harnesses (/tmp/opencode/fma_diff, lost; superseded by
    the fp_unit-level streaming test `tests/stream.py`): differential vs the
    combinational fp_fma (one-at-a-time: 2M x 6 formats plus 30M at binary32
    and 10M at binary64 across seeds) and streaming (one start per cycle with
    FIFO-tracked operands); both 0 mismatches. Worth promoting into tests/.
- Landed (DIV/SQRT SRT rework, at a relaxed 5.600 ns clock): the generic
  div/sqrt datapaths are now fully unrolled radix-4 SRT pipelines
  (`fp_div_srt`, `fp_sqrt_srt`), carry-save remainder, one start per cycle
  (fixed latency NSTG+2), functionally verified bit-exactly.
  Latencies: div 9 (binary32) / 17 (binary64) / 6 (binary16) / 5 (BF16) /
  4 (E4M3, E5M2); sqrt 15 / 29 / 8 / 7 / 5 / 4. This required relaxing the
  operating clock from 4.000 ns to 5.600 ns (178.6 MHz); the previously
  instantiated `fp_divsqrt_iter` (K+3) and the legacy combinational
  `fp_div`/`fp_sqrt` remain in-tree for reference and `ITER_DIVSQRT = 0`.
  (The measured latencies above are authoritative; an earlier draft of this
  note listed sqrt 9/16/5/5/4/3 from a 2-digit/stage experiment that was not
  landed.) `fp_unit` now runs both on SRT pipelines for generic
  formats (`ITER_DIVSQRT != 0`); `fp_divsqrt_iter` is no longer instantiated
  (kept in-tree for reference/fallback), the legacy combinational
  `fp_div`/`fp_sqrt` remain for `ITER_DIVSQRT = 0` and formal.
  * Division digit selection: QST with 4 thresholds per divisor cell
    (16 cells of 1/32), estimate floor(64R) from the carry-save top bits
    (one-sided 0/1 underestimate; the cell was widened on the upper side to
    cover it). u0 = a_al, u' = 4u - 4*d*Den, d in {-2..2}; on-the-fly Q/QM
    absorbs negative digits; the final sign correction picks Q or QM.
  * Sqrt digit selection: Xp is zero-padded (PAD=2 for even S_W) so every
    step consumes 4 radicand bits; d in {-4..4}; the non-restoring invariant
    |R| <= 2q makes the digit intervals overlap by a full step, so the digit
    is round(p/(8q)) computed from the carry-save estimate by 8 threshold
    comparisons q*(8k+4). Negative digits again use Q/QM; the PAD bit folds
    into the sticky.
  * Both: the carry-save pair is folded with a small CPA at each stage
    boundary. This was essential: without folding, exact divisions make the
    representation drift to ~S_W+3n bits (140 bits at binary64); folding
    bounds it to ~S_W+8.
  * Verification: new streaming differential harnesses (one start/cycle,
    FIFO-tracked operands) vs the combinational fp_div/fp_sqrt, 11 widths x
    300k vectors each (0 mismatches, plus 1M at binary32); exhaustive-iter
    and soak-iter; the QST/sqrt tables were derived by exhaustive interval
    analysis and the recurrences validated bit-exactly in Python
    (now `verification/srt/div_model.py`, `sqrt_model.py`).
  * Gotchas found: (a) the setup block must not reset the stage registers
    (multi-driven in synthesis - the divider was silently pruned);
    (b) signed casts are needed around all digit arithmetic (unsigned size
    casts zero-extend and corrupt negative digits); (c) the first-digit
    radicand slice is RE-5-4t, not RE-8-4t; (d) the small-q first-digit
    logic must be instantiated once (as a table), not per digit (215k ->
    36k cells, -34 ns -> -5.4 ns).
  * TIMING OUTCOME: at the old 4.000 ns clock the packed stages measure
    5.4-5.6 ns (logic 2.2-2.8 ns, route 2.7-3.2 ns; route-dominated) and
    fail by 1.4-2.2 ns; ExtraTimingOpt and a pblock recovered only ~0.1 ns.
    The clock was therefore relaxed and bisected with full implementation
    runs (5.550 ns fails -0.066; 5.580 ns passes exactly; 5.600 ns +0.055;
    5.700 ns +0.042), settling on 5.600 ns = 178.6 MHz with margin.
    Sqrt uses 1 digit/stage (its q-dependent d(8q+d) term does not fit 2
    digits/stage even at 5.6 ns: a 2-digit sqrt stage measured 9.4 ns);
    division packs 2 digits/stage. The non-div/sqrt pipelines have large
    positive slack at 5.600 ns.
  * Trade-off: in cycles div improves 16 -> 9 and sqrt 16 -> 15 (binary32),
    but the clock drops 250 -> 178.6 MHz, so in wall-clock terms division
    improves (64 -> 50 ns), sqrt is roughly flat-to-worse (64 -> 84 ns) and
    all other operations are ~1.4x slower. The previous 250 MHz design is
    the parent commit if overall throughput matters more.
- Still open: at the 5.600 ns operating point the div/sqrt SRT stages set
  the clock (division 5.53 ns, sqrt 5.56 ns); a 4:2-compressor carry-save
  update (removing the per-stage fold) or radix-8 at one digit/stage are the
  routes to close 4.000 ns again. The add pipe's S3 critical path would need
  leading-zero anticipation / far-near split for further add latency cuts;
  `fp_fma`'s `ACC_W = 3*S_W+6` accumulator width (needs an exactness proof);
  operand isolation/clock gating for power (needs a toggle power proxy), and
  the E8M0 module duplication (E8M0 ops remain 1-cycle combinational).

### Known limitations

1. **Flaky startup hang**: the retry loop in `run_regression.py` handles it,
   but it adds ~30% overhead on affected runs.

2. **No CI**: the regression is run manually. A GitHub Actions workflow or
   `Makefile`-driven CI would automate the full matrix + exhaustive sweep.

3. **Environment: GNU make must win over the Siemens Catapult make** on PATH
   (`/usr/local/bin/Siemens_EDA/.../make`), otherwise verilator's `--build`
   and the cocotb runner fail with "Process 'make' terminated with error 2".
   `tests/metrics.py` pins `/usr/bin:/bin` ahead of PATH for its subprocesses;
   interactive runs may need the same.

4. **Harness caching**: `exhaustive_build/*` / `soak_build/*` cache Verilated
   binaries and `expected.bin`, keyed by a content stamp over the RTL,
   reference oracle and harness; `FORCE_REBUILD=1` remains as a manual
   override. `--iter` builds live in separate `*_iter/` build dirs.

## File-level change summary (M5: FMA + min/max, vs. M4 square root)

| File | Change |
|------|--------|
| `rtl/fp_pkg.sv` | `OP_FMA = 3'd5`, `OP_MIN = 3'd6`, `OP_MAX = 3'd7` added to `op_t` (fills the 3-bit space) |
| `rtl/fp_fma.sv` | **New**: generic fused multiply-add (3p+6-bit exact-sum accumulator anchored at the larger leading exponent, operand tails below bit 0 captured as sticky, single GRS rounding; bugs 20) |
| `rtl/fp_fma_e8m0.sv` | **New**: E8M0 FMA (2^(e_a+e_b) + 2^e_c with the fp_add_e8m0 p=1 rules plus c=0 and tiny 0/2^emin handling) |
| `rtl/fp_minmax.sv` | **New**: generic minimum/maximum (NaN propagation, -0/+0 rule per 9.6, no rounding; format-generic, no E8M0 split) |
| `rtl/fp_unit.sv` | Add `c` input port; instantiate `fp_fma`/`fp_fma_e8m0` and `fp_minmax`; mux on OP_FMA/OP_MIN/OP_MAX |
| `tests/reference/ops.py` | `fp_fma` (3-operand specials incl. 7.2e/7.2d, exact `a*b+c`), `fp_min`/`fp_max` (9.6, tuple ordering keys) |
| `tests/test_fp_unit.py` | `OP_FMA/MIN/MAX`; `check()` drives `c`; `_directed_fma_vectors`/`_directed_minmax_vectors` + `test_directed_fma`/`test_directed_minmax`; `test_fma_random`/`test_minmax_random`; `test_random_mixed` dispatches all 8 ops |
| `tests/run_regression.py` | RTL list adds `fp_fma.sv`, `fp_fma_e8m0.sv`, `fp_minmax.sv` |
| `tests/exhaustive.py` | RTL list adds the fma/minmax files; expected generation loops over op ∈ {0..7}; FMA uses a fixed per-format `c` |
| `tests/exhaustive_main.cpp` | op loop 0..7; vector count 8·5·A·A; drives `top->c` from a CLI argument |
| `Makefile` | lint targets include `fp_fma.sv`/`fp_fma_e8m0.sv`/`fp_minmax.sv` |
| `README.md` | Document FMA (single rounding, c port) and min/max (9.6) semantics |
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

## Change summary (IMPROVEMENT_PLAN.md, branch improve/plan, 2026-11-03)

| Task | Change |
|------|--------|
| T0.1 | `rtl/filelist.f` / `filelist_wrappers.f` are the only RTL lists (`tests/rtl_files.py`, Makefile `$(RTL)`, `syn/`); `tests/reference/formats.py` owns the op table (`OP_*`, `OP_NAMES`, `NUM_OPS`); `ops.dispatch()` is the single op -> oracle map; C++ harnesses take `-DNUM_OPS` |
| T0.2 | README/HANDOFF stale statements fixed (pipelined, formal status, 9.6 citations, SRT sqrt latencies, lost /tmp paths) |
| T0.3 | `syn/fp_unit_timing.sv` + `syn/vivado-impl.tcl` (`make vivado`) replace the old script whose wrapper lived in /tmp |
| T0.4 | AI-session transcripts no longer versioned |
| T1.1 | **fp_unit `in_ready` + `in_tag`/`out_tag` + result-port reservation**: two in-flight ops finishing in the same cycle used to lose one result silently. Latencies come from `fp_pkg::lat_*`; simulation asserts `out_valid == resv[0]` and one-hot pipeline valids |
| T1.2 | `tests/stream.py` (`make stream`): request every cycle, results matched by tag; same-op (every pipeline streams, 0 stalls) and mixed-op modes |
| T1.3 | `fp32_to_bf16_round` no longer turns NaNs whose payload is in the low 16 bits into Inf, and quiets sNaN; exhaustive 2^32 test (`make bf16`) |
| T1.4 | `fp_exp_seq` tested (`make regress-exp`); real accuracy documented (~45 ulp for abs(x) <= 8, ~1.3k ulp near 16, not the claimed 1e-6) |
| T1.5 | rm 5-7 behave as RNE everywhere; reserved/disabled opcodes return y = 0 + invalid |
| T2.1 | `ITER_DIVSQRT` replaced by `DIVSQRT_IMPL` (1 SRT default, 2 iterative engine = the 250 MHz build, 0 combinational); iterative latency is floor((W_MANT+3)/2)+3 (the engine header said ceil); `--divsqrt`/`--iter` harness flags, `*-iter` make targets test the iterative engine |
| T2.2 | `OPS_EN` op-enable mask; `fp_exp_seq` builds only MUL and ADD/SUB |
| Phase 3 | New ops filling codes 11-15: OP_SGNJ (5.5.1), OP_CLASS (5.7.2), OP_NEXT (5.3.1), OP_MINMAXNUM (9.6), OP_RNDINTX (roundToIntegralExact). `rtl/fp_misc_pipe.sv` (1 cycle, format-generic incl. E8M0); `fp_roundint_pipe`/`fp_roundint_e8m0` gain an `exact` input. Oracles checked against brute-force enumeration on every 8-bit format; hand-written directed vectors; exhaustive sweep now 16 ops |
| fp_pkg | Package functions assign their name instead of `return` (yosys 0.68, used by `make formal`, cannot parse `return`) |

## Change summary (Phase 3.3 + Phase 4, branch improve/plan, 2026-11-04)

| Task | Change |
|------|--------|
| Vivado | Re-measured with Vivado 2026.1.1 (`/media/lfs/2026.1.1`), xcvu9p-2L, binary32, before the Phase 4 changes: `DIVSQRT_IMPL=1` 5.6 ns WNS +0.056, 13,488 LUTs; `=2` 4.0 ns +0.066, 7,368 LUTs. The Phase 0-3 interface work cost no Fmax |
| P4.1 | **Fixed-width carry-save SRT** (`fp_div_srt`, `fp_sqrt_srt`): S, C modulo 2^CSW (div S_W+4, sqrt 2*NDIG+5) instead of a carry-propagate fold at every stage (models first: `verification/srt/*_model.py`, exhaustive at small widths). Sqrt's `bits - d(8q+d)` (three chained CPAs) became two 3:2 levels using {q, d} / {qm, 8-abs(d)}; its threshold arithmetic is 6-bit / 13-bit (ranges checked in the model). New parameters `STAGE_FOLD`, `FOLD_STG`; the div round stage takes precomputed exponent decisions. New **`DIVSQRT_IMPL=3`** (DPS 1, FOLD_STG): fully pipelined div/sqrt at **4.0 ns** (+0.001, 13,368 LUTs), div 17 / sqrt 16 cycles at binary32. The default `=1` improves to +0.131 ns at 5.6 ns with 12,656 LUTs (-830) |
| sqrt bug | `fp_sqrt_srt` `thr_digit`: the compare counter was 3 bits, so all 8 compares true (digit +4) wrapped to digit -4. Found by the SRT differential at DPS=2 (1 in 5M binary64 / (10,40) radicands on the old RTL); not reached through the old `fp_unit` (sqrt DPS 1 with a fold per digit gives an exact estimate), but reachable once the fold is removed. Fixed (4-bit counter); directed binary64 / (10,40) vectors in `test_directed_sqrt` (they fail with the old counter on the new RTL) |
| P4.3 | Formal equivalence add/mul pipe vs combinational reference (table above), `make formal-equiv` |
| P4.2 | Not attempted: every `fp_add_pipe` stage is near the clock (S1 alone +0.279 ns at 5.6 ns, +0.016 at 4.0), so a 2-cycle add needs a dual-path (near/far) adder with LZA, a full redesign rather than a stage merge. Ask the owner whether it is worth it (add 3 -> 2 cycles) |
| 3.3 | Design notes in `docs/proposals/` (signaling compare, integer and format conversions, scaleB/logB, remainder) with the shared 5-bit opcode decision; nothing implemented |
| tools | `syn/vivado-module.tcl` (one module OOC); `vivado-impl.tcl` writes the routed checkpoint and a hierarchical utilization; `run_diff.py --param`; `make check-ds3`; harnesses accept `--divsqrt 3` / `FP_DIVSQRT_IMPL=3` |

## Change summary (Verilog/VHDL tops + core documentation, 2026-11-04)

| Item | Change |
|------|--------|
| tops | `rtl/top/`: `fp_unit_top.v` and `fp_unit_axilite_top.v` (Verilog-2001, integer parameters, X_INTERFACE attributes for clock/reset/S_AXI), `fp_unit_vhd.vhd` and `fp_unit_axilite_vhd.vhd` (VHDL-93, integer generics, instantiate the Verilog tops), `fp_unit_flat.sv` (casts plain vectors to fp_unit's enum ports; `OPS_EN` as an integer). Lists: `filelist_wrappers.f`, new `filelist_vhdl.f` |
| AXI bug 1 | `fp_unit_axilite`: in W_RESP/R_DATA the slave set BVALID/RVALID and cleared it again in the same cycle when BREADY/RREADY was already high, so a master that raises READY before VALID (legal, AXI A3.3.1) never saw a response and hung. BVALID/RVALID are now set on the handshake and held until READY; read data/response are registered at the AR handshake (stable while RVALID waits). New cocotb `test_ready_before_valid` (fails on the old RTL) |
| AXI bug 2 (xsim only) | Vivado xsim 2026.1.1 leaves a signal that a called function uses only as a part-select index (`rd_wide(v, w)`: `padded[w*32 +: 32]`) out of the `always_comb` sensitivity, so reading a wide register's high word right after its low word returned the low word in xsim (binary64 AXI). The word selects are now continuous assignments. No other function in the RTL indexes by an argument. Synthesis and Verilator were never affected |
| tests | cocotb suites through the Verilog tops (`make regress-tops`, 24/24 and 3/3 at all 8 widths); `tests/vivado/` xsim testbenches run the Verilog and VHDL tops side by side against the oracle (`make xsim-tops`: streaming with backpressure and out-of-order tags at binary32 x3 DIVSQRT_IMPL, binary16, binary64, W_MANT=0 and an OPS_EN subset; AXI at binary32, E4M3, binary64) |
| Vivado | `syn/vivado-top.tcl` (implementation with a top as the design top: `fp_unit_vhd` binary32 5.6 ns +0.109, `DIVSQRT_IMPL=3` 4.0 ns +0.031; `fp_unit_axilite_vhd` 5.6 ns +0.060; `fp_unit_top` binary16 OPS_EN 0x27 +1.288) and `syn/vivado-bd-check.tcl` (module references in a block design: AXI tops show one AXI4-Lite S_AXI with its clock and active-low reset, parameters propagate; PASS). The AXI X_INTERFACE VLNV is `xilinx.com:interface:aximm:1.0` |
| docs | `docs/fp_unit_core.md`: user guide (parameters, ports, handshake, latency, opcodes, flags, formats incl. the IEEE-style E4M3/E5M2 and the W_MANT=0 format vs OCP, AXI register map and C sequence, Vivado file sets / Tcl / block design, resources, verification, limitations) |
