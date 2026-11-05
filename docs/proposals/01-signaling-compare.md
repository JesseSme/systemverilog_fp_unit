# 01: Signaling comparisons (5.6.1)

## What is missing

IEEE 754-2019 5.6.1 defines each comparison predicate twice: quiet
(compareQuiet*, invalid only for a signaling NaN, which `OP_CMP` implements)
and signaling (compareSignaling*: compareSignalingEqual, Greater,
GreaterEqual, Less, LessEqual, and their negations). The signaling forms
must signal invalid when **either operand is any NaN** (5.11, 7.2c). The
standard requires both families (5.6.1 lists the signaling predicates as
required operations; C's `<`, `<=`, `>`, `>=` map to them).

Because `jsm_fp_unit` returns a condition code (`cmp` = LT/EQ/GT/UN) instead of
one predicate, a single op covers every predicate of one family. The two
families differ only in the invalid flag.

## Interface options

1. **`OP_CMP` with a sub-op in `rm`** (`rm = 1`: signaling). It needs no new
   opcode, but it changes the behaviour of existing code that passes a
   non-zero `rm` to `OP_CMP` today (the README documents `rm` as unused for
   comparisons, so such callers exist in principle, e.g. software that
   leaves the last rounding mode in the OPCODE register). Not recommended.
2. **New opcode `OP_CMPS = 16`** (needs the 5-bit opcode space, see
   README.md). `cmp` is the same as `OP_CMP`; `flags[invalid]` is set if
   `a` or `b` is a NaN. Recommended.

## Implementation

`jsm_fp_cmp_pipe`: add an input `signaling` (`mode == OP_CMPS`) and replace

    invalid = a_snan | b_snan

with

    invalid = signaling ? (a_nan | b_nan) : (a_snan | b_snan)

The classification signals exist already. In `jsm_fp_unit`, `OP_CMPS` shares the
`g_cmp` pipeline (enabled when `OPS_EN[OP_CMP] | OPS_EN[OP_CMPS]`), with
latency 1 like `OP_CMP`. E8M0 uses the same generic `jsm_fp_cmp`, whose
classification has no NaN when `W_MANT = 0` (0xFF classifies as infinity
there), so both ops behave identically in E8M0 unless that classification
is changed too.

Reference model: `ops.jsm_fp_cmp(..., signaling=True)` and an entry in the OP
table; the exhaustive sweep then covers it at every 8-bit format.

## Cost

- Latency: 1 cycle (same pipeline).
- Area: about 2 LUTs (one 2:1 select on the invalid bit). The opcode-space
  widening (README.md) is the only other cost.
- Tests: directed vectors for qNaN/sNaN x {a, b} under both ops; formal:
  add "OP_CMPS invalid == a_nan | b_nan" and "cmp(OP_CMPS) == cmp(OP_CMP)"
  to `formal/fp_m6_props.sv` (binary16, depth 1).
