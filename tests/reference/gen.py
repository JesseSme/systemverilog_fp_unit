"""Random floating-point operand generators for cocotb tests.

Distributions are chosen to stress the interesting corners of the format:
boundary exponents (emax/emin +/- a few), subnormals, NaNs, infinities,
zeros, and significand extremes. All generators are seeded via the rng
argument for reproducibility.
"""

from __future__ import annotations

import random

from .formats import BinFormat, encode_inf, encode_nan, encode_zero


def uniform(rng: random.Random, fmt: BinFormat) -> int:
    """Uniform random bit pattern (covers every class)."""
    return rng.getrandbits(fmt.width)


def special(rng: random.Random, fmt: BinFormat) -> int:
    """One of +-0, +-inf, qNaN, sNaN (NaNs only when the format has a
    mantissa field; E8M0 with W_MANT = 0 has no NaN encodings)."""
    n = 6 if fmt.W_MANT > 0 else 4
    pick = rng.randrange(n)
    if pick == 0:
        return encode_zero(0, fmt)
    if pick == 1:
        return encode_zero(1, fmt)
    if pick == 2:
        return encode_inf(0, fmt)
    if pick == 3:
        return encode_inf(1, fmt)
    if pick == 4:
        return encode_nan(rng.getrandbits(fmt.W_MANT), fmt)
    return (encode_nan(rng.getrandbits(fmt.W_MANT), fmt) & ~(1 << (fmt.W_MANT - 1))) | (
        1 << (fmt.W_EXP + fmt.W_MANT)
    )


def _exp_field(rng: random.Random, fmt: BinFormat) -> int:
    """Exponent field from a boundary-biased distribution."""
    exp_all = (1 << fmt.W_EXP) - 1
    interesting = [
        0, 0, 1, 2, 3, 4,
        fmt.bias - 2, fmt.bias - 1, fmt.bias, fmt.bias + 1,
        exp_all - 3, exp_all - 2,
    ]
    if rng.randrange(3) == 0:
        return rng.choice(interesting)
    return rng.randrange(1, exp_all - 1)


def _mantissa(rng: random.Random, fmt: BinFormat, extreme: bool) -> int:
    if fmt.W_MANT == 0:
        return 0
    if extreme:
        return rng.choice([0, 1, 2, (1 << fmt.W_MANT) - 1, (1 << fmt.W_MANT) - 2,
                           (1 << fmt.W_MANT) - 3, 1 << (fmt.W_MANT - 1)])
    return rng.getrandbits(fmt.W_MANT)


def finite(rng: random.Random, fmt: BinFormat, subnormal_bias: int = 10) -> int:
    """A finite number, biased toward boundaries and subnormals.
    (Subnormals do not exist for W_MANT = 0.)"""
    exp_all = (1 << fmt.W_EXP) - 1
    sign = rng.getrandbits(1)
    kind = rng.randrange(100)
    if fmt.W_MANT > 0 and kind < subnormal_bias:
        e, m = 0, rng.getrandbits(fmt.W_MANT)
        while m == 0:
            m = rng.getrandbits(fmt.W_MANT)
        return (sign << (fmt.W_EXP + fmt.W_MANT)) | m
    if kind < subnormal_bias + 20:
        e = _exp_field(rng, fmt)
        m = _mantissa(rng, fmt, extreme=True)
    else:
        e = rng.randrange(1, exp_all - 1)
        m = rng.getrandbits(fmt.W_MANT)
    return (sign << (fmt.W_EXP + fmt.W_MANT)) | (e << fmt.W_MANT) | m


def operand(rng: random.Random, fmt: BinFormat) -> int:
    """Weighted mix used as the default per-operand distribution."""
    kind = rng.randrange(100)
    if kind < 6:
        return special(rng, fmt)
    if kind < 16:
        return uniform(rng, fmt)
    return finite(rng, fmt)


def sqrt_operand(rng: random.Random, fmt: BinFormat) -> int:
    """Positive finite value (sqrt domain), biased toward boundaries."""
    return finite(rng, fmt, subnormal_bias=30) & ~(1 << (fmt.width - 1))


def pair(rng: random.Random, fmt: BinFormat, style: str) -> tuple[int, int]:
    """Operand pairs targeting specific add/sub and mul datapath behaviors."""
    if style == "independent":
        return operand(rng, fmt), operand(rng, fmt)
    if style == "same":
        a = operand(rng, fmt)
        return a, a
    if style == "opposite":
        a = operand(rng, fmt)
        return a, a ^ (1 << (fmt.width - 1))
    if style == "near":
        a = finite(rng, fmt)
        b = a + rng.choice([-1, 1])
        if not (0 <= b < (1 << fmt.width)) or b == 0:
            b = a
        return a, b
    if style == "same_exp":
        e = rng.randrange(0, (1 << fmt.W_EXP) - 1)
        m_a, m_b = rng.getrandbits(fmt.W_MANT), rng.getrandbits(fmt.W_MANT)
        a = (rng.getrandbits(1) << (fmt.W_EXP + fmt.W_MANT)) | (e << fmt.W_MANT) | m_a
        b = (rng.getrandbits(1) << (fmt.W_EXP + fmt.W_MANT)) | (e << fmt.W_MANT) | m_b
        return a, b
    if style == "boundary":
        a = finite(rng, fmt, subnormal_bias=30)
        b = finite(rng, fmt, subnormal_bias=30)
        return a, b
    if style == "mul_large":
        # Both operands near the largest finite: products overflow (7.4).
        e = rng.randrange(max(1, (1 << fmt.W_EXP) - 4), (1 << fmt.W_EXP) - 1)
        enc = lambda: ((rng.getrandbits(1) << (fmt.W_EXP + fmt.W_MANT))
                       | (e << fmt.W_MANT) | _mantissa(rng, fmt, extreme=True))
        return enc(), enc()
    if style == "mul_tiny":
        # Small magnitudes: subnormal / underflow-prone products (7.5).
        if fmt.W_MANT > 0 and rng.randrange(3) < 2:
            return finite(rng, fmt, subnormal_bias=60), finite(rng, fmt, subnormal_bias=60)
        e = rng.randrange(0, fmt.bias + 1)  # small exponent field
        enc = lambda: ((rng.getrandbits(1) << (fmt.W_EXP + fmt.W_MANT))
                       | (e << fmt.W_MANT) | _mantissa(rng, fmt, extreme=True))
        return enc(), enc()
    if style == "mul_pow2":
        # Exact powers of two (mantissa 0): products are exact or overflow/tiny.
        enc = lambda: ((rng.getrandbits(1) << (fmt.W_EXP + fmt.W_MANT))
                       | (rng.randrange(0, (1 << fmt.W_EXP) - 1) << fmt.W_MANT))
        return enc(), enc()
    if style == "div_close":
        # Quotients near 1.0 (and their neighbours): exercises the leading-bit
        # tie between e_a-e_b and e_a-e_b-1 and the near-1 rounding cases.
        a = finite(rng, fmt)
        if fmt.W_MANT > 0:
            b = a + rng.choice([-1, 1, 2, -2, 1 << (fmt.W_MANT - 1)])
        else:
            b = a + rng.choice([-1, 1, 2, -2])
        if not (0 <= b < (1 << fmt.width)) or b == 0:
            b = a
        return a, b
    if style == "div_extreme":
        # One huge and one tiny operand: overflow/underflow-prone quotients.
        if fmt.W_MANT > 0 and rng.randrange(3) == 0:
            return finite(rng, fmt, subnormal_bias=60), finite(rng, fmt)
        e_hi = rng.randrange(max(1, (1 << fmt.W_EXP) - 4), (1 << fmt.W_EXP) - 1)
        e_lo = rng.randrange(0, fmt.bias + 1)
        hi = ((rng.getrandbits(1) << (fmt.W_EXP + fmt.W_MANT))
              | (e_hi << fmt.W_MANT) | _mantissa(rng, fmt, True))
        lo = ((rng.getrandbits(1) << (fmt.W_EXP + fmt.W_MANT))
              | (e_lo << fmt.W_MANT) | _mantissa(rng, fmt, False))
        return (hi, lo) if rng.randrange(2) else (lo, hi)
    if style == "sqrt":
        # Positive finite (b is ignored by sqrt): boundary-biased radicands.
        a = sqrt_operand(rng, fmt)
        return a, a
    raise ValueError(f"unknown pair style {style!r}")


def pair_stream(rng: random.Random, fmt: BinFormat, n: int) -> list[tuple[int, int]]:
    """Mixed stream: mostly independent, plus targeted pairs."""
    styles = (["independent"] * 5 + ["same", "opposite", "near", "same_exp", "boundary",
              "mul_large", "mul_tiny", "mul_pow2", "div_close", "div_extreme", "sqrt"])
    out = []
    for _ in range(n):
        out.append(pair(rng, fmt, rng.choice(styles)))
    return out
