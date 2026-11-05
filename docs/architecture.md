# jsm_fp_unit: architecture and verification specification

For maintainers. It describes how the unit is built, how it is verified,
the rules the RTL follows so that every supported tool reads it, and how to
extend it. The interface contract (ports, timing, semantics, register maps)
is in [user_guide.md](user_guide.md) and is not repeated here.

## 1. Specification sources

- **IEEE 754-2019** defines the arithmetic. Module headers cite the clause
  each behaviour comes from.
- **The reference model is the executable specification.**
  `tests/reference/` computes every result and flag bit-exactly with exact
  rational arithmetic: `formats.py` (format parameters, opcode table,
  `NUM_OPS`, rounding-mode and flag encodings), `ops.py` (one function per
  operation and `dispatch()`, the single opcode-to-function map that every
  harness uses), `gen.py` (operand generators biased towards boundaries).
  When the RTL and the model disagree, the clause decides which one is wrong;
  both have had bugs.
- Implementation choices the standard leaves open are fixed in the model
  and documented in the user guide: the NaN result (quiet, sign 0, payload
  of the first NaN operand), tininess after rounding, the reserved encodings
  (rm 5-7 behave as RNE; disabled opcodes return y = 0 with invalid), and
  the `W_MANT = 0` format (no NaN; invalid gives +infinity).

## 2. Repository map

| path | contents |
|------|----------|
| `rtl/jsm_fp_pkg.sv` | opcode/rounding enums, flag and cmp encodings, latency functions (`lat_*`, `max_latency`), SRT configuration per `DIVSQRT_IMPL` |
| `rtl/jsm_fp_unit.sv` | the unit: per-operation pipelines on one result port |
| `rtl/jsm_fp_*_pipe.sv`, `jsm_fp_mul_core.sv`, `jsm_fp_div_srt.sv`, `jsm_fp_sqrt_srt.sv`, `jsm_fp_divsqrt_iter.sv` | the pipelined datapaths |
| `rtl/jsm_fp_add.sv`, `_mul`, `_div`, `_sqrt`, `_fma`, `_minmax`, `_cmp`, `_totalorder`, `_roundint` | combinational reference datapaths (formal proofs, `DIVSQRT_IMPL = 0`, building blocks of some pipes) |
| `rtl/jsm_fp_*_e8m0.sv` | dedicated `W_MANT = 0` datapaths |
| `rtl/jsm_fp_unit_axis.sv`, `rtl/jsm_fp_unit_axilite.sv` | AXI4-Stream and AXI4-Lite wrappers |
| `rtl/top/` | Verilog-2001 and VHDL tops, `jsm_fp_unit_flat.sv` shim |
| `rtl/filelist*.f` | the only file lists: `filelist.f` (core, compile order), `filelist_wrappers.f`, `filelist_vhdl.f` |
| `tests/` | cocotb suites, C++ Verilator harnesses, reference model, Vivado xsim testbenches (`tests/vivado/`) |
| `verification/srt/` | SRT division/sqrt models and the streaming module differential |
| `formal/` | SymbiYosys property and equivalence proofs (`*.sby`, `*_props.sv`, `fp_pipe_equiv.sv`) |
| `syn/` | Vivado scripts (implementation, per-module timing, tops, block design, IP packaging) |
| `metrics/` | reference Vivado reports of the default build; `make metrics-*` writes JSON here |

## 3. The unit (`jsm_fp_unit`)

### 3.1 Structure

Each operation class has its own pipeline with a fixed latency. A request
is decoded once and starts exactly one pipeline (`start_*` strobes); all
pipelines deliver to one output register. Operations without a pipeline of
their own go through a 1-cycle path into that register: the `W_MANT = 0`
datapaths, `DIVSQRT_IMPL = 0` div/sqrt, and reserved or disabled opcodes.

| pipeline | operations | latency (binary32) |
|----------|------------|--------------------|
| `jsm_fp_add_pipe` | ADD, SUB | 3 |
| `jsm_fp_mul_pipe` (+ `jsm_fp_mul_core`) | MUL | 4 (5 for W_MANT + 1 > 32) |
| `jsm_fp_fma_pipe` (+ `jsm_fp_mul_core`) | FMA | 7 (8) |
| `jsm_fp_div_srt` / `jsm_fp_sqrt_srt` | DIV / SQRT, `DIVSQRT_IMPL` 1 or 3 | 9 / 15 (17 / 16) |
| `jsm_fp_divsqrt_iter` | DIV and SQRT, `DIVSQRT_IMPL` 2 | 16 |
| `jsm_fp_roundint_pipe` | RNDINT, RNDINTX | 2 |
| `jsm_fp_minmax_pipe`, `_cmp_pipe`, `_totalorder_pipe`, `_misc_pipe` | MIN/MAX, CMP, TOTALORDER, SGNJ/CLASS/NEXT/MINMAXNUM | 1 |

`OPS_EN` removes pipelines at elaboration; a disabled opcode behaves as
reserved. `GENERIC = (W_MANT > 0)` selects the generic datapaths or the
`*_e8m0` set.

### 3.2 Result-port reservation and tags

Pipelines of different latency would complete in the same cycle. The unit
keeps a reservation vector `resv[MAXLAT:0]`: `resv[i]` is set if a result is
due `i` cycles from now (`resv[0] == out_valid`). A request of latency L is
accepted only if `resv[L]` is clear (`in_ready`), and then sets bit L - 1 of
the next, shifted vector. `in_ready` therefore depends on `mode` (through
L). The iterative engine adds a busy condition for div/sqrt.

The request tag travels in a parallel shift register `tag_q`, written at
index L - 1 on acceptance and shifted like `resv`; `out_tag = tag_q[0]`.

Latencies come from `jsm_fp_pkg::lat_*`. If a pipeline's depth changes,
the matching function must change too. Simulation assertions
(`out_valid == resv[0]`, at most one pipeline delivering per cycle) and
`tests/latency.py` catch any mismatch. `jsm_fp_pkg::max_latency` is the
bound the AXI4-Stream wrapper sizes its buffer from; an elaboration check
in the unit verifies it covers `MAXLAT`.

### 3.3 Datapaths

- **Add** (3 stages). S1: classify, and compute per-operand alignment shift
  amounts from the exponents. The subnormal bit length is scanned on the
  mantissa in parallel. S2: one bidirectional shift per operand; the
  alignment sticky goes into the subtractor carry-in; both difference
  directions are computed in parallel and selected by the borrow. S3:
  leading-one normalize and round. The subnormal candidate is shifted
  directly from the pre-normalization sum by `e_max - EMIN`, independent of
  the leading-one position. Increment, exponent and overflow candidates are
  computed in parallel with the round decision. Every stage is close to the
  clock (S1 slack +0.279 ns at 5.6 ns), so a 2-cycle add would need a
  different structure (section 9).
- **Multiplier core**: LUT-only partial-product tree (no DSP inference),
  2 pipeline stages for W_MANT + 1 <= 32, else 3; shared by MUL and FMA.
- **FMA**: exact sum in a 3p+6-bit accumulator anchored at the larger
  exponent, single rounding. The subnormal candidate is computed from the
  pre-normalization accumulator (as in add), so round and encode take one
  stage.
- **SRT division / square root**: fully unrolled radix-4 digit
  recurrences, one start per cycle.
  - Division: u' = 4u - 4dD, d in {-2..2}, digit selection from 4
    thresholds per 1/32 divisor cell.
  - Square root: R' = 16R + bits - d(8q + d), d in {-4..4}, with the
    digit round(p/(8q)) chosen from the carry-save estimate by threshold
    compares. The non-restoring bound |R| <= 2q gives the tolerance.
  - Both convert digits on the fly into Q and QM = Q - 1, so negative
    digits need no borrow.
  - **Fixed-width carry-save**: S and C are kept modulo 2^CSW (division
    `CSW = S_W + 4`, sqrt `2*NDIG + 5`). The recurrence is linear, so S + C
    stays congruent to the true residual, the wrapped estimate window equals
    the exact one, and the residual is recovered once, at the end.
    `verification/srt/*_model.py` checks the widths (exhaustively at small
    widths; S_W + 3 fails for division).
  - The sqrt update -d(8q + d) needs no adder: 8q + d = {q, d} for d > 0
    and {qm, 8 - |d|} for d < 0, fed through two 3:2 levels, with the
    negation's +1s in the zero carry LSBs.
  - Parameters: `DPS` digits per stage; `STAGE_FOLD` folds S + C at each
    stage boundary (default for DPS >= 2, so the next stage's first estimate
    needs no add); `FOLD_STG` registers the final fold separately from
    rounding. `jsm_fp_pkg::srt_div_dps/srt_fold_stg` map `DIVSQRT_IMPL`
    to them: 1 uses division DPS 2 with stage folds and sqrt DPS 1;
    3 uses DPS 1, no stage folds and `FOLD_STG` for both.
- **Iterative engine** (`DIVSQRT_IMPL = 2`): one radix-4 div/sqrt in flight,
  latency floor((W_MANT + 3) / 2) + 3.
- **`W_MANT = 0`**: separate combinational modules. Verilator 5.020 crashes
  on the generic subnormal logic at 1-bit fraction width. The p = 1
  rounding rules are explicit: a tie goes to the larger magnitude under RNE.

### 3.4 Wrappers

- **`jsm_fp_unit_axilite`**: register file, a GO-edge-triggered sequencer
  that holds the request until `in_ready`, and AXI4-Lite channels. BVALID
  and RVALID are set at the address handshake and held until READY, and the
  read data is registered there, so READY may come first and data stays
  stable.
- **`jsm_fp_unit_axis`**: a two-register skid buffer (the unit's inputs come
  straight from a register, and `s_axis_tready` is registered) and a
  reorder buffer of `ROB_N` entries. The issue slot is
  the unit's tag. Results are written into their slot in completion order,
  read out from the head in request order, and a slot is freed when its
  result leaves. Issue requires a free slot, so output backpressure can
  never drop a result. TUSER/TLAST are stored per slot at issue.
- **`rtl/top/`**: plain-port Verilog-2001 tops with `X_INTERFACE_*`
  attributes, and VHDL tops instantiating them as components.
  `jsm_fp_unit_flat.sv` casts plain vectors to the native core's enum ports.

## 4. Verification

### 4.1 Harnesses

| harness | what | command |
|---------|------|---------|
| cocotb `tests/test_fp_unit.py` | directed vectors written by hand, randomized ops, reserved encodings; 8 formats | `make regress-all` |
| cocotb `test_fp_unit_axilite.py`, `test_fp_unit_axis.py` | wrapper protocols (incl. READY before VALID, output stalls, throughput, latency), random ops | `make regress-axilite`, `make regress-axis` |
| same suites through the Verilog tops | | `make regress-tops` |
| `tests/exhaustive.py` | every operand pair x 5 rm x 16 ops, all 8-bit formats (C++ driver) | `make exhaustive` |
| `tests/soak.py` | millions of boundary-biased random vectors, medium formats and binary64 | `make soak` |
| `tests/stream.py` | a request every cycle, backpressure, out-of-order tags, `OPS_EN` subset | `make stream` |
| `tests/latency.py` | per-op latency table, constant across operand classes | `make metrics-latency` |
| `verification/srt/run_diff.py` | SRT modules vs combinational div/sqrt, streaming, any `DPS`/`FOLD_STG`/`STAGE_FOLD` | `make srt-diff` |
| `tests/bf16.py`, `test_fp_exp_seq.py` | the helper modules | `make bf16`, `make regress-exp` |
| `formal/` | properties of the combinational datapaths; add/mul pipelines equal to their references (all inputs, E4M3/bfloat16/binary16) | `make formal`, `make formal-equiv` |
| `tests/vivado/run_xsim.py` | Verilog and VHDL tops of all three interfaces side by side in xsim vs the oracle | `make xsim-tops` |
| `syn/` scripts | implementation, tops as design top, block-design references, packaged IP | `make vivado`, `vivado-top`, `vivado-bd-check`, `ip-check` |

Simulations run with `--assert`. The C++ harnesses cache Verilated builds
and expected-result files under `*_build/`, keyed by a hash of the RTL,
the model and the harness (`FORCE_REBUILD=1` overrides).

### 4.2 Gates before a change is merged

`make check-all` (lint, the cocotb suites, exhaustive, soak, stream, SRT
differential), `make check-iter` and `make check-ds3` (the other div/sqrt
builds), `make formal formal-equiv` when a datapath changed, and
`make xsim-tops ip-check vivado` when a wrapper, a top or timing changed.
Line coverage (`make coverage`) was 91 % at the last refresh; the gaps are
constant-generate branches a given build does not select.

### 4.3 How tests have been made to fail

Every new harness was checked against a deliberately broken RTL or
property: formal against a one-bit output mutant (sby passes vacuously at
depth 0); the AXI4-Stream tests against a reorder buffer without its full
check; the directed sqrt vectors against the old 3-bit digit counter.
Keep doing this for new tests.

## 5. Coding rules (tool compatibility)

The RTL must stay readable by Vivado (synthesis and xsim), Verilator 5.020
and Yosys 0.68. Each rule below comes from a real failure.

- **Yosys**: no `return` in functions (assign the function name); no
  assignment patterns `'{field: ...}` (assign fields); no initialized
  declarations inside `always` blocks; no module-level variables of a
  package type (`jsm_fp_pkg::op_t x;`: use plain vectors and cast at the
  port); no package constants in parameter overrides (use literals);
  constant loop bounds and no `break` (use last-set-bit-wins scans and mask
  reductions); write `~(N'(x))`, not `~N'(x)` (Yosys applies `~` to the
  size). Give Yosys only the files of the top being built.
- **Vivado xsim**: a signal used only as a part-select index inside a
  called function (`f(v, w)` with `v[w*32 +: 32]`) is left out of the
  `always_comb` / `always @*` sensitivity. Compute such selects in
  continuous assignments.
- **Verilator 5.020**: replications with non-literal counts cannot be the
  first or a middle item of a concatenation; the V3Gate optimizer crashes at
  `W_MANT = 0` on the generic datapaths (hence the `*_e8m0` modules); the
  multiplier does not build at `W_MANT = 112`. Lint is `-Wall` clean; waive
  locally with `lint_off` and a comment.
- **SystemVerilog precedence**: `+`/`-` bind tighter than `<<`; write
  `((N'(1) << k) - 1)`.
- **Elaboration checks**: invalid parameters stop elaboration with
  `$error` in a generate `if` (Vivado, Verilator and Yosys honour it), not
  with an `initial $fatal`, which only fires in simulation.
- **Vivado interface attributes**: in Verilog on the ports; in VHDL in the
  architecture (Vivado ignores them in the entity, where the VHDL standard
  wants them, so strict tools need a relaxed mode). VLNVs:
  `xilinx.com:interface:aximm:1.0`, `xilinx.com:interface:axis:1.0`,
  `xilinx.com:signal:clock:1.0`, `xilinx.com:signal:reset:1.0`.
- **IP packaging**: integer parameter defaults must be plain decimal
  integers in the Verilog tops (a sized literal makes the packager treat
  the parameter as a bit string).

## 6. Toolchain and environment

- Verilator 5.020 (Ubuntu 24.04 package), cocotb 1.9.2 (`cocotb < 2`,
  which needs Verilator >= 5.036), Python 3.13 via uv (`uv sync`,
  `uv run`).
- `tests/run_regression.py` patches cocotb 1.9.2's `verilator.cpp` in the
  venv on every run, so Verilator's time advances; without the patch every
  `Timer` wait stalls. It also retries a width if the simulator hangs at
  start-up (a rare cocotb 1.9.2 + Verilator 5.020 race).
- GNU make must come first on PATH: another `make` (for example a vendor
  tool's) breaks Verilator's `--build` and the cocotb runner.
- oss-cad-suite (SymbiYosys, Yosys, bitwuzla, GHDL) for `make formal`
  (`OSS=<suite root>` if it is not on PATH); Vivado on PATH for the Vivado
  targets (`VIVADO_SETTINGS=<settings64.sh>` for `run_xsim.py`).
- Do not kill simulations with `pkill -f <path>`: the pattern also matches
  the calling shell. Use `pgrep -x`.

## 7. Adding an operation

1. **Specify**: quote the clause and write down the NaN, signed-zero,
   infinity, subnormal and `W_MANT = 0` behaviour first.
2. **Model**: add the function to `tests/reference/ops.py` and to
   `dispatch()`, and the opcode to `formats.py` (`OP_*`, `OP_NAMES`,
   `NUM_OPS`). Check the model against brute-force enumeration on the 8-bit
   formats where possible.
3. **Directed vectors**: write the expected values by hand (signed zeros,
   min/max subnormal, min normal, one, max finite, infinities, qNaN with
   payload, sNaN, mixed pairs) and make the model agree.
4. **RTL**: a `*_pipe.sv` with the `start / y / flags / [cmp] / out_valid`
   shape of the existing 1-cycle pipes; the enum value in `jsm_fp_pkg.sv`;
   in `jsm_fp_unit.sv` the start strobe, `lat_sel` entry, output mux,
   `OPS_EN` gating and the latency function; the file in
   `rtl/filelist.f`.
5. **Tests**: `test_directed_<op>` and a random test. The exhaustive
   sweep, soak, stream, latency probe, the AXI tests and the xsim
   testbenches pick the op up through `NUM_OPS`, `OP_NAMES` and
   `dispatch()`.
6. **Documentation**: the opcode, latency and semantics in the user guide.
7. **Gates**: section 4.2.

The 4-bit opcode space is full (section 9).

## 8. Measured results

The user guide (section 9.5) has the current Vivado numbers; `metrics/`
holds the reports of the default build. The history behind them, in short:
the original combinational design reached 17.6 ns. Pipelining every
operation closed 4.0 ns with an iterative div/sqrt engine. The SRT
pipelines raised throughput but needed 5.6 ns until the fixed-width
carry-save change brought a fully pipelined 4.0 ns build back
(`DIVSQRT_IMPL = 3`).

## 9. Future work

- **Opcode space**: all 16 codes are used. New operations need `op_t`
  widened to 5 bits (codes 0-15 unchanged; `OPS_EN` to 32 bits; the AXI4-Lite
  OPCODE register can take `op[4]` in its free bit 7, keeping the map
  compatible; the AXI4-Stream TDATA layout has a free bit at `3*OPB + 7`).
- **Signaling comparisons** (5.6.1): an `OP_CMPS` identical to `OP_CMP`
  except that any NaN signals invalid; about 2 LUTs in `jsm_fp_cmp_pipe`.
  Reusing `OP_CMP` with an `rm` variant would change existing behaviour.
- **Integer conversions** (5.4.1, 5.8): an `INT_W` parameter, signed and
  unsigned opcodes, the Exact variants; fp-to-int is a wider
  `jsm_fp_roundint_pipe` (shift, round, negate, saturate), int-to-fp is
  abs, LZC, shift and round; about 2 cycles and 1,200 LUTs at
  binary32/int32. Restrict to `INT_W <= W` first, to keep the port widths.
- **Format conversions** (5.4.2): a second format parameter pair and two
  opcodes; widening is exact (normalize subnormals, quiet sNaN), narrowing
  rounds. Factor the rounding back end of the pipes into a shared
  `round_pack` module first.
- **scaleB / logB** (5.3.3): two opcodes, N in `b`, clamped; logB fits
  `jsm_fp_misc_pipe`, scaleB is the multiplier's post-normalization (about
  2 cycles).
- **remainder** (5.3.1): the quotient can need up to EMAX - EMIN + p bits,
  so the latency depends on the data. That breaks the fixed-latency result
  port. An iterative engine that waits for a free `resv[0]` slot before
  delivering keeps the other latencies fixed.
- **2-cycle add**: needs a dual-path (near/far) adder with leading-zero
  anticipation, since every current stage is near the clock.
