"""Exact rounding of rational values to a binary format (clauses 4.3, 7.4-7.6).

This implements the specification-level rounding:
  * result = round(value) per the rounding-direction attribute (4.3),
  * overflow per 7.4 (flagged iff the rounded result with unbounded exponent
    range exceeds the largest finite number),
  * underflow per 7.5 with tininess detected AFTER rounding (the rounded,
    unbounded-range result is a non-zero value strictly between +-b^emin,
    plus the result must be inexact),
  * inexact per 7.6.
"""

from __future__ import annotations

from fractions import Fraction

from .formats import (
    FLAG_INEXACT,
    FLAG_OVERFLOW,
    FLAG_UNDERFLOW,
    MODE_RM,
    MODE_RNA,
    MODE_RNE,
    MODE_RP,
    MODE_RZ,
    BinFormat,
    encode_finite,
    encode_inf,
    encode_zero,
    max_finite_bits,
)


def _round_up(rm: int, sign: int, r: Fraction, m: int) -> bool:
    """Rounding-decision for a remainder r in [0, 1) below a significand m."""
    if r == 0:
        return False
    if rm == MODE_RNE:
        half = Fraction(1, 2)
        if r > half:
            return True
        if r == half:
            return bool(m & 1)
        return False
    if rm == MODE_RNA:
        return r >= Fraction(1, 2)
    if rm == MODE_RZ:
        return False
    if rm == MODE_RP:
        return sign == 0
    if rm == MODE_RM:
        return sign == 1
    raise AssertionError(f"invalid rounding mode {rm}")


def round_to_format(sign: int, value: Fraction, rm: int, fmt: BinFormat) -> tuple[int, int]:
    """Round the exact value to fmt per attribute rm.

    Args:
        sign: sign bit used only for an exactly-zero value (the caller decides
              it per clause 6.3); nonzero values carry their own sign.
        value: exact rational result.
        fmt: destination format.

    Returns (encoded bits, flags).
    """
    flags = 0
    if value == 0:
        return encode_zero(sign, fmt), flags

    s = 1 if value < 0 else 0
    v = -value if s else value

    # Leading exponent n: v in [2^n, 2^(n+1)).
    n = v.numerator.bit_length() - 1 - (v.denominator.bit_length() - 1)
    if v < Fraction(2) ** n:
        n -= 1
    elif v >= Fraction(2) ** (n + 1):
        n += 1

    # Round to p bits with unbounded exponent range (4.3).
    scaled = v * (Fraction(2) ** (fmt.p - 1 - n))
    m = scaled.numerator // scaled.denominator  # p bits, MSB set
    r = scaled - m
    m2 = m + (1 if _round_up(rm, s, r, m) else 0)
    if m2 == 1 << fmt.p:  # carry out of the significand
        m2 >>= 1
        n += 1
    inexact = r != 0
    rounded = Fraction(m2) * (Fraction(2) ** (n + 1 - fmt.p))  # rounded with unbounded range

    # Overflow (7.4): rounded result exceeds the largest finite number.
    if rounded > fmt.max_finite:
        if rm in (MODE_RNE, MODE_RNA):
            bits = encode_inf(s, fmt)
        elif rm == MODE_RZ:
            bits = max_finite_bits(s, fmt)
        elif rm == MODE_RP:
            bits = encode_inf(0, fmt) if s == 0 else max_finite_bits(1, fmt)
        else:  # MODE_RM
            bits = encode_inf(1, fmt) if s == 1 else max_finite_bits(0, fmt)
        return bits, flags | (1 << FLAG_OVERFLOW) | (1 << FLAG_INEXACT)

    if n >= fmt.emin:
        # Normal result.
        bits = encode_finite(s, n + fmt.bias, m2 - (1 << fmt.W_MANT), fmt)
        if inexact:
            flags |= 1 << FLAG_INEXACT
        return bits, flags

    # Subnormal result: re-round on the subnormal grid (ulp = 2^(emin-W_MANT)).
    ulp = fmt.emin - fmt.W_MANT
    scaled = v * (Fraction(2) ** -ulp)
    m = scaled.numerator // scaled.denominator
    r = scaled - m
    m2 = m + (1 if _round_up(rm, s, r, m) else 0)
    inexact = r != 0
    if m2 >= 1 << fmt.W_MANT:
        # Rounds up to the smallest normal number.
        bits = encode_finite(s, 1, 0, fmt)
        tiny = False
    elif m2 == 0:
        bits = encode_zero(s, fmt)
        tiny = False
    else:
        bits = encode_finite(s, 0, m2, fmt)
        tiny = True
    # Underflow (7.5, tininess after rounding): tiny non-zero rounded result
    # (strictly between +-2^emin) that is inexact.
    if tiny and inexact:
        flags |= 1 << FLAG_UNDERFLOW
    if inexact:
        flags |= 1 << FLAG_INEXACT
    return bits, flags
