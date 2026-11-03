# FP Unit: State Review and Implementation Plan

> **Status (2026-11-03, branch `improve/plan`):** Phases 0-3 are
> implemented and verified: T0.1-T0.4, T1.1-T1.5, T2.1, T2.2, and the five
> Phase 3 ops (codes 11-15). See the HANDOFF.md "Change summary" table and
> the commit log. Corrections found while implementing:
> - The iterative engine latency is floor((W_MANT+3)/2) + 3, not ceil
>   (fixed below and in the RTL header).
> - Yosys 0.68 cannot parse `return`, so the `fp_pkg` functions assign
>   their name instead.
> - `fp_exp_seq` is far less accurate than its header claimed (T1.4).
>
> Still open: the Vivado re-measurement (T0.3/T2.1; no Vivado on the
> development host), Phase 4, and the Phase 3.3 design notes.

Written 2026-11-03 against `master` @ `0c8b86f` ("Merge opt/divsqrt-srt").
The reader is an implementing agent. Do the tasks in order. Each task lists the
files to touch, the steps, the acceptance gate, and the known pitfalls. If a
gate fails, stop and fix it before starting the next task.

---

## 0. Ground rules (read first)

1. **Toolchain is pinned.** Verilator 5.020 (`/usr/bin/verilator`), cocotb
   1.9.2 (`<2`), Python 3.13 through `uv`. Do not upgrade any of them. Yosys
   and SymbiYosys come from
   `/home/jesse/Documents/oss-cad-suite-linux-x64-20260813/oss-cad-suite/bin`
   and are **not** on PATH by default (`make formal` adds them). Vivado is not
   on PATH in a plain shell; it is reached through the `ross` Vivado MCP
   tools, if you have them.
2. **Put GNU make first on PATH.** Run `export PATH=/usr/bin:/bin:$PATH`
   before any `make`/`uv run` command. A Siemens Catapult `make` elsewhere on
   PATH breaks Verilator builds with "Process 'make' terminated with error 2".
3. **The Python oracle (`tests/reference/`) is the specification.** Every RTL
   result must match it bit for bit: `y`, all 5 `flags`, and `cmp`. When you
   add an operation, write the oracle function first, check it by hand
   against IEEE 754-2019 (`754-2019.pdf` is in the repo root; it converts with
   `pdftotext -layout`), and only then write the RTL.
4. **Never weaken a test to make it pass.** If the exhaustive sweep reports a
   mismatch, the RTL or the oracle is wrong. Find out which one.
5. **Harness caches.** `exhaustive_build/`, `soak_build/` and
   `latency_build/` cache binaries keyed by a content stamp. If anything
   looks stale, rerun with `FORCE_REBUILD=1` and delete
   `exhaustive_build/*/expected.bin`.
6. **Verilator 5.020 and Yosys 0.68 restrictions.** These caused real bugs
   before (HANDOFF.md, "Bugs found and fixed"):
   - No `break` in loops, and no runtime-bounded `for` loops. Use constant
     bounds and masks (Yosys/formal).
   - A replication with a non-literal count cannot be the first or middle
     item of a concatenation (Verilator parse limitation). Use shifts and ORs.
   - No non-constant `$clog2`.
   - Use explicit `signed` casts on any arithmetic that can go negative. A
     sized unsigned cast zero-extends and corrupts negative values.
   - Do not reset a register from two `always_ff` blocks. Synthesis treats it
     as multi-driven and can silently prune logic.
   - Generic datapaths cannot be elaborated at `W_MANT = 0`. E8M0 needs the
     `*_e8m0` modules (`generate` split in `fp_unit.sv`).
7. **Commit per task** on a feature branch (`git checkout -b <task-id>`), with
   a message that says what changed and which gates passed. Do not commit to
   `master` unless told to.
8. **graphify.** `CLAUDE.md` tells you to use `graphify query` when
   `graphify-out/graph.json` exists. It does not exist today. If it appears,
   follow `CLAUDE.md`, and run `graphify update .` after you change code.

### Verification gates (referred to by name below)

| Gate | Command | Time | Expected output |
|---|---|---|---|
| `LINT` | `make lint` | ~6 s | no output, exit 0 |
| `SMOKE` | `make smoke` | ~30 s | `all widths passed` |
| `REGRESS` | `make regress` | ~1-2 min | `all widths passed` |
| `REGRESS_ALL` | `make regress-all` | a few min | `all widths passed` (8 widths) |
| `AXI` | `make regress-axilite` | ~1 min | `all widths passed` |
| `EXH` | `uv run python tests/exhaustive.py` | ~3-5 min | 7× `EXHAUSTIVE 3604480 vectors: PASS (0 mismatches, 0 latency errors)` (vector count grows when ops are added) |
| `SOAK` | `uv run python tests/soak.py` | several min | `PASS` for binary16, BF16, E4M3 |
| `LAT` | `uv run python tests/latency.py` | ~1 min | `ALL LATENCY PROBES PASS` + table |
| `SRTDIFF` | `uv run python verification/srt/run_diff.py` | several min | 0 mismatches |
| `FORMAL` | `make formal` | minutes | every `.sby` config PASS |

---

## 1. Current state (verified 2026-11-03)

### 1.1 What the design is

- A parameterized IEEE 754-2019 binary FPU: `W_EXP` exponent bits and
  `W_MANT` fraction bits. Tested at E4M3, E5M2, BF16, binary16, binary32,
  binary64, the odd formats 6/16 and 10/40, all seven 8-bit formats, and
  E8M0 (`W_MANT = 0`, a microscaling format with no NaN encoding).
- 11 operations (`fp_pkg::op_t`, 4 bits, codes 0-10): add, sub, mul, div,
  sqrt, fma, min, max, quiet compare, roundToIntegral, totalOrder. All five
  rounding modes, full subnormal support, all five flags.
- **Microarchitecture.** Each operation has its own pipeline with a fixed
  latency that does not depend on the input. All pipelines accept a new start
  every cycle. `fp_unit.sv` decodes `mode`, starts the matching pipeline, and
  merges the results with a priority mux onto a single `y/flags/cmp/out_valid`
  output. The interface has no ready/backpressure signal.
- Latencies in cycles, as measured by the `LAT` gate (see
  `metrics/latency-after.json`):

  | format | add/sub | mul | fma | div | sqrt | rndint | min/max/cmp/tot |
  |---|---|---|---|---|---|---|---|
  | E4M3 | 3 | 4 | 7 | 4 | 5 | 2 | 1 |
  | E5M2 | 3 | 4 | 7 | 4 | 4 | 2 | 1 |
  | BF16 | 3 | 4 | 7 | 5 | 7 | 2 | 1 |
  | binary16 | 3 | 4 | 7 | 6 | 8 | 2 | 1 |
  | binary32 | 3 | 4 | 7 | 9 | 15 | 2 | 1 |
  | binary64 | 3 | 5 | 8 | 17 | 29 | 2 | 1 |
  | E8M0 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |

- **Implementation (binary32, VU9P -2L, OOC).** 5.600 ns clock (178.6 MHz),
  WNS +0.055 ns, 13 338 LUTs, 3 993 FFs, 0 DSPs. The critical path is the SRT
  div/sqrt stage. The previous commit, which used the iterative div/sqrt
  engine, closed 4.000 ns (250 MHz) at about 7.2k LUTs.

### 1.2 Module map (`rtl/`)

| Role | Files | Instantiated by `fp_unit` today? |
|---|---|---|
| Package | `fp_pkg.sv` (rounding/op enums, CMP codes, flag bits) | yes |
| Pipelined generic datapaths | `fp_add_pipe`, `fp_mul_pipe` + `fp_mul_core` (LUT-only multiplier), `fp_fma_pipe`, `fp_div_srt`, `fp_sqrt_srt`, `fp_roundint_pipe`, `fp_minmax_pipe`, `fp_cmp_pipe`, `fp_totalorder_pipe` | yes |
| Combinational reference datapaths | `fp_add`, `fp_mul`, `fp_div`, `fp_sqrt`, `fp_fma`, `fp_roundint`, `fp_minmax`, `fp_cmp`, `fp_totalorder` | only `fp_div`/`fp_sqrt`, and only when `ITER_DIVSQRT=0`; formal and differential harnesses use the rest |
| Iterative div/sqrt engine | `fp_divsqrt_iter.sv` (latency K+3, K=floor((W_MANT+3)/2), one op at a time, `busy`/`done`) | **no** (kept for reference) |
| E8M0 (`W_MANT=0`) | `fp_{add,mul,div,sqrt,fma,roundint}_e8m0.sv` (combinational, 1 cycle through `fp_unit`'s output register) | yes, when `W_MANT=0` |
| Top | `fp_unit.sv` | — |
| Wrappers / users | `fp_unit_axilite.sv` (AXI4-Lite register map, one op at a time), `fp_exp_seq.sv` (fp32 exp, uses two `fp_unit`), `fp32_to_bf16_round.sv` (combinational fp32→bf16 RNE) | — |

### 1.3 Verification infrastructure (`tests/`, `verification/`, `formal/`)

- `tests/reference/`: exact-rational bit-exact oracle (`formats.py`,
  `rounding.py`, `ops.py`, `gen.py`).
- `tests/test_fp_unit.py` (cocotb, 20 tests) + `tests/run_regression.py` (the
  width matrix).
- `tests/exhaustive.py` + `exhaustive_main.cpp`: every op × rm × a × b for
  all 7 eight-bit formats (25.2M vectors). It also asserts a constant
  latency per op.
- `tests/soak.py` + `soak_main.cpp`: seeded random soak at medium widths.
- `tests/latency.py` + `latency_main.cpp`: latency probe.
- `tests/test_fp_unit_axilite.py`: AXI-Lite register-map tests.
- `verification/srt/`: Python SRT models + a **streaming** differential
  (one start per cycle) of `fp_div_srt`/`fp_sqrt_srt` against
  `fp_div`/`fp_sqrt`.
- `formal/` + `bmc_*.sby`: SymbiYosys depth-1 BMC property proofs. **They
  target the combinational modules (`fp_add`, `fp_mul`, `fp_div`, …), not the
  pipelines that `fp_unit` actually instantiates.**
- **Important:** every `fp_unit`-level harness (cocotb, exhaustive, soak,
  latency, AXI) issues **one operation at a time** and waits for
  `out_valid`. Streaming (back-to-back) and mixed-op issue are not tested at
  the `fp_unit` level.

### 1.4 Baseline re-verified today

- `LINT`: clean (all 11 lint configurations, 6 s).
- `SMOKE`: PASS (20/20 cocotb tests).
- `EXH`: all 7 eight-bit formats `EXHAUSTIVE 3604480 vectors: PASS (0 mismatches, 0 latency errors)`.
- `SOAK` (`--vectors 200000`): binary16, BF16, E4M3 PASS.
- `LAT`: `ALL LATENCY PROBES PASS`, table identical to §1.1.
- Not run in this review: `REGRESS_ALL`, `AXI`, `SRTDIFF`, `FORMAL`
  (sby is not on PATH; use `make formal`), Vivado.

Rerun `LINT`, `SMOKE`, `EXH` and `LAT` on your branch before you start, so
you know the baseline is green on your machine.

---

## 2. Findings (problems found in this review, with evidence)

Severity: **P0** wrong results or a hang a user can hit; **P1**
reproducibility or verification gap; **P2** stale docs or maintainability;
**P3** feature or performance opportunity.

| # | Sev | Finding | Evidence |
|---|---|---|---|
| F1 | **P0** | **Result-bus collision drops results silently.** Every pipeline accepts a start each cycle, but they share one output port, merged by a priority mux. If two in-flight ops finish in the same cycle, the lower-priority result is lost. Example (binary32): issue MUL (4 cycles) at cycle 0 and ADD (3 cycles) at cycle 1. Both finish at cycle 4, only the MUL result appears, and `out_valid` pulses once for two requests. There is no `in_ready`, so the caller cannot avoid this except by issuing one op at a time. | Reproduced with a small Verilator harness during this review: "issued 2 ops (MUL then ADD next cycle), got 1 out_valid pulses". `rtl/fp_unit.sv:356-380` (priority mux + OR of valids). |
| F2 | P0 | **Results can come back out of order with no tag.** Even without a collision, an ADD issued after a SQRT finishes first. The caller has to know the latency table to match results to requests. | `fp_unit.sv` has no tag/ID ports. |
| F3 | P0 | **`fp32_to_bf16_round` turns NaNs into infinity.** The NaN/Inf branch returns `x[31:16]`. A NaN whose payload sits only in the low 16 bits (e.g. `0x7F800001`) becomes `0x7F80` = +Inf. Signaling NaNs are not quieted. The module has no test at all. | `rtl/fp32_to_bf16_round.sv:28-29`. No reference in `tests/`. |
| F4 | P1 | **`fp_exp_seq` is compiled but never tested.** It claims ~1e-6 relative error. No harness checks that claim. | `grep fp_exp_seq tests/` finds it only in the RTL list. |
| F5 | P1 | **The Vivado flow cannot be reproduced.** `metrics/vivado-impl.tcl` reads `/tmp/opencode/timing/fp_unit_timing.sv` (the I/O-registering wrapper) and writes to `/tmp/opencode/vivado`. That directory no longer exists. The FMA streaming differential (`/tmp/opencode/fma_diff`) is lost too. | `ls /tmp/opencode/timing` → no such directory. |
| F6 | P1 | **Reserved encodings are undefined.** `mode` 11-15 returns `out_valid` after 1 cycle with a stale `y_add` register value and arbitrary flags. `rm` 5-7 behave as RZ for the increment but as RNE for overflow. The behaviour differs per module and is not documented. | `fp_unit.sv` legacy `always_comb` mux (default branch) and `out_valid_r`. `fp_add_pipe.sv:423-449` `default:` arms. |
| F7 | P1 | **Formal proofs cover the reference modules, not the shipped pipelines.** That is acceptable for 8-bit formats (the exhaustive sweep covers the pipelines), but no proof ties `fp_*_pipe` to `fp_*` at binary16 and above. | `formal/*.sv`, `bmc_*.sby`. |
| F8 | P1 | **The coverage data is stale.** `coverage.dat`/`coverage_annotate` date from 2026-09-17, before the pipelined and SRT modules landed. | File timestamps. |
| F9 | P2 | **Stale or contradicting documentation.** README line 3 says "Parametrized combinational FPU". README says the arithmetic formal proofs are "blocked by a yosys write_smt2 bug", but HANDOFF says they were unblocked and proven. README says `in_valid` is "ignored while the same pipeline is busy" (false: every pipeline streams). README cites min/max as clause 5.6.1. In 754-2019, 5.6.1 is the signaling comparisons, and minimum/maximum are 9.6. HANDOFF's SRT section has two conflicting sqrt latency lists ("sqrt 15/29/8/7/5/4" and "sqrt 17 -> 9 (binary32) …"). The real numbers are 15/29/8/7/5/4. The `fp_unit.sv` header calls the unit combinational and describes `ITER_DIVSQRT` as selecting `fp_divsqrt_iter`. The `fp_unit_axilite.sv` comments refer to the "iterative engine" and to "GO → BUSY → 3 cycles". The `fp_div_srt.sv` header says `CSW = S_W+22`, but the code uses `S_W+14`, and the header still points to `/tmp/opencode/srt` (now `verification/srt`). | The files named. |
| F10 | P2 | **The parameter `ITER_DIVSQRT` is misnamed.** `1` now selects the SRT pipelines, not the iterative engine. The harness flags `--iter`/`FP_ITER_DIVSQRT=1` select the same default build. | `fp_unit.sv:38`, Makefile `*-iter` targets. |
| F11 | P2 | **Many copies of the same lists.** The RTL file list appears in `tests/run_regression.py`, `exhaustive.py`, `soak.py`, `latency.py`, `metrics.py`, `metrics/vivado-impl.tcl`, and and in 6 of the 11 lint lines of the Makefile. The op count `11` is hard-coded in `exhaustive.py`, `exhaustive_main.cpp` (×3), `soak.py`, `soak_main.cpp`, `latency.py` (×3), `test_fp_unit.py:1271`, and `test_fp_unit_axilite.py:264`. The op → oracle dispatch `if/elif` chain is repeated in several drivers. Adding one op today means editing about 15 places. | grep. |
| F12 | P2 | **Repository hygiene.** About 6 MB of AI-session transcripts are committed at the root (`ses_00f278…json`, `session-ses_*.md`). `fp_unit.sv` keeps dead state: `cmp_r` is always 0, `cmp_c` is a constant, and several "legacy" comments are stale. | `git ls-files`. |
| F13 | P3 | **Clock and throughput trade-off.** The SRT landing moved the whole unit from 250 MHz to 178.6 MHz to make div/sqrt faster in cycles. Every other op is now 1.4× slower in wall-clock time. In ns, sqrt got slightly worse (64 → 84 ns at binary32). No build-time option brings back the 250 MHz configuration. | README "Pipelined latency-optimized core" section. |
| F14 | P3 | **Required IEEE 754-2019 operations are missing.** Clauses with "shall": 5.3.1 nextUp/nextDown, remainder, roundToIntegralExact; 5.3.3 scaleB/logB; 5.4.1 convertFromInt; 5.8 convertToInteger*; 5.4.2 format conversions; 5.5.1 copy/negate/abs/copySign; 5.6.1 signaling comparisons; 5.7.2 class/isSignMinus/…. 9.6 (recommended) minimumNumber/maximumNumber/minimumMagnitude/…. Only 5 opcodes (11-15) are free. | `fp_pkg.sv`; 754-2019 §5.3.1, 5.5.1, 5.7.2, 9.6. |
| F15 | P3 | **Area cannot be pruned.** `fp_exp_seq` instantiates two complete `fp_unit`s (all datapaths, ~13k LUTs each) and uses only MUL and ADD. `fp_unit` has no parameter to leave unused ops out. | `rtl/fp_exp_seq.sv:57,74`. |

---

## 3. Task plan

Phases 0-2 are mandatory and low-to-medium risk. Phase 3 adds features.
Phase 4 is optional advanced work. **Do not start Phase 4 without the owner's
approval.**

### Phase 0: hygiene and single sources of truth (low risk, no RTL behaviour change)

#### T0.1 One RTL file list, one op table, one oracle dispatcher

Goal: adding a module or an op becomes a one-place change.

Steps:
1. Create `rtl/filelist.f` with one path per line (relative to the repo root)
   in the current order: `fp_pkg.sv` first, then every datapath, then
   `fp_unit.sv`. Keep `fp_unit_axilite.sv`, `fp32_to_bf16_round.sv` and
   `fp_exp_seq.sv` in a second file, `rtl/filelist_wrappers.f`, because some
   harnesses do not compile them.
2. Create `tests/rtl_files.py` with `def rtl_files(wrappers: bool = False) ->
   list[pathlib.Path]`, which reads those files. Replace the hard-coded `RTL =
   [...]` lists in `run_regression.py`, `exhaustive.py`, `soak.py`,
   `latency.py` and `metrics.py` with calls to it. **Keep the build-stamp
   logic hashing the same set of files.** Today the stamp hashes the `RTL`
   list, so feed it the new list.
3. In the Makefile, replace the repeated lint file lists with
   `RTL := $(shell cat rtl/filelist.f)` and
   `WRAP := $(shell cat rtl/filelist_wrappers.f)`, and use `$(RTL)` in every
   lint line. Keep all 11 lint configurations (including `-GITER_DIVSQRT=1`,
   the `fp_exp_seq` one, the `fp_unit_axilite` ones, and the standalone
   `*_e8m0` ones).
4. In `tests/reference/formats.py`, add the op codes (`OP_ADD = 0` …
   `OP_TOTALORDER = 10`), `NUM_OPS = 11` and `OP_NAMES = (...)`. Import
   them in `test_fp_unit.py`, `test_fp_unit_axilite.py`, `exhaustive.py`,
   `soak.py` and `latency.py` instead of redefining them.
5. In `tests/reference/ops.py`, add
   `def dispatch(op, a, b, c, rm, fmt) -> tuple[int, int, int]` that returns
   `(y, flags, cmp)` for every op. Use the same branch logic as
   `exhaustive.py:generate_expected` (sub = add with `sub=True`; cmp and
   totalOrder return 3-tuples; the others return `cmp=0`). Replace the
   `if/elif` chains in `exhaustive.py` and `soak.py` (and in `test_fp_unit.py`
   where one exists) with `dispatch`.
6. C++ harnesses: replace the literal `11` with a `NUM_OPS` value passed on
   the command line (the Python drivers already pass CLI args) or with a
   `-DNUM_OPS=<n>` define added by the driver to the Verilator `-CFLAGS`.
   The define is simpler: add `"-CFLAGS", f"-DNUM_OPS={NUM_OPS}"` to the
   Verilator command in each driver, and in the `.cpp` write
   `#ifndef NUM_OPS\n#error NUM_OPS\n#endif`.

Gate: `LINT`, `SMOKE`, `EXH`, `LAT`, `AXI`. The output must be identical to
the baseline (same vector counts, same latency table).

Pitfall: the `exhaustive_main.cpp` vector count `11 * 5 * A * A` must become
`NUM_OPS * 5 * A * A`. The binary checks the size of `expected.bin` against
it.

#### T0.2 Fix stale documentation (F9, F10, F12 comment parts)

Edit only comments and Markdown:
- `README.md`: change line 3 to describe a pipelined, fixed-latency-per-op
  FPU with a valid-in/valid-out interface. Replace the "blocked by a yosys
  0.68 write_smt2 bug" paragraph with the current status from HANDOFF
  (arithmetic laws proven at E4M3/E5M2, division laws through binary16).
  Remove "ignored while the same pipeline is busy". Re-cite min/max as
  754-2019 §9.6 `minimum`/`maximum`. State that the "W ≤ 32" multiplier
  condition means significand width `W_MANT+1 ≤ 32`.
- `HANDOFF.md`: in the "DIV/SQRT SRT rework" bullet, delete the conflicting
  sentence "Latencies: div 17 -> 9 … sqrt 17 -> 9 (binary32) …" and keep the
  measured list (div 9/17/6/5/4/4, sqrt 15/29/8/7/5/4). Replace every
  `/tmp/opencode/...` path with its repo equivalent (or with "lost; see T1.4"
  if none exists). Change the "Missing (future milestones)" section, which
  still says the datapath is combinational.
- `rtl/fp_unit.sv` header and the `ITER_DIVSQRT` comment: describe the real
  selection (`ITER_DIVSQRT != 0` → SRT pipelines; `0` → combinational
  `fp_div`/`fp_sqrt` with 1-cycle latency). Change the comment above `y_r`
  ("During an iterative div/sqrt transaction …").
- `rtl/fp_unit_axilite.sv`: fix the operation-flow comment and the
  "GO strobe -> BUSY -> 3 cycles -> VALID" banner (latency varies by op; see
  the README table).
- `rtl/fp_div_srt.sv` header: change `CSW = S_W+22` to the real `S_W+14`
  (check `fp_sqrt_srt.sv` too: it uses `S_W+18`), and change
  `/tmp/opencode/srt` to `verification/srt`.

Gate: `LINT` (comments only, but run it anyway).

#### T0.3 Bring the Vivado flow back into the repo (F5)

1. Create `syn/fp_unit_timing.sv`. Module `fp_unit_timing` with the same
   parameters as `fp_unit` (default binary32) that registers **every** input
   (`in_valid, mode, rm, a, b, c`) once, feeds them to `fp_unit`, and
   registers every output once. With this, input and output ports are not
   timed as unconstrained combinational paths in OOC mode. Keep `rst_n`
   synchronous, passed straight through.
2. Move `metrics/vivado-impl.tcl` to `syn/vivado-impl.tcl`. Compute paths
   relative to the script
   (`set root [file normalize [file dirname [info script]]/..]`), read the
   RTL from `rtl/filelist.f` (T0.1) plus `syn/fp_unit_timing.sv`, write
   reports to `syn/out/` (add it to `.gitignore`), and take the clock period
   from an optional `-tclargs` argument (default 5.600).
3. Add a `make vivado` target that prints the command to run
   (`vivado -mode batch -source syn/vivado-impl.tcl -tclargs 5.600`), so a
   missing tool cannot break the target.
4. If Vivado is available (through the `ross` MCP), run it once and check
   that the WNS and utilization are close to `metrics/vivado-*.rpt` (WNS
   within ±0.1 ns, LUTs within ±3 %). If Vivado is not available, say so in
   the commit message. Do not invent numbers.

Gate: `LINT`. The new wrapper must also pass
`verilator --lint-only -Wall $(cat rtl/filelist.f) syn/fp_unit_timing.sv --top-module fp_unit_timing`.

#### T0.4 Repository hygiene (needs owner confirmation)

- **Ask the owner before doing this.** Remove the committed session
  transcripts from the index (`git rm --cached ses_*.json session-ses_*.md`)
  and add `ses_*.json` and `session-*.md` to `.gitignore`. They stay on disk.
- Remove the dead `cmp_r`/`cmp_c` path in `fp_unit.sv`: `cmp` is `cmp_cmp_pipe`
  or `cmp_tot_pipe` when those are valid, and `2'd0` otherwise. Gate: `EXH`.

### Phase 1: correctness of the top-level interface (P0)

#### T1.1 Add backpressure (`in_ready`) with a result-bus reservation table (F1)

This is the most important task in the plan. It fixes the silent loss of
results.

**Interface change (backward compatible):** add `output logic in_ready`. An
op starts only on a cycle where `in_valid && in_ready` (call that `fire`).
A caller that issues one op at a time always sees `in_ready = 1`, so every
existing harness keeps working unchanged.

**Latency table.** Add these functions to `fp_pkg.sv`. They reproduce the
pipelines' formulas exactly. Verify each function against the `LAT` table in
§1.1 before you use it.

```systemverilog
  // Cycle counts from `fire` to `out_valid` (generic formats, W_MANT > 0).
  function automatic int lat_mul(input int w_mant);   // fp_mul_core TWO_STAGE = (S_W <= 32)
    return (w_mant + 1 <= 32) ? 4 : 5;
  endfunction
  function automatic int lat_fma(input int w_mant);
    return (w_mant + 1 <= 32) ? 7 : 8;
  endfunction
  function automatic int lat_div_srt(input int w_mant, input int dps);
    int s_w, target, ndig;
    s_w = w_mant + 1;  target = s_w + 2;
    ndig = (target % 2 == 0) ? (target / 2 + 1) : ((target + 1) / 2 + 1);
    return (ndig + dps - 1) / dps + 2;               // NSTG + 2
  endfunction
  function automatic int lat_sqrt_srt(input int w_mant, input int dps);
    int s_w, re, ndig;
    s_w = w_mant + 1;
    re  = 2 * s_w + 6 + ((s_w % 2 == 0) ? 2 : 0);    // R_W + PAD
    ndig = (re - 4) / 4;
    return (ndig + dps - 1) / dps + 2;
  endfunction
  function automatic int lat_divsqrt_iter(input int w_mant);
    return (w_mant + 3) / 2 + 3;                     // K + 3, K = floor((W_MANT+3)/2) (the RTL header said ceil: wrong for even W_MANT)
  endfunction
```

Expected values: `lat_div_srt(23,2)=9`, `lat_div_srt(52,2)=17`,
`lat_div_srt(10,2)=6`, `lat_div_srt(7,2)=5`, `lat_div_srt(3,2)=4`,
`lat_div_srt(2,2)=4`; `lat_sqrt_srt(23,1)=15`, `(52,1)=29`, `(10,1)=8`,
`(7,1)=7`, `(3,1)=5`, `(2,1)=4`; `lat_divsqrt_iter(23)=16`, `(52)=30`.

In `fp_unit.sv`, define `localparam int LAT_ADD, LAT_MUL, LAT_FMA, LAT_DIV,
LAT_SQRT, LAT_RND, LAT_MM = 1, LAT_LEGACY = 1`, and `MAXLAT` as their
maximum. For `W_MANT == 0` every op is 1 cycle except min/max/cmp/totalOrder,
which also take 1. For `ITER_DIVSQRT == 0`, div/sqrt go through `out_valid_r`
and take 1 cycle. Reserved opcodes also take 1 (`out_valid_r`).

Write a combinational `function automatic int lat_of(op_t m)`, or use an
`always_comb` case, to get `lat_sel` for the current `mode`.

**Reservation vector.**

```systemverilog
  // resv[i] == 1  <=>  some in-flight op will assert out_valid i cycles
  // from now (i = 0 is the current cycle). Index MAXLAT is always 0 at the
  // current cycle; it exists so resv[lat_sel] is always in range.
  logic [MAXLAT:0] resv;
  assign in_ready = !resv[lat_sel];
  assign fire     = in_valid && in_ready;
  always_ff @(posedge clk) begin
    if (!rst_n) resv <= '0;
    else        resv <= (resv >> 1) | (fire ? ((MAXLAT+1)'(1) << (lat_sel - 1)) : '0);
  end
```

Replace `in_valid` with `fire` in **every** `start_*` assignment and in the
`out_valid_r` update.

**Optional tag (F2).** Add `parameter int TAG_W = 1`, `input logic
[TAG_W-1:0] in_tag` and `output logic [TAG_W-1:0] out_tag`. Keep a tag
array `logic [TAG_W-1:0] tag_q [MAXLAT+1]` that shifts the same way as
`resv`: entry i moves to entry i-1 each cycle, and on `fire` entry
`lat_sel - 1` (after the shift) gets `in_tag`. Then `out_tag = tag_q[0]`.
Because each slot is reserved by at most one op, no two tags overlap.

**Assertions (simulation only).** Wrap them in
`ifndef SYNTHESIS ... endif`:
- `out_valid == resv[0]` every cycle after reset. If a latency function is
  wrong, this fires on the first vector.
- the individual pipeline valids (`mul_valid`, `fma_valid`, …,
  `out_valid_r`) are `$onehot0`.

Add `--assert` to the Verilator build lines in `exhaustive.py`, `soak.py`
and `latency.py` (cocotb builds: add it to `build_args` in
`run_regression.py`) so the assertions actually run.

**Callers.**
- `fp_unit_axilite.sv`: connect `in_ready`. Hold `fpu_in_valid` until
  `fpu_in_ready` (with one op at a time it is always ready, but write it
  correctly). Connect the tag ports to `'0` and leave `out_tag` unused,
  inside a `lint_off PINCONNECTEMPTY` region if needed.
- `fp_exp_seq.sv`: the same. It issues one op at a time.
- The C++ harnesses do not need changes. The new input ports default to 0.

Gate: `LINT`, `SMOKE`, `REGRESS_ALL`, `AXI`, `EXH`, `SOAK`, `LAT` (the
latency table must not change). Then T1.2.

Pitfalls:
- `lat_sel - 1` for a 1-cycle op is 0, so the op books `resv[0]` of the next
  cycle, which is exactly when its `out_valid` appears. Get this right on
  paper first, then prove it with the `out_valid == resv[0]` assertion.
- `in_ready` depends combinationally on `mode`. That is allowed: like AXI,
  the master must keep `mode` and operands stable while `in_valid` is high and
  `in_ready` is low. Document this in the `fp_unit` header.
- Do not change any datapath module in this task.

#### T1.2 Streaming and mixed-issue soak harness (verifies T1.1; also covers F5's lost FMA streaming test)

1. Add `tests/stream_main.cpp` and `tests/stream.py` (copy `soak.py` and
   `soak_main.cpp` as the skeleton). The driver generates the same vector
   records as the soak, plus a per-vector `tag` (`i & ((1<<TAG_W)-1)`, built
   with `-GTAG_W=16`).
2. The C++ loop presents a new vector **every cycle** that `in_ready` allows
   (`in_valid = 1` always, until the stream is exhausted). It pushes
   `(tag, expected)` into a map when `in_valid && in_ready` at the clock
   edge. When `out_valid` is high, it looks up `out_tag`, compares
   `y/flags/cmp`, and erases the entry. At the end the map must be empty (no
   lost results) and every vector must have completed.
3. Two modes: `--same-op` (every vector uses one op: this checks each
   pipeline's back-to-back streaming, including the FMA context alignment
   that HANDOFF says was once ~99 % wrong) and `--mixed` (random op per
   vector: this checks the reservation table). Also report the achieved
   issue rate (`fires / cycles`). With `--same-op` it must be 1.0 for every
   op.
4. Add `make stream` (default: binary16, BF16, E4M3, binary32; both modes;
   200k vectors each).

Gate: `make stream` 0 mismatches, 0 lost results, same-op issue rate 1.0 for
all 11 ops. **Run this test against `master` too, without T1.1. It must FAIL
in `--mixed` mode. That proves the test can catch F1.**

#### T1.3 Fix `fp32_to_bf16_round` and test it (F3)

1. NaN input (`x[30:23] == 8'hFF && x[22:0] != 0`): return
   `{x[31], 8'hFF, 1'b1, x[21:16]}`. That quiets the NaN and keeps the sign
   and the top payload bits, so the result is never Inf. Infinity input
   passes through unchanged (`x[31:16]`).
2. Remove the dead `rounded[16]` branch. `{0, hi} + 1` cannot carry out of
   bit 16 for a finite `x`. Rounding up the largest finite value already
   gives the correctly signed Inf encoding, `0x7F80`/`0xFF80`.
3. Document the semantics in the header: RNE only, NaN quieted, no flags
   output. Ask the owner whether an inexact/overflow flag output is wanted.
   Do not add one without asking.
4. Add a reference function `f32_to_bf16_rne(x) -> int` in
   `tests/reference/ops.py`. Decode `x` with `BinFormat(8,23)`, then for
   finite values use `round_to_format(sign, value, MODE_RNE,
   BinFormat(8,7))`. Handle NaN as in step 1.
5. Add a standalone Verilator C++ harness `tests/bf16_main.cpp` +
   `tests/bf16.py` that checks **all 2^32 inputs** (a tiny combinational
   module, so this takes a minute or less). The expected value comes from a
   C++ port of the rule: `round_up = g && (sticky || lsb)`, plus the NaN
   rule. Before the sweep, `bf16.py` checks that C++ rule against the Python
   oracle `f32_to_bf16_rne` on all special encodings plus 1M random inputs,
   by writing them to a file the C++ harness also checks.

Gate: new harness PASS, `LINT`.

#### T1.4 Test `fp_exp_seq` (F4)

Add a cocotb test (`tests/test_fp_exp_seq.py`, run with
`--top fp_exp_seq --tests test_fp_exp_seq`, the way the AXI test is run) that:
- drives 2 000 random `x` in [-16, 16] plus the edge cases ±0, ±16, ±16.5
  (clamped), tiny values, NaN, ±Inf;
- checks `y` against `math.exp(clamp(x))` rounded to fp32 within a stated
  ULP bound. Measure the bound first, then set the tolerance to the
  measured maximum rounded up. Report it in the README;
- checks `done` pulses once per `start`.
Write down how NaN and Inf inputs are handled today (the clamp compares
magnitudes, so NaN is treated as a huge magnitude and clamped). Put the
observed behaviour in the module header. Ask the owner before changing it.

Gate: the new test passes. Add a `make regress-exp` target.

#### T1.5 Define the reserved opcodes and rounding modes (F6)

Recommended semantics. **Confirm them with the owner first.** These are API
decisions.
- `mode` 11-15 (before Phase 3 uses any of them): `y = 0`,
  `flags = 1 << FLAG_INVALID`, `cmp = 0`, latency 1 (through `out_valid_r`).
- `rm` 5-7: map to RNE at the `fp_unit` input
  (`rm_eff = (rm > RM_RM) ? RM_RNE : rm`), so every datapath sees a defined
  mode.
Add both rules to the oracle (`dispatch` from T0.1), to README "Semantics",
and to a directed cocotb test. The exhaustive sweep keeps `rm` in 0..4.

Gate: `SMOKE`, `EXH`, `AXI`.

### Phase 2: configurability (P3, moderate)

#### T2.1 Choose the div/sqrt implementation at build time (gets the 250 MHz build back) (F13)

Replace `ITER_DIVSQRT` with
`parameter int DIVSQRT_IMPL = 1   // 0 = combinational fp_div/fp_sqrt, 1 = SRT pipelines (178 MHz), 2 = iterative fp_divsqrt_iter (250 MHz)`.
Keep `ITER_DIVSQRT` as a deprecated alias for one release: if a user sets
`ITER_DIVSQRT=0`, `DIVSQRT_IMPL` becomes 0. Or just rename it everywhere
(Makefile `-GITER_DIVSQRT=1`, `FP_ITER_DIVSQRT`, the `--iter` flags,
`fp_unit_axilite`). Choose the rename and update every reference.
`grep -rn ITER_DIVSQRT` lists them.

For `DIVSQRT_IMPL == 2`:
- Wire `fp_divsqrt_iter` exactly as commit `3323487` did
  (`git show 3323487:rtl/fp_unit.sv` is a working reference), but gate its
  start with `fire`. It serves one op at a time, so **div/sqrt must not be
  ready while the engine is busy**:
  `in_ready = !resv[lat_sel] && !(is_divsqrt(mode) && busy_iter)`. The
  engine accepts a new start in its `done` cycle (see the comment at
  `fp_divsqrt_iter.sv:601`), so use `busy_iter` exactly as 3323487 did.
- `LAT_DIV = LAT_SQRT = lat_divsqrt_iter(W_MANT)`.
- In T1.2's `--same-op` streaming test the expected issue rate for div/sqrt
  becomes `1/LAT`, not 1.0. Make the test accept a per-op expected rate.

Add harness flags `--divsqrt {0,1,2}` (replacing `--iter`) and build dirs
keyed by the value.

Gate: `LINT` (all 3 values), `EXH` + `SOAK` + `LAT` + `make stream` for
`DIVSQRT_IMPL=1` and `=2`; `EXH` for `=0`. If Vivado is available, run T0.3
with `DIVSQRT_IMPL=2` at 4.000 ns and record WNS and LUTs in README. Expect
about +0.0x ns WNS and about 7.2k LUTs, as in commit `54a661a`.

#### T2.2 Op-enable mask for area pruning (F15)

Add `parameter logic [15:0] OPS_EN = 16'hFFFF` (bit i = `op_t` value i).
Wrap each datapath instance in `if (OPS_EN[OP_x])`, tie its outputs to 0
otherwise, and leave those ops out of `start_*`. A disabled opcode behaves as
reserved (T1.5: invalid, 1 cycle). `OP_MIN`/`OP_MAX` share one pipeline:
enable it if either bit is set. `OP_ADD`/`OP_SUB` likewise.

Use it in `fp_exp_seq`: `u_mul` gets `OPS_EN = 1 << OP_MUL` and `u_add`
gets `(1 << OP_ADD) | (1 << OP_SUB)`.

Gate: `LINT`; `EXH` with the default mask; a cocotb or latency test with a
reduced mask showing that a disabled op returns the reserved-op result; T1.4
still passes. If Vivado or Yosys is available, report the `fp_exp_seq` cell
count before and after (`tests/metrics.py` uses Yosys; add an `fp_exp_seq`
entry).

### Phase 3: IEEE 754-2019 operations (P3) (F14)

#### 3.0 Opcode budget

There are 5 free codes (11-15), and the AXI `OPCODE` register packs
`[3:0] op, [6:4] rm`. To add more than 5 ops later, widen `op_t` to 5 bits
and move `rm` to `OPCODE[10:8]`. That breaks the AXI software interface, so
it is an owner decision and is **not** part of this plan. To fit the most
useful operations into the 5 codes, the plan uses the **`rm` field as a
sub-operation selector** for ops that do not round (the RISC-V `funct3`
pattern):

| code | name | rm sub-op | 754-2019 | result |
|---|---|---|---|---|
| 11 | `OP_SGNJ` | 0 copy(a), 1 negate(a), 2 abs(a), 3 copySign(a,b); 4 → copy | 5.5.1 | `y`; no flags ever, NaN payload/sign bits untouched |
| 12 | `OP_CLASS` | ignored | 5.7.2 `class` | `y` = class index 0..9 (signalingNaN, quietNaN, −Inf, −normal, −subnormal, −0, +0, +subnormal, +normal, +Inf) zero-extended; flags 0 |
| 13 | `OP_NEXT` | 0 nextUp, 1 nextDown, others → nextUp | 5.3.1 | `y`; invalid only for sNaN (result is the quieted NaN per 6.2) |
| 14 | `OP_MINMAXNUM` | 0 minimumNumber, 1 maximumNumber, 2 minimumMagnitudeNumber, 3 maximumMagnitudeNumber, 4 → minimumNumber | 9.6 | `y`; invalid iff either operand is sNaN |
| 15 | `OP_RNDINTX` | rounding mode (as `OP_RNDINT`) | 5.3.1 roundToIntegralExact | like `OP_RNDINT`, but raises inexact when the result ≠ the input |

The E8M0 caveat: there are no NaN encodings. `class` never returns 0 or 1,
and `nextUp(maxfinite)` is +Inf (check what `formats.py` does for E8M0
Inf/NaN before you write the oracle). Every op must also work at
`W_MANT = 0` (these ops are simple bit manipulation, so one format-generic
module usually works for both branches, as `fp_minmax` does). If Verilator
5.020 crashes at `W_MANT=0` (bug 8 in HANDOFF), write a separate `*_e8m0`
module.

Order: `OP_SGNJ` → `OP_CLASS` → `OP_RNDINTX` → `OP_MINMAXNUM` → `OP_NEXT`.
That is roughly increasing difficulty. Do one op per branch/commit.

#### 3.1 Checklist for adding one operation (follow every line)

1. **Spec.** Quote the 754-2019 clause in the module header. Write down the
   NaN, ±0, ±Inf, subnormal and E8M0 behaviour before you write any code.
2. **Oracle.** Add `fp_<op>` to `tests/reference/ops.py` and to `dispatch`.
   Add the op code to `formats.py` (`OP_*`, `OP_NAMES`; bump `NUM_OPS`).
3. **Hand check.** Add a directed vector list `_directed_<op>_vectors(fmt)`
   in `test_fp_unit.py` with expected values written out by hand
   (not computed by the oracle). Include ±0, ±min subnormal, ±max
   subnormal, ±min normal, ±1, ±max finite, ±Inf, qNaN with payload, sNaN,
   and for two-operand ops the mixed pairs. Run the oracle over the list
   and fix the oracle until it agrees.
4. **RTL.** Write `rtl/fp_<op>_pipe.sv` with the same port shape as
   `fp_minmax_pipe.sv` (`clk, rst_n, start, a, b, rm → y, flags, [cmp],
   out_valid`). One register stage, i.e. latency 1, is right for all five
   ops above. Use the existing `localparam` header block (`BIAS`, `EMAX`,
   `EXP_ALL`, `QUIET`, …) copied from a sibling module.
5. **`fp_pkg.sv`.** Add the enum value. Keep `tests/reference/formats.py` in
   sync.
6. **`fp_unit.sv`.** Instantiate, add `start_<op> = fire && mode == OP_<op>`,
   add the latency (`lat_sel` case), add the result to the `y`/`flags`/`cmp`
   output mux and the `out_valid` OR, and exclude `start_<op>` from
   `out_valid_r`. If T2.2 landed, also gate the instance with `OPS_EN`.
7. **File lists.** Add the file to `rtl/filelist.f` (one place, after T0.1).
8. **Tests.** Add `test_directed_<op>` and `test_<op>_random` to
   `test_fp_unit.py`. `test_random_mixed` and the AXI random test pick from
   `NUM_OPS` automatically after T0.1. The exhaustive sweep and soak pick up
   the new op from `NUM_OPS` and `dispatch`. Check the exhaustive vector
   count rises by `5·256·256 = 327 680` per format.
9. **Latency probe.** Add the op name to `latency.py`'s `OPS`. Add the
   expected latency to the README table.
10. **Docs.** README op list, latency table, semantics section, AXI opcode
    table comment in `fp_unit_axilite.sv`. Add a HANDOFF changelog row.
11. **Gates.** `LINT`, `REGRESS_ALL`, `AXI`, `EXH`, `SOAK`, `LAT`,
    `make stream`.

#### 3.2 Notes per op

- **OP_SGNJ.** Pure bit manipulation. `copySign(a,b) = {b[W-1], a[W-2:0]}`.
  Never raises a flag, not even for sNaN (754-2019 §5.5.1: "signal no
  exception"). Must **not** quiet NaNs.
- **OP_CLASS.** Put the 4-bit index in `y[3:0]`. Every tested format has
  W ≥ 8, but add an elaboration-time check
  (`if (W < 4) $error("OP_CLASS needs W >= 4");` inside a generate) for
  safety. Use the existing classification already in
  `fp_cmp.sv` and `fp_minmax.sv` (exponent all-ones / zero, mantissa zero,
  quiet bit `a[W_MANT-1]`).
- **OP_RNDINTX.** Reuse `fp_roundint_pipe`. Add an `exact` input port and
  raise `FLAG_INEXACT` when a finite non-integral input was rounded. Simplest
  test: the result bits differ from the input bits and the input is finite
  and non-NaN. Do **not** use that shortcut for NaN or Inf: those return
  unchanged (or quieted) and are never inexact. An sNaN input raises invalid,
  as `OP_RNDINT` already does (check the oracle).
- **OP_MINMAXNUM.** Compute it from `fp_minmax`'s ordering. The NaN rule
  differs from `OP_MIN`/`OP_MAX`: return the number when exactly one operand
  is NaN; return a quiet NaN (payload of the first NaN, per the unit's 6.2.3
  convention) when both are NaN; raise invalid iff either is sNaN. For the
  Magnitude variants, compare |a| and |b| first and fall back to the
  non-magnitude rule on a tie. −0 < +0 in all variants.
- **OP_NEXT.** For finite non-zero `x`, nextUp is an increment or decrement
  of the magnitude field by 1 ulp (sign-magnitude integer ±1 on
  `a[W-2:0]`): +1 for positive, −1 for negative. ±0 → +min subnormal (or, if
  the format has no subnormals, as at `W_MANT=0`, the min normal). −min
  subnormal → −0. +Inf → +Inf. −Inf → −max finite. +max finite → +Inf. qNaN
  → same NaN under the unit's NaN convention (check `_nan_result`). sNaN →
  quieted, invalid. nextDown(x) = −nextUp(−x). Implement it literally that
  way, so the sign rules stay consistent.

#### 3.3 Not in this plan (need interface decisions; write them up only)

Signaling comparisons (5.6.1; could be `OP_CMP` + a sub-op, but that changes
existing `OP_CMP` behaviour for rm ≠ 0), convertFromInt / convertToInteger
(5.4.1, 5.8: need an integer-width parameter and a different port shape),
format conversions (5.4.2), scaleB/logB (5.3.3), remainder (5.3.1:
iterative, large). For each, write a one-page design note in
`docs/proposals/` covering the opcode or interface change, the latency, and
the area estimate. Do not implement them.

### Phase 4: advanced performance (optional; ask the owner first)

Only start these after Phases 0-2 are merged and the owner asks for them.
Each needs Vivado measurements. Without the measurements, report "not
attempted".

- **P4.1 Close 4.000 ns with the SRT pipelines.** The stage that sets the
  clock is the per-stage carry-save **fold**: a full-width carry-propagate
  adder at every stage boundary, which HANDOFF calls "essential". Standard
  SRT keeps the residual in a **fixed-width** carry-save form and discards
  carries out of the top bit (two's-complement wrap-around is exact because
  |residual| is bounded). Only the top ~6-8 bits get a short CPA for digit
  selection. That removes the long CPA from every stage. HANDOFF says
  "without folding … drift to ~S_W+3n bits". That drift happens when widths
  are allowed to grow. They must be truncated modulo 2^CSW after every
  update instead. Procedure: change the Python models in
  `verification/srt/*_model.py` first, prove 0 mismatches there, then change
  the RTL, then run `SRTDIFF`, `EXH`, `SOAK`, `make stream`, then Vivado at
  4.000 ns.
- **P4.2 Add/sub leading-zero anticipation (LZA).** The goal is a 2-cycle
  add. The HANDOFF notes say the S3 normalize/round stage is the obstacle.
- **P4.3 Formal equivalence of the pipelines against the combinational
  references** at binary16 (F7): a SymbiYosys config with depth = latency +
  1, the same `a`/`b`/`rm` driven into `fp_add_pipe` and `fp_add`,
  asserting equal outputs when `out_valid`. Start with add and mul. Expect
  the solver to struggle at fma.
- **P4.4 Refresh coverage (F8).** Run `make coverage` after Phases 0-3 and
  record per-module line coverage of the `*_pipe`, `*_srt` and new op
  modules in HANDOFF. This is cheap: do it as part of Phase 3 if there is
  time.

---

## 4. Definition of done for the whole plan

- [ ] F1/F2 fixed: `make stream --mixed` reports 0 lost results on all
      default formats; the same harness fails on the old `master`.
- [ ] F3 fixed and exhaustively tested; F4 tested with a documented ULP bound.
- [ ] F5: `syn/vivado-impl.tcl` + `syn/fp_unit_timing.sv` committed and
      runnable from a clean checkout.
- [ ] F6: reserved encodings defined, documented and tested.
- [ ] F9-F11: docs agree with the code; adding an op touches the RTL module,
      `fp_pkg.sv`, `fp_unit.sv`, `filelist.f`, `formats.py`, `ops.py`, the
      tests and the docs only.
- [ ] T2.1: a 250 MHz build option exists (`DIVSQRT_IMPL=2`) and is
      verified. T2.2: `fp_exp_seq` no longer builds full units.
- [ ] Phase 3 ops merged one by one, each with every gate green.
- [ ] README latency table regenerated from `make metrics-latency`.

---

## Appendix A: `fp_unit` port list after Phase 1

```
input  clk, rst_n (synchronous, active low)
input  in_valid               // request
output in_ready               // NEW: request accepted on in_valid && in_ready
input  op_t mode, rounding_t rm
input  [W-1:0] a, b, c        // c used by OP_FMA only
input  [TAG_W-1:0] in_tag     // NEW (optional, default width 1)
output [W-1:0] y
output [1:0] cmp
output [4:0] flags            // {invalid, div0, overflow, underflow, inexact}
output out_valid              // exactly one pulse per accepted request
output [TAG_W-1:0] out_tag    // NEW: in_tag of the request that completes
```

Rules: hold `mode/rm/a/b/c/in_tag` stable while `in_valid && !in_ready`.
Results return in completion order, not issue order. Use `out_tag` to match
them.

## Appendix B: where the existing "start one op, wait for out_valid" assumption lives

`tests/test_fp_unit.py:69` (`check()`), `tests/soak_main.cpp:76-104`,
`tests/exhaustive_main.cpp`, `tests/latency_main.cpp`,
`rtl/fp_unit_axilite.sv` (S_IDLE/S_WAIT FSM), `rtl/fp_exp_seq.sv` (sequencer).
None of them needs to change for T1.1, but none of them would catch a
regression in streaming. That is why T1.2 exists.

## Appendix C: useful history

- `54a661a` last 250 MHz master (iterative div/sqrt, 7 255 LUTs, WNS +0.014 ns).
- `3323487` reference wiring of `fp_divsqrt_iter` with the `busy` handshake.
- `0fca7b6`, `5aa4ae5` the FMA and MUL context-alignment fixes for
  back-to-back starts. They show the bug class that T1.2 guards against.
- HANDOFF.md "Bugs found and fixed" (25+ entries) is required reading
  before you touch any datapath.

## Appendix D: baseline log

Collision reproduction used for F1 (binary32, Verilator C++ against
`fp_unit`; build it with the same file list as `tests/latency.py`):

```cpp
// cycle 0: MUL 2.0*3.0 (4 cycles); cycle 1: ADD 1.0+1.0 (3 cycles)
t->in_valid=1; t->mode=2; t->rm=0; t->a=0x40000000; t->b=0x40400000;
tick();                         // MUL sampled
t->mode=0; t->a=0x3f800000; t->b=0x3f800000;
tick();                         // ADD sampled
t->in_valid=0;
// ...count out_valid pulses over the next 12 cycles
```

Observed on `0c8b86f`: one pulse at cycle 4 with `y=0x40c00000` (6.0). The
ADD result (2.0) never appears. After T1.1, `in_ready` must be low in the
cycle the ADD is presented (the slot is taken), so the ADD is accepted one
cycle later and both results appear.
