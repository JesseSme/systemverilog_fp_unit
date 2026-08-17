"""IEEE 754-2019 binary format model (clauses 3.2-3.7).

This is the bit-exact oracle for the SystemVerilog DUT. Every value is kept
as an exact rational (Fraction) so that rounding to an arbitrary
(W_EXP, W_MANT) format never loses information, per clause 4.3:
"every operation shall be performed as if it first produced an intermediate
result correct to infinite precision and with unbounded range, and then
rounded that result according to one of the attributes".
"""

from __future__ import annotations

from dataclasses import dataclass
from fractions import Fraction

# Value classes (mirror rtl/fp_pkg.sv).
ZERO = 0
SUBNORMAL = 1
NORMAL = 2
INF = 3
QNAN = 4
SNAN = 5

# Exception flag bit positions (clause 7, mirror rtl/fp_pkg.sv).
FLAG_INVALID = 4
FLAG_DIV0 = 3
FLAG_OVERFLOW = 2
FLAG_UNDERFLOW = 1
FLAG_INEXACT = 0

# Rounding-direction attributes (clause 4.3).
MODE_RNE = 0  # roundTiesToEven (4.3.1)
MODE_RNA = 1  # roundTiesToAway (4.3.1)
MODE_RZ = 2   # roundTowardZero (4.3.2)
MODE_RP = 3   # roundTowardPositive (4.3.2)
MODE_RM = 4   # roundTowardNegative (4.3.2)
MODE_NAMES = ("RNE", "RNA", "RZ", "RP", "RM")

# Comparison condition codes (5.11), encoding of the DUT's 2-bit cmp output
# (mirror rtl/fp_pkg.sv). OP_TOTALORDER uses cmp[0] only.
CMP_LT = 0  # a < b
CMP_EQ = 1  # a == b
CMP_GT = 2  # a > b
CMP_UN = 3  # unordered (a NaN operand)


@dataclass(frozen=True)
class BinFormat:
    """Binary interchange/extendable format (3.3, 3.6, 3.7).

    W_EXP:  width of the exponent field in bits
    W_MANT: width of the fraction field in bits
    """

    W_EXP: int
    W_MANT: int

    @property
    def width(self) -> int:
        return 1 + self.W_EXP + self.W_MANT

    @property
    def p(self) -> int:
        """Precision: number of significand bits including the implicit bit (3.3)."""
        return self.W_MANT + 1

    @property
    def emax(self) -> int:
        """Largest exponent (3.3): emax = 2^(W_EXP-1) - 1."""
        return (1 << (self.W_EXP - 1)) - 1

    @property
    def bias(self) -> int:
        return self.emax

    @property
    def emin(self) -> int:
        """Smallest normal exponent: emin = 1 - emax."""
        return 1 - self.emax

    @property
    def max_finite(self) -> Fraction:
        """Largest finite number: b^emax x (b - b^(1-p))."""
        return Fraction((1 << self.p) - 1) * (Fraction(2) ** (self.emax + 1 - self.p))

    @property
    def min_normal(self) -> Fraction:
        return Fraction(2) ** self.emin

    @property
    def min_subnormal(self) -> Fraction:
        return Fraction(2) ** (self.emin - self.W_MANT)


def split(bits: int, fmt: BinFormat) -> tuple[int, int, int]:
    """Split an encoding into (sign, exponent field, fraction field)."""
    s = (bits >> (fmt.W_EXP + fmt.W_MANT)) & 1
    e = (bits >> fmt.W_MANT) & ((1 << fmt.W_EXP) - 1)
    m = bits & ((1 << fmt.W_MANT) - 1)
    return s, e, m


def decode(bits: int, fmt: BinFormat) -> tuple[int, int, Fraction | None, int]:
    """Decode an encoding.

    Returns (cls, sign, value, payload) where
      cls     is one of ZERO/SUBNORMAL/NORMAL/INF/QNAN/SNAN,
      sign    is the sign bit,
      value   is the exact rational value for finite numbers, else None,
      payload is the fraction field for NaNs, else 0.
    """
    s, e, m = split(bits, fmt)
    if e == (1 << fmt.W_EXP) - 1:
        if m == 0:
            return INF, s, None, 0
        return (QNAN, s, None, m) if m >> (fmt.W_MANT - 1) else (SNAN, s, None, m)
    if e == 0:
        if m == 0:
            return ZERO, s, None, 0
        v = Fraction(m) * (Fraction(2) ** (1 - fmt.emax - fmt.W_MANT))
        return SUBNORMAL, s, -v if s else v, 0
    v = Fraction((1 << fmt.W_MANT) | m) * (Fraction(2) ** (e - fmt.emax - fmt.W_MANT))
    return NORMAL, s, -v if s else v, 0


def encode_finite(sign: int, exp_field: int, mant: int, fmt: BinFormat) -> int:
    """Encode a finite number from its stored (sign, exponent field, fraction)."""
    return (sign << (fmt.W_EXP + fmt.W_MANT)) | (exp_field << fmt.W_MANT) | mant


def encode_zero(sign: int, fmt: BinFormat) -> int:
    return sign << (fmt.W_EXP + fmt.W_MANT)


def encode_inf(sign: int, fmt: BinFormat) -> int:
    return (sign << (fmt.W_EXP + fmt.W_MANT)) | ((1 << fmt.W_EXP) - 1) << fmt.W_MANT


def encode_nan(payload: int, fmt: BinFormat) -> int:
    """Quiet NaN with sign 0 and the given payload (6.2.3 quiet bit forced).

    E8M0 (W_MANT = 0) has no NaN encodings; encode +infinity instead (the
    documented default result for invalid operations in that format).
    """
    if fmt.W_MANT == 0:
        return encode_inf(0, fmt)
    return ((1 << fmt.W_EXP) - 1) << fmt.W_MANT | (1 << (fmt.W_MANT - 1)) | payload


def max_finite_bits(sign: int, fmt: BinFormat) -> int:
    return encode_finite(sign, (1 << fmt.W_EXP) - 2, (1 << fmt.W_MANT) - 1, fmt)
