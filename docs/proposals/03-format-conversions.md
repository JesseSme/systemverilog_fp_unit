# 03: Format conversions (5.4.2 convertFormat)

## Operations

`formatOf-convertFormat(source)` between the unit's format F = (W_EXP,
W_MANT) and a second format G = (G_EXP, G_MANT):

- **Widening** (G has a wider exponent range and precision, e.g. binary16
  to binary32): always exact. A subnormal source becomes a normal result
  (normalize: LZC + shift), an sNaN is quieted with invalid, and NaN
  payloads are kept (left-aligned, 6.2.3).
- **Narrowing** (e.g. binary32 to binary16, binary32 to bfloat16): rounds per
  `rm` and can overflow, underflow (subnormal results, tininess after
  rounding as everywhere else in this unit) or be inexact. NaN payloads are
  truncated, and a payload that truncates to 0 is replaced by the quiet bit.
- Mixed cases (wider exponent, narrower precision, e.g. binary16 to
  bfloat16) are a narrowing in precision and a widening in range, so they
  use the narrowing datapath.

`rtl/fp32_to_bf16_round.sv` (RNE only, no flags) is a special case of this
operation and could be replaced by it.

## Interface

`fp_unit` has one format, so G must be a build parameter: `G_EXP`,
`G_MANT` (`G_EXP = 0` disables the conversion ops). Two opcodes:

- `OP_CVT_FG` (F to G): `a` holds an F value, `y` returns a G value.
- `OP_CVT_GF` (G to F): `a` holds a G value in its low `1+G_EXP+G_MANT`
  bits, `y` returns an F value.

As with the integer conversions, the G value must fit in the `a`/`y` port:
`1+G_EXP+G_MANT <= W`. That covers the common uses: a binary32 unit
converting to and from binary16 / bfloat16 / E4M3 / E5M2, or a binary64 unit
to and from binary32. Several target formats (e.g. both bfloat16 and
binary16) would need one opcode pair per format, or a format-select field in
`rm` for these two ops (they need `rm` for rounding, so a new request field
would be needed; not recommended in a first version).

## Datapath

The rounding back end already exists in parameterized form in
`fp_add_pipe` (stage S3: normalize, round, overflow and subnormal handling)
and is duplicated in every pipe. Factor it into a shared `fp_round_pack`
module (significand + guard/round/sticky + exponent in, encoded result and
flags out), use it in the conversion and, later, in the existing pipes.

- Widening F to G (or G to F): unpack, LZC + shift for subnormal sources,
  exponent rebias, NaN quieting: no rounding. **1 cycle.**
- Narrowing: unpack, rebias, then `fp_round_pack` with a right shift for
  subnormal results. **2 cycles** (unpack + shift | round + pack), like
  `fp_roundint_pipe`.
- Latency is fixed per opcode (1 or 2 depending on which direction narrows),
  so it fits the result-port reservation scheme unchanged.

## Cost (binary32 unit, G = binary16)

- Widening path: about 150 LUTs (LZC of 11 bits, shift, rebias).
- Narrowing path: about 400 LUTs (a 26-bit right shifter for the subnormal
  range, rounding, packing), similar to `fp_roundint_pipe` (442).
- Total about 550 LUTs (+4 %). With G = bfloat16 the narrowing shifter is
  shorter (bfloat16 has binary32's range): about 300 LUTs.
- Tests: the oracle's `round_to_format` does the narrowing directly. With F
  an 8-bit format and G binary16 (or the reverse), the sweep is exhaustive
  over all F values, and 2^16 G values x 5 rm.
