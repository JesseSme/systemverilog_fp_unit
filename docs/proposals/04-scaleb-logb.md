# 04: scaleB and logB (5.3.3)

## Operations

- `scaleB(x, N)` = x * 2^N, rounded: exact unless the result overflows or
  becomes subnormal (then it rounds per `rm`, with overflow/underflow/inexact
  as usual). N is an integer (`logBFormat`, 5.3.3); NaN propagates (an sNaN is
  quieted with invalid), and infinity and zero are returned unchanged.
- `logB(x)` = floor(log2 |x|) as an integer: the unbiased exponent of x,
  with subnormals normalized (logB(min subnormal) = emin - W_MANT). For
  `logB(NaN)`, `logB(inf)` and `logB(0)` with an integer logBFormat, 5.3.3
  requires invalid and a language-defined result outside
  +-2*(emax + p - 1).
  Recommended: NaN and inf give +max integer, 0 gives -max integer (the C
  `ilogb` FP_ILOGBNAN / FP_ILOGB0 convention as INT_MAX / INT_MIN).

## Interface

Two opcodes, `OP_SCALEB` and `OP_LOGB`.

- N for scaleB is carried in `b` as a two's-complement integer. Only
  `NW = W_EXP + ceil(log2(W_MANT + 2)) + 2` bits matter: any |N| larger than
  `2 * (EMAX + W_MANT + 1)` saturates to overflow or underflow, so the
  datapath clamps N to that range. `NW <= W` for every format with
  `W_MANT >= 1`, so `b` is wide enough (E8M0: NW = 10 > 8, so clamp there to
  the 8-bit signed range; still enough to reach both ends of E8M0's range).
- logB returns the integer in the low bits of `y`, sign-extended to `W` bits.

## Datapath

- logB: an LZC over the W_MANT fraction bits (subnormals only) and a
  subtraction from the biased exponent. **1 cycle.** In the `fp_misc_pipe`
  style, so it can share that module (`OP_LOGB` as another case).
- scaleB: unpack (normalize a subnormal x: LZC + left shift), add the
  clamped N to the exponent, then the subnormal right shift + round + pack
  of the result. It is the multiplier's post-normalization without the
  product, so **2 cycles** (unpack + normalize + add | shift + round + pack),
  using the `fp_round_pack` back end proposed in note 03.

## Cost (binary32)

- logB: about 40 LUTs (5-bit LZC over 23 bits, 9-bit subtract), added to
  `fp_misc_pipe` (294 LUTs).
- scaleB: about 350 LUTs (normalize shifter, exponent adder, subnormal
  shifter, rounding), about 1/3 of `fp_mul_pipe` without the core.
- Total about 400 LUTs (+3 %).
- Tests: the oracle is short (`scaleB` = `round(x * 2^N)` with the existing
  rounding, `logB` = the exponent). The 8-bit sweep is exhaustive if b runs
  over all 256 values, which it does already (the sweep covers all (a, b)
  pairs); every N, including the saturating ones, is then tested.
