"""Operation reference models (clause 5): exact semantics per IEEE 754-2019.

Each op decodes its operands, resolves special cases (NaNs 6.1/6.2, infinities,
zeros and their signs 6.3), computes the infinitely precise result, and rounds
it with round_to_format (clause 4.3). This is the bit-exact oracle for the RTL.

Shared choices (mirror the RTL):
  * NaN results: quiet NaN with sign 0 and the payload of the first NaN
    operand (6.2.3, 6.3: the sign of a NaN result is not specified).
  * Invalid operation is signaled for any signaling NaN operand (7.2a).
"""

from __future__ import annotations

import math
from fractions import Fraction

from .formats import (
    CMP_EQ,
    CMP_GT,
    CMP_LT,
    CMP_UN,
    FLAG_DIV0,
    FLAG_INEXACT,
    FLAG_INVALID,
    FLAG_OVERFLOW,
    FLAG_UNDERFLOW,
    INF,
    MODE_RM,
    MODE_RNE,
    MODE_RNA,
    MODE_RP,
    MODE_RZ,
    QNAN,
    SNAN,
    ZERO,
    BinFormat,
    decode,
    encode_finite,
    encode_inf,
    encode_nan,
    encode_zero,
    max_finite_bits,
)
from .rounding import _round_up, round_to_format


def _nan_result(a_cls, a_payload, b_cls, b_payload, fmt: BinFormat) -> tuple[int, int]:
    flags = (1 << FLAG_INVALID) if a_cls == SNAN or b_cls == SNAN else 0
    payload = a_payload if a_cls in (QNAN, SNAN) else b_payload
    return encode_nan(payload, fmt), flags


def fp_add(a_bits: int, b_bits: int, rm: int, fmt: BinFormat, sub: bool = False) -> tuple[int, int]:
    """addition / subtraction (5.4.1). sub selects x - y."""
    a_cls, a_s, a_v, a_pay = decode(a_bits, fmt)
    b_cls, b_s, b_v, b_pay = decode(b_bits, fmt)
    if sub:
        b_s ^= 1
        b_v = -b_v if b_v is not None else None

    # NaN handling (6.2.3, 7.2a).
    if a_cls in (QNAN, SNAN) or b_cls in (QNAN, SNAN):
        return _nan_result(a_cls, a_pay, b_cls, b_pay, fmt)

    # Infinity (7.2d: magnitude subtraction of infinities is invalid).
    if a_cls == INF or b_cls == INF:
        if a_cls == INF and b_cls == INF:
            if a_s == b_s:
                return encode_inf(a_s, fmt), 0
            return encode_nan(0, fmt), 1 << FLAG_INVALID
        return (encode_inf(a_s, fmt), 0) if a_cls == INF else (encode_inf(b_s, fmt), 0)

    # Zero (6.3).
    if a_cls == ZERO and b_cls == ZERO:
        # Exact zero sum: like-sign addends keep that sign; opposite-sign
        # addends give +0, or -0 under roundTowardNegative.
        if a_s == b_s:
            return encode_zero(a_s, fmt), 0
        return encode_zero(1 if rm == MODE_RM else 0, fmt), 0
    if a_cls == ZERO:
        return b_bits if not sub else _flip_sign(b_bits, fmt), 0
    if b_cls == ZERO:
        return a_bits, 0

    value = a_v + b_v
    if value == 0:
        # Exact cancellation of opposite-sign addends (6.3).
        return encode_zero(1 if rm == MODE_RM else 0, fmt), 0
    sign = 1 if value < 0 else 0
    return round_to_format(sign, value, rm, fmt)


def fp_mul(a_bits: int, b_bits: int, rm: int, fmt: BinFormat) -> tuple[int, int]:
    """multiplication (5.4.1)."""
    a_cls, a_s, a_v, a_pay = decode(a_bits, fmt)
    b_cls, b_s, b_v, b_pay = decode(b_bits, fmt)
    sign = a_s ^ b_s  # the sign of a product is the XOR of the signs (6.3)

    # NaN handling (6.2.3, 7.2a).
    if a_cls in (QNAN, SNAN) or b_cls in (QNAN, SNAN):
        return _nan_result(a_cls, a_pay, b_cls, b_pay, fmt)

    # Infinity (7.2e: infinity x zero is invalid).
    if a_cls == INF or b_cls == INF:
        if a_cls == ZERO or b_cls == ZERO:
            return encode_nan(0, fmt), 1 << FLAG_INVALID
        return encode_inf(sign, fmt), 0

    # Zero (6.3): the sign of a product of zeros is the XOR of the signs;
    # unlike addition there is no roundTowardNegative sign quirk for products.
    if a_cls == ZERO or b_cls == ZERO:
        return encode_zero(sign, fmt), 0

    return round_to_format(sign, a_v * b_v, rm, fmt)


def fp_div(a_bits: int, b_bits: int, rm: int, fmt: BinFormat) -> tuple[int, int]:
    """division (5.4.1)."""
    a_cls, a_s, a_v, a_pay = decode(a_bits, fmt)
    b_cls, b_s, b_v, b_pay = decode(b_bits, fmt)
    sign = a_s ^ b_s  # the sign of a quotient is the XOR of the signs (6.3)

    # NaN handling (6.2.3, 7.2a).
    if a_cls in (QNAN, SNAN) or b_cls in (QNAN, SNAN):
        return _nan_result(a_cls, a_pay, b_cls, b_pay, fmt)

    # Infinity (7.2f: magnitude division of infinities is invalid).
    if a_cls == INF or b_cls == INF:
        if a_cls == INF and b_cls == INF:
            return encode_nan(0, fmt), 1 << FLAG_INVALID
        return (encode_inf(sign, fmt), 0) if a_cls == INF else (encode_zero(sign, fmt), 0)

    # Zero (7.2f: 0/0 is invalid; 7.3: x/0 is division by zero).
    if a_cls == ZERO or b_cls == ZERO:
        if a_cls == ZERO and b_cls == ZERO:
            return encode_nan(0, fmt), 1 << FLAG_INVALID
        return (encode_zero(sign, fmt), 0) if a_cls == ZERO else (encode_inf(sign, fmt), 1 << FLAG_DIV0)

    return round_to_format(sign, a_v / b_v, rm, fmt)


def _isqrt_scaled(p: int, q: int, j: int) -> int:
    """floor(sqrt(p/q) * 2^j) for positive ints p, q and any int j, exactly.

    Uses the identity floor(sqrt(p/q) * 2^j) = floor(sqrt(p * 2^(2j) / q)) and
    the integer isqrt; for j < 0 the reciprocal power is moved into the
    denominator.
    """
    if j >= 0:
        return math.isqrt(p * (1 << (2 * j)) * q) // q
    den = q << (2 * -j)
    return math.isqrt(p * den) // den


def _sqrt_round(value: Fraction, rm: int, fmt: BinFormat) -> tuple[int, int]:
    """Bit-exact rounding of sqrt(value) to fmt per attribute rm.

    sqrt(value) is irrational unless value is the square of a dyadic
    rational, so the rounding is decided by exact integer comparisons: the
    integer isqrt gives the significand, and the remainder is compared
    against 0 and the half-way point by squaring both sides (no floating
    point, no ties approximated). Mirrors round_to_format's control flow.
    """
    p, q = value.numerator, value.denominator
    flags = 0
    s = 0

    # Leading exponent n of sqrt(p/q): 2^n <= sqrt(p/q) < 2^(n+1).
    # Find the largest n with p/q >= 2^(2n) using exact Fraction comparisons
    # (avoids Python's negative-shift restriction on the initial estimate).
    v2 = Fraction(p, q)
    n = (p.bit_length() - q.bit_length() - 1) // 2
    while v2 < Fraction(2) ** (2 * n):
        n -= 1
    while v2 >= Fraction(2) ** (2 * (n + 1)):
        n += 1

    def round_signif(j: int):
        """Significand (and remainder indicator) of sqrt(p/q) scaled by 2^j."""
        m = _isqrt_scaled(p, q, j)
        vs = Fraction(p, q) * (Fraction(2) ** (2 * j))
        m2 = Fraction(m * m)
        half = Fraction((2 * m + 1) * (2 * m + 1), 4)
        if vs == m2:
            r = 0
        elif vs == half:
            r = Fraction(1, 2)
        elif vs > half:
            r = Fraction(1)  # sentinel: strictly above the half-way point
        else:
            r = Fraction(1, 4)  # sentinel: strictly below
        up = _round_up(rm, s, r, m)
        return m + (1 if up else 0), r != 0

    m2, inexact = round_signif(fmt.p - 1 - n)
    if m2 == 1 << fmt.p:  # carry out of the significand
        m2 >>= 1
        n += 1
    rounded = Fraction(m2) * (Fraction(2) ** (n + 1 - fmt.p))

    # Overflow (7.4): unreachable for sqrt (sqrt(2^emax) <= 2^(emax/2)), kept
    # for structural consistency with round_to_format.
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
    m2s, inexact_s = round_signif(-ulp)
    if m2s >= 1 << fmt.W_MANT:
        bits = encode_finite(s, 1, 0, fmt)
        tiny = False
    elif m2s == 0:
        bits = encode_zero(s, fmt)
        tiny = False
    else:
        bits = encode_finite(s, 0, m2s, fmt)
        tiny = True
    if tiny and inexact_s:
        flags |= 1 << FLAG_UNDERFLOW
    if inexact_s:
        flags |= 1 << FLAG_INEXACT
    return bits, flags


def fp_sqrt(a_bits: int, rm: int, fmt: BinFormat) -> tuple[int, int]:
    """square root (5.4.1)."""
    a_cls, a_s, a_v, a_pay = decode(a_bits, fmt)

    # NaN handling (6.2.3, 7.2a).
    if a_cls in (QNAN, SNAN):
        return _nan_result(a_cls, a_pay, 0, 0, fmt)

    # Infinity (7.2g: sqrt of a negative number is invalid).
    if a_cls == INF:
        if a_s:
            return encode_nan(0, fmt), 1 << FLAG_INVALID
        return encode_inf(0, fmt), 0

    # Zero (6.3): sqrt(+-0) = +-0.
    if a_cls == ZERO:
        return encode_zero(a_s, fmt), 0

    # Negative finite number (7.2g).
    if a_s:
        return encode_nan(0, fmt), 1 << FLAG_INVALID

    return _sqrt_round(a_v, rm, fmt)


def fp_fma(a_bits: int, b_bits: int, c_bits: int, rm: int, fmt: BinFormat) -> tuple[int, int]:
    """fused multiply-add (5.4.1): (a x b) + c with a single rounding."""
    a_cls, a_s, a_v, a_pay = decode(a_bits, fmt)
    b_cls, b_s, b_v, b_pay = decode(b_bits, fmt)
    c_cls, c_s, c_v, c_pay = decode(c_bits, fmt)
    prod_sign = a_s ^ b_s

    # NaN handling (6.2.3, 7.2a): payload of the first NaN operand; invalid
    # if ANY operand is a signaling NaN.
    first_nan = None
    invalid = 0
    for cls, pay in ((a_cls, a_pay), (b_cls, b_pay), (c_cls, c_pay)):
        if cls in (QNAN, SNAN):
            if first_nan is None:
                first_nan = (cls, pay)
            if cls == SNAN:
                invalid = 1
    if first_nan is not None:
        return encode_nan(first_nan[1], fmt), (1 << FLAG_INVALID if invalid else 0)

    a_inf, b_inf = a_cls == INF, b_cls == INF
    a_zero, b_zero = a_cls == ZERO, b_cls == ZERO
    c_inf, c_zero = c_cls == INF, c_cls == ZERO

    # 7.2e: infinity x zero is invalid, regardless of c.
    if (a_inf and b_zero) or (a_zero and b_inf):
        return encode_nan(0, fmt), 1 << FLAG_INVALID

    # Product is an infinity of sign prod_sign.
    if a_inf or b_inf:
        if c_inf and c_s != prod_sign:
            # 7.2d: magnitude subtraction of infinities (inf + -inf).
            return encode_nan(0, fmt), 1 << FLAG_INVALID
        return encode_inf(prod_sign, fmt), 0

    # Finite product + infinity.
    if c_inf:
        return encode_inf(c_s, fmt), 0

    # Product is a zero of sign prod_sign.
    if a_zero or b_zero:
        if c_zero:
            # 6.3: exact zero sum of like-sign addends keeps that sign; of
            # opposite-sign addends it is +0, or -0 under roundTowardNegative.
            if prod_sign == c_s:
                return encode_zero(prod_sign, fmt), 0
            return encode_zero(1 if rm == MODE_RM else 0, fmt), 0
        return c_bits, 0  # 0 + c = c

    # a, b finite non-zero.
    if c_zero:
        # product + 0 = product, rounded once.
        return round_to_format(prod_sign, a_v * b_v, rm, fmt)

    value = a_v * b_v + c_v
    if value == 0:
        # Exact cancellation (6.3).
        return encode_zero(1 if rm == MODE_RM else 0, fmt), 0
    sign = 1 if value < 0 else 0
    return round_to_format(sign, value, rm, fmt)


def _minmax(a_bits: int, b_bits: int, fmt: BinFormat, is_max: bool) -> tuple[int, int]:
    """minimum / maximum (5.6.1)."""
    a_cls, a_s, a_v, a_pay = decode(a_bits, fmt)
    b_cls, b_s, b_v, b_pay = decode(b_bits, fmt)

    # A NaN operand produces a quiet NaN (payload of the first); sNaN -> invalid.
    if a_cls in (QNAN, SNAN) or b_cls in (QNAN, SNAN):
        return _nan_result(a_cls, a_pay, b_cls, b_pay, fmt)

    # Ordering key: -inf < finite < +inf. Use a rank tuple so the infinities
    # order strictly outside every finite value (decode returns None for both
    # zeros and infinities, so branch on the class).
    def key(cls, s, v):
        if cls == INF:
            return (-2 if s else 2, 0)
        if cls == ZERO:
            return (0, Fraction(0))
        return (0, v)

    ka, kb = key(a_cls, a_s, a_v), key(b_cls, b_s, b_v)
    if ka != kb:
        # pick a iff (a is the min) == (not is_max)
        return (a_bits if (ka < kb) == (not is_max) else b_bits), 0

    # Equal values: minimum(-0,+0) = -0, maximum(-0,+0) = +0 (5.6.1); equal
    # non-zero values (or equal infinities) return either operand.
    if a_cls == ZERO and b_cls == ZERO and a_s != b_s:
        pick_minus = not is_max
        return (a_bits if a_s == pick_minus else b_bits), 0
    return a_bits, 0


def fp_min(a_bits: int, b_bits: int, fmt: BinFormat) -> tuple[int, int]:
    return _minmax(a_bits, b_bits, fmt, is_max=False)


def fp_max(a_bits: int, b_bits: int, fmt: BinFormat) -> tuple[int, int]:
    return _minmax(a_bits, b_bits, fmt, is_max=True)


def fp_cmp(a_bits: int, b_bits: int, fmt: BinFormat) -> tuple[int, int, int]:
    """quiet comparison (5.11): returns (y=0, condition code, flags).

    -0 compares equal to +0; NaN is unordered. A quiet comparison signals
    invalid (7.2a) only for a signaling NaN operand. y is unused (0).
    """
    a_cls, a_s, a_v, a_pay = decode(a_bits, fmt)
    b_cls, b_s, b_v, b_pay = decode(b_bits, fmt)
    flags = (1 << FLAG_INVALID) if a_cls == SNAN or b_cls == SNAN else 0
    if a_cls in (QNAN, SNAN) or b_cls in (QNAN, SNAN):
        return 0, CMP_UN, flags
    if a_cls == ZERO and b_cls == ZERO:
        return 0, CMP_EQ, flags

    def key(cls, s, v):
        if cls == INF:
            return (-2 if s else 2, 0)
        if cls == ZERO:
            return (0, Fraction(0))
        return (0, v)

    ka, kb = key(a_cls, a_s, a_v), key(b_cls, b_s, b_v)
    cond = CMP_EQ if ka == kb else (CMP_LT if ka < kb else CMP_GT)
    return 0, cond, flags


def fp_totalorder(a_bits: int, b_bits: int, fmt: BinFormat) -> tuple[int, int, int]:
    """totalOrder (5.10): returns (y=0, cmp[0] = a precedes-or-equals b, 0).

    Non-strict: totalOrder(x, x) is true for identical encodings. The ordering
    (-qNaN < -sNaN < -inf < negative finite < -0 < +0 < positive finite < +inf
    < +sNaN < +qNaN, payloads as unsigned integers with the quiet bit the
    fraction MSB) is exactly the sign-magnitude integer order: for a negative
    encoding the magnitude is negated (low bits flipped), so -0 maps to -1 and
    +0 to 0. Never signals, even for a signaling NaN.
    """
    w = fmt.width
    signbit = 1 << (w - 1)
    lowmask = signbit - 1

    def signed_key(x):
        if x & signbit:
            return -((x & lowmask) + 1)
        return x

    return 0, (1 if signed_key(a_bits) <= signed_key(b_bits) else 0), 0


def fp_roundint(a_bits: int, rm: int, fmt: BinFormat) -> tuple[int, int]:
    """roundToIntegral (5.9).

    NaN: the operand quieted -- sign and payload preserved, quiet bit forced;
    sNaN signals invalid. Infinity and zero: returned unchanged (zero keeps
    its sign). Finite values round to an integral value per attribute rm; a
    fractional value that rounds to zero takes the sign of x. Inexact is NOT
    signaled (only roundToIntegralExact does). For the degenerate emax < p-1
    corner the rounded integer can exceed the largest finite, handled per 7.4
    (mirrors round_to_format).
    """
    a_cls, a_s, a_v, a_pay = decode(a_bits, fmt)
    if a_cls in (QNAN, SNAN):
        flags = (1 << FLAG_INVALID) if a_cls == SNAN else 0
        if fmt.W_MANT == 0:
            # Dead for E8M0 (no NaN encodings); keep encode_nan's +inf default.
            return encode_inf(0, fmt), flags
        payload = a_pay | (1 << (fmt.W_MANT - 1))
        bits = ((a_s << (fmt.W_EXP + fmt.W_MANT))
                | ((1 << fmt.W_EXP) - 1) << fmt.W_MANT | payload)
        return bits, flags
    if a_cls == INF or a_cls == ZERO:
        return a_bits, 0

    sign = a_s
    v = -a_v if a_s else a_v
    if v.denominator == 1:
        # Already integral: returned unchanged.
        return a_bits, 0
    n = v.numerator // v.denominator  # floor(|x|)
    r = v - n  # fractional part in (0,1)
    up = _round_up(rm, sign, r, n)
    y = n + (1 if up else 0)
    if y == 0:
        return encode_zero(sign, fmt), 0

    # Representability: for conforming formats (emax >= p-1) the rounded
    # integer always fits; the overflow corner is handled per 7.4.
    if y > fmt.max_finite:
        s = sign
        if rm in (MODE_RNE, MODE_RNA):
            bits = encode_inf(s, fmt)
        elif rm == MODE_RZ:
            bits = max_finite_bits(s, fmt)
        elif rm == MODE_RP:
            bits = encode_inf(0, fmt) if s == 0 else max_finite_bits(1, fmt)
        else:  # MODE_RM
            bits = encode_inf(1, fmt) if s == 1 else max_finite_bits(0, fmt)
        return bits, (1 << FLAG_OVERFLOW) | (1 << FLAG_INEXACT)

    ey = y.bit_length() - 1
    if ey >= fmt.emin:
        mant = ((y - (1 << ey)) << fmt.W_MANT) >> ey
        return encode_finite(sign, ey + fmt.bias, mant, fmt), 0
    # Subnormal (non-conforming corner only): y * 2^(W_MANT-emin).
    mant = y << (fmt.W_MANT - fmt.emin)
    return encode_finite(sign, 0, mant, fmt), 0


def _flip_sign(bits: int, fmt: BinFormat) -> int:
    return bits ^ (1 << (fmt.width - 1))
