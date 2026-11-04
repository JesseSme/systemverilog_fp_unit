# 02: Integer conversions (5.4.1 convertFromInt, 5.8 convertToInteger)

## Operations

- `convertFromInt(int)`: integer to the unit's format, rounded per `rm`
  (inexact when the integer has more significant bits than the format's
  precision, overflow only for formats with a tiny exponent range, e.g. E4M3
  with int32).
- `convertToIntegerTiesToEven / TowardZero / TowardPositive / TowardNegative
  / TiesToAway` (5.8): one op with the rounding direction taken from `rm`.
  It does **not** signal inexact.
- `convertToIntegerExact*`: the same, but signals inexact when the result
  differs from the operand (mirror of `OP_RNDINT` / `OP_RNDINTX`).
- Invalid (7.2 j): NaN, infinity, or a value outside the integer range. The
  standard leaves the result unspecified; recommended: saturate to the
  integer's min/max, NaN gives the max positive value (the RISC-V F
  convention, so a soft-float reference exists).

## Interface

The integer width and signedness are new parameters of the operation:

- Parameter `INT_W` (default 32; 0 disables both conversions at build
  time, like `OPS_EN`).
- Signed / unsigned from the opcode: `OP_CVTFI` (int to fp, signed),
  `OP_CVTFU` (unsigned), `OP_CVTIF` (fp to int, signed), `OP_CVTUF`
  (unsigned). Four opcodes. The Exact variants take a sub-op bit: since the
  rounding direction already uses `rm`, use `rm[2:0]` = direction and a new
  1-bit request field `exact`, or (simpler, recommended) two more opcodes
  `OP_CVTIFX`/`OP_CVTUFX`, six opcodes in all.
- Port widths: the integer operand arrives in `a` and the integer result
  leaves in `y`. That works only if `INT_W <= W` (binary32 with int32,
  binary64 with int64). For narrower formats (binary16 with int32, the
  8-bit formats) `a`/`y` would need widening to `DATA_W = max(W, INT_W)`,
  which changes every port of `fp_unit` and the AXI register widths.
  Recommended: support `INT_W <= W` only in a first version, and assert it
  at elaboration; AXI-Lite already accesses wide operands as several
  32-bit words, so a later `DATA_W` change is contained there.

## Datapath

- fp to int: unpack, right shift by `(W_MANT - e)` (barrel shifter of
  `max(S_W, INT_W) + 2` bits, guard/round/sticky out), round with the
  `fp_roundint_pipe` rounding logic, negate for negative values, range
  check and saturate. Same structure as `fp_roundint_pipe`, with a wider
  shifter and the negation: **2 cycles** (shift | round+negate+saturate).
- int to fp: absolute value, leading-zero count of `INT_W` bits, left
  shift, round to `S_W` bits (the rounding back end of `fp_add_pipe` S3),
  exponent = `INT_W - 1 - lzc + BIAS`, overflow check: **2 cycles** (abs+lzc
  | shift+round). An LZC plus normalize shift at 32 bits fits one 5.6 ns
  stage. At 4.0 ns, use 3 cycles (lzc | shift | round).

## Cost (binary32, int32)

- fp to int: about 1.2 x `fp_roundint_pipe` = 550 LUTs, 150 FFs.
- int to fp: about 0.6 x `fp_add_pipe` (one shifter, LZC and rounding;
  no alignment shifter, no adder) = 650 LUTs, 150 FFs.
- Total about 1,200 LUTs (+9 % of `fp_unit`), latency 2 for every variant.
- Tests: the oracle needs `convert_from_int` / `convert_to_int` (exact with
  Python ints and the existing `round_*` helpers). The exhaustive sweep is
  impossible over 32-bit ints; use the 8-bit formats with `INT_W = 8`
  (exhaustive, 2^8 operands per op) plus random binary32/int32 vectors.
