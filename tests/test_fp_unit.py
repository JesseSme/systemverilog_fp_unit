"""Cocotb tests for the IEEE 754-2019 FPU (add/sub milestone).

Run via tests/run_regression.py, which instantiates the DUT at several
(W_EXP, W_MANT) widths and sets FP_W_EXP/FP_W_MANT/FP_ITERS/FP_SEED.

The expected (result, flags) pairs come from the bit-exact Python oracle in
tests/reference (exact rational arithmetic rounded per clause 4.3), plus a
table of hand-verified directed vectors for binary32.
"""

import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cocotb
from cocotb.triggers import Timer

from reference import formats, gen, ops
from reference.formats import (
    CMP_EQ,
    CMP_GT,
    CMP_LT,
    CMP_UN,
    MODE_NAMES,
    MODE_RNA,
    MODE_RNE,
    MODE_RM,
    MODE_RP,
    MODE_RZ,
    BinFormat,
    encode_finite,
    encode_inf,
    encode_nan,
    encode_zero,
    max_finite_bits,
)

OP_ADD = 0
OP_SUB = 1
OP_MUL = 2
OP_DIV = 3
OP_SQRT = 4
OP_FMA = 5
OP_MIN = 6
OP_MAX = 7
OP_CMP = 8
OP_RNDINT = 9
OP_TOTALORDER = 10

W_EXP = int(os.environ.get("FP_W_EXP", "8"))
W_MANT = int(os.environ.get("FP_W_MANT", "23"))
FMT = BinFormat(W_EXP, W_MANT)
ITERS = int(os.environ.get("FP_ITERS", "100"))
SEED = int(os.environ.get("FP_SEED", "0x5eed"), 0)


def _flag_names(f):
    names = []
    for bit, name in ((formats.FLAG_INVALID, "invalid"), (formats.FLAG_DIV0, "div0"),
                      (formats.FLAG_OVERFLOW, "overflow"), (formats.FLAG_UNDERFLOW, "underflow"),
                      (formats.FLAG_INEXACT, "inexact")):
        if f & (1 << bit):
            names.append(name)
    return ",".join(names) or "-"


async def check(dut, mode, rm, a, b, exp_y, exp_f, what, c=0, exp_cmp=0):
    dut.rst_n.value = 1
    dut.mode.value = mode
    dut.rm.value = rm
    dut.a.value = a
    dut.b.value = b
    dut.c.value = c
    dut.clk.value = 0
    await Timer(1, units="ns")
    dut.clk.value = 1   # posedge captures the combinational result into the registers
    await Timer(1, units="ns")
    y = int(dut.y.value)
    f = int(dut.flags.value)
    cc = int(dut.cmp.value)
    if y != exp_y or f != exp_f or cc != exp_cmp:
        w = (W_EXP + W_MANT + 1) // 4 + 1
        opname = {OP_ADD: "add", OP_SUB: "sub", OP_MUL: "mul", OP_DIV: "div",
                  OP_SQRT: "sqrt", OP_FMA: "fma", OP_MIN: "min", OP_MAX: "max",
                  OP_CMP: "cmp", OP_RNDINT: "rndint", OP_TOTALORDER: "totalorder"}[mode]
        dut._log.error(
            "%s: mode=%s rm=%s a=%0*x b=%0*x: got y=%0*x flags=%s cmp=%d, "
            "want y=%0*x flags=%s cmp=%d",
            what,
            opname,
            MODE_NAMES[rm],
            w, a, w, b,
            w, y,
            _flag_names(f),
            cc,
            w, exp_y,
            _flag_names(exp_f),
            exp_cmp,
        )
        raise AssertionError(f"{what} mismatch (rm={MODE_NAMES[rm]})")


def _directed_vectors(fmt):
    """Hand-verified directed vectors (generic where possible, binary32
    specific vectors for exact tie/overflow arithmetic).

    Note: for addition/subtraction the exact result is always an integer
    multiple of the minimum subnormal, so subnormal results are always exact
    and the underflow flag is never signaled (7.5 requires inexact as well).
    """
    w = fmt.width
    neg = lambda x: x ^ (1 << (w - 1))
    m0 = fmt.W_MANT
    m1 = _norm1(fmt)
    m1s = neg(m1)
    maxf = max_finite_bits(0, fmt)
    maxs = neg(maxf)
    maxm = (1 << m0) - 1
    z = encode_zero(0, fmt)
    zs = encode_zero(1, fmt)
    inf = encode_inf(0, fmt)
    infs = encode_inf(1, fmt)
    # E8M0 (W_MANT = 0) has no NaN encodings; encode_nan returns +inf there.
    qnan = encode_nan(0, fmt)
    minn = encode_finite(0, 1, 0, fmt)                    # min normal
    maxsn = encode_finite(0, 0, maxm, fmt)                # max subnormal
    minsn = encode_finite(0, 0, 1, fmt)                   # min subnormal
    v = []

    # --- zeros (6.3)
    v += [
        (OP_ADD, MODE_RNE, z, z, z, 0, "+0 + +0 = +0"),
        (OP_ADD, MODE_RNE, zs, zs, zs, 0, "-0 + -0 = -0 (like signs)"),
        (OP_ADD, MODE_RM, zs, zs, zs, 0, "-0 + -0 = -0 under RM"),
        (OP_ADD, MODE_RNE, zs, z, z, 0, "-0 + +0 = +0 (opposite signs)"),
        (OP_ADD, MODE_RM, zs, z, zs, 0, "-0 + +0 = -0 under RM"),
        (OP_SUB, MODE_RNE, z, z, z, 0, "+0 - +0 = +0"),
        (OP_SUB, MODE_RM, z, z, zs, 0, "+0 - +0 = -0 under RM"),
        (OP_SUB, MODE_RNE, z, zs, z, 0, "+0 - -0 = +0 (x - (-x))"),
        (OP_SUB, MODE_RM, z, zs, z, 0, "+0 - -0 = +0 even under RM"),
        (OP_SUB, MODE_RNE, zs, z, zs, 0, "-0 - +0 = -0 (x - (-x))"),
        (OP_SUB, MODE_RM, zs, z, zs, 0, "-0 - +0 = -0 even under RM"),
        (OP_SUB, MODE_RNE, zs, zs, z, 0, "-0 - -0 = +0"),
        (OP_SUB, MODE_RM, zs, zs, zs, 0, "-0 - -0 = -0 under RM"),
        # x +- 0
        (OP_ADD, MODE_RNE, m1, z, m1, 0, "1 + +0 = 1"),
        (OP_ADD, MODE_RNE, m1, zs, m1, 0, "1 + -0 = 1"),
        (OP_SUB, MODE_RNE, m1, z, m1, 0, "1 - +0 = 1"),
        (OP_SUB, MODE_RNE, m1, zs, m1, 0, "1 - -0 = 1"),
        (OP_ADD, MODE_RNE, z, m1, m1, 0, "+0 + 1 = 1"),
        (OP_SUB, MODE_RNE, z, m1, m1s, 0, "0 - 1 = -1"),
        (OP_SUB, MODE_RNE, z, m1s, m1, 0, "0 - -1 = 1"),
        # cancellation
        (OP_ADD, MODE_RNE, m1, m1s, z, 0, "1 + -1 = +0"),
        (OP_ADD, MODE_RM, m1, m1s, zs, 0, "1 + -1 = -0 under RM"),
        (OP_SUB, MODE_RNE, m1, m1, z, 0, "1 - 1 = +0"),
        (OP_SUB, MODE_RM, m1, m1, zs, 0, "1 - 1 = -0 under RM"),
        (OP_SUB, MODE_RNE, m1s, m1s, z, 0, "-1 - -1 = +0"),
    ]

    # --- infinities and NaNs (6.1, 6.2, 7.2)
    v += [
        (OP_ADD, MODE_RNE, inf, inf, inf, 0, "inf + inf = inf"),
        (OP_ADD, MODE_RNE, infs, infs, infs, 0, "-inf + -inf = -inf"),
        (OP_SUB, MODE_RNE, inf, infs, inf, 0, "inf - -inf = inf"),
        (OP_ADD, MODE_RNE, inf, infs, qnan, 1 << formats.FLAG_INVALID, "inf + -inf -> qNaN, invalid"),
        (OP_SUB, MODE_RNE, inf, inf, qnan, 1 << formats.FLAG_INVALID, "inf - inf -> qNaN, invalid"),
        (OP_ADD, MODE_RNE, inf, m1, inf, 0, "inf + 1 = inf"),
        (OP_ADD, MODE_RNE, m1, inf, inf, 0, "1 + inf = inf"),
        (OP_SUB, MODE_RNE, m1, inf, infs, 0, "1 - inf = -inf"),
        (OP_ADD, MODE_RNE, qnan, m1, qnan, 0, "qNaN + 1 -> qNaN"),
        (OP_ADD, MODE_RNE, m1, qnan, qnan, 0, "1 + qNaN -> qNaN"),
    ]
    if w == 32:
        v += [
            (OP_ADD, MODE_RNE, 0x7FC00001, m1, 0x7FC00001, 0, "qNaN payload passthrough"),
            (OP_ADD, MODE_RNE, 0x7F800001, m1, 0x7FC00001, 1 << formats.FLAG_INVALID,
             "sNaN -> qNaN, invalid"),
            (OP_ADD, MODE_RNE, m1, 0xFF80000F, 0x7FC0000F, 1 << formats.FLAG_INVALID,
             "sNaN payload kept, invalid"),
            (OP_ADD, MODE_RNE, 0x7FC00003, 0x7F800005, 0x7FC00003, 1 << formats.FLAG_INVALID,
             "a NaN wins payload, sNaN -> invalid"),
        ]

    # --- basic arithmetic (RNE)
    v += [
        (OP_ADD, MODE_RNE, m1, m1, encode_finite(0, fmt.bias + 1, 0, fmt), 0, "1 + 1 = 2"),
        (OP_SUB, MODE_RNE, m1, m1s, encode_finite(0, fmt.bias + 1, 0, fmt), 0, "1 - -1 = 2"),
    ]
    if fmt.W_MANT > 0:
        v += [
            (OP_ADD, MODE_RNE, m1, encode_finite(0, fmt.bias, 1 << (m0 - 1), fmt),
             encode_finite(0, fmt.bias + 1, 1 << (m0 - 2), fmt), 0, "1 + 1.5 = 2.5"),
        ]
    # --- subnormal boundary (generic; all exact, so no flags)
    # Subnormals do not exist for W_MANT = 0 (E8M0).
    if fmt.W_MANT > 0:
        v += [
            (OP_ADD, MODE_RNE, minn, maxsn, encode_finite(0, 1, maxm, fmt), 0,
             "min normal + max subnormal = 2^-125 - 2^-149 (exact)"),
            (OP_ADD, MODE_RNE, minn, minn, encode_finite(0, 2, 0, fmt), 0, "min normal + min normal"),
            (OP_ADD, MODE_RNE, minsn, minsn, encode_finite(0, 0, 2, fmt), 0,
             "min subnormal + min subnormal"),
            (OP_ADD, MODE_RNE, minsn, neg(minsn), z, 0, "subnormal cancellation"),
            (OP_SUB, MODE_RNE, encode_finite(0, 1, 1, fmt), minn, minsn, 0,
             "min normal + ulp - min normal = min subnormal (exact)"),
            (OP_ADD, MODE_RNE, minn, neg(maxsn), minsn, 0,
             "min normal - max subnormal = min subnormal (exact, no underflow)"),
        ]
    # --- overflow (7.4)
    v += [
        (OP_ADD, MODE_RNE, maxf, maxf, inf, 0x05, "max + max -> +inf (RNE)"),
        (OP_ADD, MODE_RZ, maxf, maxf, maxf, 0x05, "max + max -> max (RZ)"),
        (OP_ADD, MODE_RM, maxf, maxf, maxf, 0x05, "max + max -> max (RM, positive)"),
        (OP_ADD, MODE_RP, maxf, maxf, inf, 0x05, "max + max -> +inf (RP)"),
        (OP_ADD, MODE_RNE, maxs, maxs, infs, 0x05, "-max + -max -> -inf (RNE)"),
        (OP_ADD, MODE_RP, maxs, maxs, maxs, 0x05, "-max + -max -> -max (RP, negative)"),
        (OP_ADD, MODE_RM, maxs, maxs, infs, 0x05, "-max + -max -> -inf (RM)"),
        (OP_ADD, MODE_RNE, maxf, m1, maxf, 1 << formats.FLAG_INEXACT, "max + 1 -> max, inexact"),
        (OP_ADD, MODE_RP, maxf, m1, inf, 0x05, "max + 1 -> inf under RP, overflow"),
    ]
    if w == 32:
        # Tie at the overflow threshold: exact sum = 2^128 - 2^103 (0x73000000 = 2^103).
        # Per 7.4 the overflow flag tracks the rounded result with unbounded
        # exponent range: RNE/RNA round the tie to 2^128 (> max) -> overflow;
        # RZ/RM round down to max finite exactly -> inexact only.
        v += [
            (OP_ADD, MODE_RNE, maxf, 0x73000000, inf, 0x05, "overflow tie -> inf (RNE even)"),
            (OP_ADD, MODE_RNA, maxf, 0x73000000, inf, 0x05, "overflow tie -> inf (RNA)"),
            (OP_ADD, MODE_RZ, maxf, 0x73000000, maxf, 1 << formats.FLAG_INEXACT,
             "overflow tie -> max (RZ), inexact only"),
            (OP_ADD, MODE_RM, maxf, 0x73000000, maxf, 1 << formats.FLAG_INEXACT,
             "overflow tie -> max (RM), inexact only"),
        ]
    # --- E8M0 (W_MANT = 0) ties and exact powers (4.3.1: p = 1 ties -> larger).
    if fmt.W_MANT == 0:
        pe  = maxf                                            # 2^EMAX
        pem = encode_finite(0, fmt.emax - 1 + fmt.bias, 0, fmt)   # 2^(EMAX-1)
        pe2 = encode_finite(0, fmt.emax - 2 + fmt.bias, 0, fmt)   # 2^(EMAX-2)
        pe3 = encode_finite(0, fmt.emax - 3 + fmt.bias, 0, fmt)   # 2^(EMAX-3)
        v += [
            # 2^EMAX + 2^EMAX = 2^(EMAX+1): overflow (rounded-unbounded > max)
            (OP_ADD, MODE_RNE, pe, pe, inf, 0x05, "e8m0: 2^EMAX + 2^EMAX -> inf (RNE, OF)"),
            (OP_ADD, MODE_RZ,  pe, pe, maxf, 0x05, "e8m0: max + max -> max (RZ, OF+INE)"),
            (OP_ADD, MODE_RP,  pe, pe, inf, 0x05, "e8m0: max + max -> inf (RP, OF)"),
            (OP_ADD, MODE_RM,  pe, pe, maxf, 0x05, "e8m0: max + max (pos) -> max (RM, OF+INE)"),
            # Tie: 2^EMAX + 2^(EMAX-1) = 1.5*2^EMAX -> RNE/RNA/RP larger (inf),
            # RZ/RM smaller (max finite, inexact only: rounded-unbounded = max).
            (OP_ADD, MODE_RNE, pe, pem, inf, 0x05, "e8m0: tie -> +inf (RNE, OF)"),
            (OP_ADD, MODE_RZ,  pe, pem, maxf, 1 << formats.FLAG_INEXACT, "e8m0: tie -> max (RZ, no OF)"),
            (OP_ADD, MODE_RP,  pe, pem, inf, 0x05, "e8m0: tie -> +inf (RP, OF)"),
            (OP_ADD, MODE_RM,  pe, pem, maxf, 1 << formats.FLAG_INEXACT, "e8m0: tie (pos) -> max (RM, no OF)"),
            # Non-overflow tie: 2^(EMAX-1) + 2^(EMAX-2) -> larger = 2^EMAX (RNE/RP)
            (OP_ADD, MODE_RNE, pem, pe2, pe, 1 << formats.FLAG_INEXACT,
             "e8m0: tie -> larger 2^EMAX (RNE, no OF)"),
            (OP_ADD, MODE_RZ,  pem, pe2, pem, 1 << formats.FLAG_INEXACT, "e8m0: tie -> smaller (RZ)"),
            (OP_ADD, MODE_RP,  pem, pe2, pe, 1 << formats.FLAG_INEXACT, "e8m0: tie -> larger (RP)"),
            # Cancellation
            (OP_ADD, MODE_RNE, pe, neg(pe), z, 0, "e8m0: 2^EMAX + -2^EMAX = +0"),
            (OP_ADD, MODE_RM,  pe, neg(pe), zs, 0, "e8m0: cancellation -> -0 (RM)"),
            (OP_SUB, MODE_RNE, pe, neg(pe), inf, 0x05, "e8m0: 2^EMAX - -2^EMAX = inf (OF)"),
            # Opposite-sign d=1: exact 2^EMAX - 2^(EMAX-1) = 2^(EMAX-1)
            (OP_ADD, MODE_RNE, pe, neg(pem), pem, 0, "e8m0: d=1 opposite -> exact 2^(EMAX-1)"),
            # Opposite-sign d=2: tie between 2^(EMAX-1) and 2^EMAX -> larger (RNE/RP)
            (OP_ADD, MODE_RNE, pe, neg(pe2), pe, 1 << formats.FLAG_INEXACT,
             "e8m0: d=2 tie -> larger 2^EMAX (RNE)"),
            (OP_ADD, MODE_RZ,  pe, neg(pe2), pem, 1 << formats.FLAG_INEXACT, "e8m0: d=2 tie -> smaller (RZ)"),
            (OP_ADD, MODE_RP,  pe, neg(pe2), pe, 1 << formats.FLAG_INEXACT, "e8m0: d=2 tie -> larger (RP)"),
            (OP_ADD, MODE_RM,  pe, neg(pe2), pem, 1 << formats.FLAG_INEXACT, "e8m0: d=2 tie -> smaller (RM)"),
            # Opposite-sign d=3: nearest to 2^EMAX (above midpoint)
            (OP_ADD, MODE_RNE, pe, neg(pe3), pe, 1 << formats.FLAG_INEXACT,
             "e8m0: d=3 -> nearest 2^EMAX (RNE, inexact)"),
        ]
    # --- half-way ties (RNE/RNA), binary32 only
    if w == 32:
        p24 = 0x33800000   # 2^-24
        p23 = 0x34000000   # 2^-23
        v += [
            (OP_ADD, MODE_RNE, m1, p23, 0x3F800001, 0, "1 + 2^-23 exact"),
            (OP_ADD, MODE_RNE, m1, p24, 0x3F800000, 1 << formats.FLAG_INEXACT, "tie -> even (down)"),
            (OP_ADD, MODE_RNA, m1, p24, 0x3F800001, 1 << formats.FLAG_INEXACT, "tie -> away"),
            (OP_ADD, MODE_RZ, m1, p24, 0x3F800000, 1 << formats.FLAG_INEXACT, "tie -> toward zero"),
            (OP_ADD, MODE_RP, m1, p24, 0x3F800001, 1 << formats.FLAG_INEXACT, "tie -> +inf dir"),
            (OP_ADD, MODE_RM, m1, p24, 0x3F800000, 1 << formats.FLAG_INEXACT, "tie -> -inf dir"),
            # 1 + 3*2^-24: tie between odd (1+2^-23) and even (1+2^-22) -> even up
            (OP_ADD, MODE_RNE, m1, 0x34400000, 0x3F800002, 1 << formats.FLAG_INEXACT, "tie -> even (up)"),
            (OP_ADD, MODE_RNA, m1, 0x34400000, 0x3F800002, 1 << formats.FLAG_INEXACT, "tie -> away"),
            (OP_ADD, MODE_RZ, m1, 0x34400000, 0x3F800001, 1 << formats.FLAG_INEXACT, "3/2 ulp -> toward zero"),
            (OP_ADD, MODE_RM, m1, 0x34400000, 0x3F800001, 1 << formats.FLAG_INEXACT, "3/2 ulp -> down"),
            # sticky rounding: 1 + 2^-126 + 2^-149 (0x33000001)
            (OP_ADD, MODE_RNE, m1, 0x33000001, 0x3F800000, 1 << formats.FLAG_INEXACT,
             "sticky forces inexact"),
            (OP_ADD, MODE_RP, m1, 0x33000001, 0x3F800001, 1 << formats.FLAG_INEXACT,
             "sticky rounds up (RP)"),
            # max finite + 2^-24: sticky below max, rounds up over the edge under RP
            (OP_ADD, MODE_RNE, maxf, p24, maxf, 1 << formats.FLAG_INEXACT, "max + tiny -> max"),
            (OP_ADD, MODE_RP, maxf, p24, inf, 0x05, "max + tiny -> inf under RP"),
        ]
    return v


def _directed_mul_vectors(fmt):
    """Hand-verified directed vectors for multiplication (5.4.1)."""
    w = fmt.width
    neg = lambda x: x ^ (1 << (w - 1))
    m0 = fmt.W_MANT
    m1 = _norm1(fmt)          # 1.0
    m1s = neg(m1)
    m2 = encode_finite(0, fmt.bias + 1, 0, fmt)         # 2.0
    m4 = encode_finite(0, fmt.bias + 2, 0, fmt)         # 4.0
    m05 = encode_finite(0, fmt.bias - 1, 0, fmt)        # 0.5
    m025 = encode_finite(0, fmt.bias - 2, 0, fmt)       # 0.25
    maxf = max_finite_bits(0, fmt)
    maxs = neg(maxf)
    maxm = (1 << m0) - 1
    z = encode_zero(0, fmt)
    zs = encode_zero(1, fmt)
    inf = encode_inf(0, fmt)
    infs = encode_inf(1, fmt)
    qnan = encode_nan(0, fmt)
    minn = encode_finite(0, 1, 0, fmt)                  # min normal
    maxsn = encode_finite(0, 0, maxm, fmt)              # max subnormal
    v = []

    # --- zero products: sign is the XOR of the operand signs (6.3), and the
    # roundTowardNegative zero-sign quirk of addition does not apply.
    v += [
        (OP_MUL, MODE_RNE, z, z, z, 0, "0 x 0 = +0"),
        (OP_MUL, MODE_RNE, zs, zs, z, 0, "-0 x -0 = +0"),
        (OP_MUL, MODE_RNE, zs, z, zs, 0, "-0 x +0 = -0"),
        (OP_MUL, MODE_RNE, z, zs, zs, 0, "+0 x -0 = -0"),
        (OP_MUL, MODE_RM, z, zs, zs, 0, "0 x -0 = -0 even under RM (sign XOR)"),
        (OP_MUL, MODE_RNE, z, m1, z, 0, "0 x 1 = +0"),
        (OP_MUL, MODE_RNE, zs, m1, zs, 0, "-0 x 1 = -0"),
        (OP_MUL, MODE_RNE, m2, z, z, 0, "2 x 0 = +0"),
        (OP_MUL, MODE_RNE, m2, zs, zs, 0, "2 x -0 = -0"),
    ]

    # --- infinities (6.3, 7.2e)
    v += [
        (OP_MUL, MODE_RNE, inf, inf, inf, 0, "inf x inf = +inf"),
        (OP_MUL, MODE_RNE, infs, infs, inf, 0, "-inf x -inf = +inf"),
        (OP_MUL, MODE_RNE, inf, infs, infs, 0, "inf x -inf = -inf"),
        (OP_MUL, MODE_RNE, inf, m2, inf, 0, "inf x 2 = +inf"),
        (OP_MUL, MODE_RNE, m2, infs, infs, 0, "2 x -inf = -inf"),
        (OP_MUL, MODE_RNE, infs, m05, infs, 0, "-inf x 0.5 = -inf"),
        (OP_MUL, MODE_RNE, inf, z, qnan, 1 << formats.FLAG_INVALID, "inf x 0 -> qNaN, invalid (7.2e)"),
        (OP_MUL, MODE_RNE, z, infs, qnan, 1 << formats.FLAG_INVALID, "0 x -inf -> qNaN, invalid (7.2e)"),
    ]

    # --- NaNs (6.2.3, 7.2a)
    v += [
        (OP_MUL, MODE_RNE, qnan, m1, qnan, 0, "qNaN x 1 -> qNaN"),
        (OP_MUL, MODE_RNE, m1, qnan, qnan, 0, "1 x qNaN -> qNaN"),
        (OP_MUL, MODE_RNE, inf, qnan, qnan, 0, "inf x qNaN -> qNaN"),
    ]
    if w == 32:
        v += [
            (OP_MUL, MODE_RNE, 0x7FC00001, m2, 0x7FC00001, 0, "qNaN payload passthrough"),
            (OP_MUL, MODE_RNE, 0x7F800001, m2, 0x7FC00001, 1 << formats.FLAG_INVALID,
             "sNaN -> qNaN, invalid"),
            (OP_MUL, MODE_RNE, m2, 0xFF80000F, 0x7FC0000F, 1 << formats.FLAG_INVALID,
             "sNaN payload kept, invalid"),
        ]

    # --- exact products (RNE)
    v += [
        (OP_MUL, MODE_RNE, m1, m1, m1, 0, "1 x 1 = 1"),
        (OP_MUL, MODE_RNE, m1, m2, m2, 0, "1 x 2 = 2"),
        (OP_MUL, MODE_RNE, m2, m2, m4, 0, "2 x 2 = 4"),
        (OP_MUL, MODE_RNE, m05, m05, m025, 0, "0.5 x 0.5 = 0.25"),
        (OP_MUL, MODE_RNE, m2, m05, m1, 0, "2 x 0.5 = 1"),
        (OP_MUL, MODE_RNE, m1s, m1s, m1, 0, "-1 x -1 = 1"),
        (OP_MUL, MODE_RNE, m1s, m1, m1s, 0, "-1 x 1 = -1"),
        (OP_MUL, MODE_RNE, m1, m1s, m1s, 0, "1 x -1 = -1"),
    ]
    if fmt.W_MANT > 0:
        # max sub x 2 = 2^emin - 2^(emin-W_MANT+1): an exact normal number
        # (significand 1.11..10 = 2 - 2^(1-W_MANT)).
        v += [
            (OP_MUL, MODE_RNE, maxsn, m2, encode_finite(0, 1, maxm - 1, fmt), 0,
             "max sub x 2 exact"),
        ]
    if fmt.W_MANT >= 3:
        m15 = encode_finite(0, fmt.bias, 1 << (m0 - 1), fmt)      # 1.5
        m3  = encode_finite(0, fmt.bias + 1, 1 << (m0 - 1), fmt)  # 3.0
        m225 = encode_finite(0, fmt.bias + 1, 1 << (m0 - 3), fmt) # 2.25
        u   = encode_finite(0, fmt.bias, 1, fmt)                  # 1 + 2^-W_MANT
        u2  = encode_finite(0, fmt.bias, 2, fmt)                  # 1 + 2^-(W_MANT-1)
        v += [
            (OP_MUL, MODE_RNE, m15, m2, m3, 0, "1.5 x 2 = 3"),
            (OP_MUL, MODE_RNE, m15, m15, m225, 0, "1.5 x 1.5 = 2.25"),
            (OP_MUL, MODE_RNE, m15, m1s, neg(m15), 0, "1.5 x -1 = -1.5"),
            # (1+2^-m)^2 = 1 + 2^-(m-1) + 2^-2m: the 2^-2m tail is sticky only.
            (OP_MUL, MODE_RNE, u, u, u2, 1 << formats.FLAG_INEXACT,
             "(1+2^-m)^2 -> 1+2^-(m-1), inexact"),
            (OP_MUL, MODE_RZ, u, u, u2, 1 << formats.FLAG_INEXACT,
             "(1+2^-m)^2 (RZ) -> 1+2^-(m-1)"),
            (OP_MUL, MODE_RM, u, u, u2, 1 << formats.FLAG_INEXACT,
             "(1+2^-m)^2 (RM, positive) -> 1+2^-(m-1)"),
            (OP_MUL, MODE_RP, u, u, encode_finite(0, fmt.bias, 3, fmt), 1 << formats.FLAG_INEXACT,
             "(1+2^-m)^2 (RP, positive) -> 1+2^-(m-2), inexact"),
        ]

    # --- half-way product tie: (1 + 2^-(m-1)) x (1 + 2^-2) leaves exactly
    # half an ulp. The even-mantissa candidate (RNE/RZ/RM for a positive
    # result) is 2^(m-2) + 2, the odd one (RNA/RP) is 2^(m-2) + 3.
    if fmt.W_MANT >= 3:
        t_a = encode_finite(0, fmt.bias, 2, fmt)                 # 1 + 2^-(m-1)
        t_b = encode_finite(0, fmt.bias, 1 << (m0 - 2), fmt)     # 1 + 2^-2
        t_even = encode_finite(0, fmt.bias, (1 << (m0 - 2)) + 2, fmt)
        t_odd = encode_finite(0, fmt.bias, (1 << (m0 - 2)) + 3, fmt)
        v += [
            (OP_MUL, MODE_RNE, t_a, t_b, t_even, 1 << formats.FLAG_INEXACT, "tie -> even (down)"),
            (OP_MUL, MODE_RNA, t_a, t_b, t_odd, 1 << formats.FLAG_INEXACT, "tie -> away (up)"),
            (OP_MUL, MODE_RZ, t_a, t_b, t_even, 1 << formats.FLAG_INEXACT, "tie -> toward zero"),
            (OP_MUL, MODE_RP, t_a, t_b, t_odd, 1 << formats.FLAG_INEXACT, "tie -> +inf direction"),
            (OP_MUL, MODE_RM, t_a, t_b, t_even, 1 << formats.FLAG_INEXACT, "tie (pos) -> -inf direction"),
        ]

    # --- subnormal / underflow products (7.5, tininess after rounding).
    # Subnormals do not exist for W_MANT = 0 (E8M0).
    if fmt.W_MANT > 0:
        minsn = encode_finite(0, 0, 1, fmt)                        # min subnormal
        psub  = encode_finite(0, fmt.bias - fmt.W_MANT - 1, 0, fmt)  # 2^(-W_MANT-1)
        v += [
            # min normal x 2^(-W_MANT-1) = 2^(emin-W_MANT-1) = half the min
            # subnormal: RNE ties to even (zero); RNA/RP round up to it.
            (OP_MUL, MODE_RNE, minn, psub, z, 1 << formats.FLAG_INEXACT,
             "half min sub (RNE tie -> 0, inexact)"),
            (OP_MUL, MODE_RNA, minn, psub, minsn,
             (1 << formats.FLAG_UNDERFLOW) | (1 << formats.FLAG_INEXACT),
             "half min sub (RNA -> min sub, underflow)"),
            (OP_MUL, MODE_RZ, minn, psub, z, 1 << formats.FLAG_INEXACT,
             "half min sub (RZ -> 0, inexact)"),
            (OP_MUL, MODE_RP, minn, psub, minsn,
             (1 << formats.FLAG_UNDERFLOW) | (1 << formats.FLAG_INEXACT),
             "half min sub (RP -> min sub, underflow)"),
            (OP_MUL, MODE_RM, minn, psub, z, 1 << formats.FLAG_INEXACT,
             "half min sub (RM, positive -> 0, inexact)"),
            # min normal x min normal = 2^(2emin), far below the min subnormal.
            (OP_MUL, MODE_RNE, minn, minn, z, 1 << formats.FLAG_INEXACT,
             "min normal x min normal -> 0 (RNE, inexact)"),
            (OP_MUL, MODE_RP, minn, minn, minsn,
             (1 << formats.FLAG_UNDERFLOW) | (1 << formats.FLAG_INEXACT),
             "min normal x min normal -> min sub (RP, underflow)"),
        ]

    # --- overflow (7.4)
    v += [
        (OP_MUL, MODE_RNE, maxf, maxf, inf, 0x05, "max x max -> +inf (RNE)"),
        (OP_MUL, MODE_RZ, maxf, maxf, maxf, 0x05, "max x max -> max (RZ)"),
        (OP_MUL, MODE_RM, maxf, maxf, maxf, 0x05, "max x max -> max (RM, positive)"),
        (OP_MUL, MODE_RP, maxf, maxf, inf, 0x05, "max x max -> +inf (RP)"),
        (OP_MUL, MODE_RNE, maxs, maxs, inf, 0x05, "-max x -max -> +inf (RNE)"),
        (OP_MUL, MODE_RNE, maxs, maxf, infs, 0x05, "-max x max -> -inf (RNE)"),
        (OP_MUL, MODE_RP, maxs, maxf, maxs, 0x05, "-max x max (RP, negative) -> -max"),
        (OP_MUL, MODE_RM, maxs, maxf, infs, 0x05, "-max x max (RM, negative) -> -inf"),
        (OP_MUL, MODE_RZ, maxs, maxf, maxs, 0x05, "-max x max (RZ) -> -max"),
    ]

    # --- E8M0 (W_MANT = 0): products of exact powers of two (6.3, 7.4).
    if fmt.W_MANT == 0:
        pe  = maxf                                                # 2^EMAX
        p20 = encode_finite(0, 20 + fmt.bias, 0, fmt)             # 2^20
        p40 = encode_finite(0, 40 + fmt.bias, 0, fmt)             # 2^40
        pn100 = encode_finite(0, -100 + fmt.bias, 0, fmt)         # 2^-100
        # Tie at 2^(emin-1): e_a + e_b = emin - 1. For emax = 2^(W_EXP-1)-1
        # (odd), e_a = -(emax-1)/2 and e_b = e_a - 1 give exactly that sum.
        ea = -(fmt.emax - 1) // 2
        eb = ea - 1
        tie_a = encode_finite(0, ea + fmt.bias, 0, fmt)
        tie_b = encode_finite(0, eb + fmt.bias, 0, fmt)
        v += [
            (OP_MUL, MODE_RNE, pe, pe, inf, 0x05, "e8m0: 2^EMAX x 2^EMAX -> inf (RNE, OF)"),
            (OP_MUL, MODE_RZ,  pe, pe, maxf, 0x05, "e8m0: 2^EMAX x 2^EMAX -> max (RZ, OF+INE)"),
            (OP_MUL, MODE_RP,  pe, pe, inf, 0x05, "e8m0: 2^EMAX x 2^EMAX -> inf (RP, OF)"),
            (OP_MUL, MODE_RM,  pe, pe, maxf, 0x05, "e8m0: 2^EMAX x 2^EMAX (pos) -> max (RM, OF+INE)"),
            (OP_MUL, MODE_RNE, p20, p20, p40, 0, "e8m0: 2^20 x 2^20 = 2^40 exact"),
            (OP_MUL, MODE_RNE, pn100, pn100, z, 1 << formats.FLAG_INEXACT,
             "e8m0: tiny product -> 0 (RNE, inexact)"),
            (OP_MUL, MODE_RP, pn100, pn100, minn, 1 << formats.FLAG_INEXACT,
             "e8m0: tiny product -> 2^emin (RP, inexact)"),
            (OP_MUL, MODE_RNE, tie_a, tie_b, z, 1 << formats.FLAG_INEXACT,
             "e8m0: half-2^emin tie -> 0 (RNE, inexact)"),
            (OP_MUL, MODE_RNA, tie_a, tie_b, minn, 1 << formats.FLAG_INEXACT,
             "e8m0: half-2^emin tie -> 2^emin (RNA)"),
            (OP_MUL, MODE_RP, tie_a, tie_b, minn, 1 << formats.FLAG_INEXACT,
             "e8m0: half-2^emin tie -> 2^emin (RP)"),
            (OP_MUL, MODE_RM, tie_a, tie_b, z, 1 << formats.FLAG_INEXACT,
             "e8m0: half-2^emin tie (pos) -> 0 (RM)"),
        ]
    return v


def _directed_div_vectors(fmt):
    """Hand-verified directed vectors for division (5.4.1)."""
    w = fmt.width
    neg = lambda x: x ^ (1 << (w - 1))
    m0 = fmt.W_MANT
    m1 = _norm1(fmt)          # 1.0
    m1s = neg(m1)
    m2 = encode_finite(0, fmt.bias + 1, 0, fmt)         # 2.0
    m4 = encode_finite(0, fmt.bias + 2, 0, fmt)         # 4.0
    m05 = encode_finite(0, fmt.bias - 1, 0, fmt)        # 0.5
    m025 = encode_finite(0, fmt.bias - 2, 0, fmt)       # 0.25
    maxf = max_finite_bits(0, fmt)
    maxs = neg(maxf)
    maxm = (1 << m0) - 1
    z = encode_zero(0, fmt)
    zs = encode_zero(1, fmt)
    inf = encode_inf(0, fmt)
    infs = encode_inf(1, fmt)
    qnan = encode_nan(0, fmt)
    minn = encode_finite(0, 1, 0, fmt)                  # min normal
    maxsn = encode_finite(0, 0, maxm, fmt)              # max subnormal
    minsn = encode_finite(0, 0, 1, fmt)                 # min subnormal
    inv = 1 << formats.FLAG_INVALID
    d0 = 1 << formats.FLAG_DIV0
    ine = 1 << formats.FLAG_INEXACT
    uf = 1 << formats.FLAG_UNDERFLOW
    v = []

    # --- zero products/quotients: sign is the XOR of the operand signs (6.3)
    v += [
        (OP_DIV, MODE_RNE, z, m1, z, 0, "0/1 = +0"),
        (OP_DIV, MODE_RNE, zs, m1, zs, 0, "-0/1 = -0"),
        (OP_DIV, MODE_RNE, z, m1s, zs, 0, "0/-1 = -0"),
        (OP_DIV, MODE_RNE, m1, z, inf, d0, "1/0 -> +inf, div0 (7.3)"),
        (OP_DIV, MODE_RNE, m1, zs, infs, d0, "1/-0 -> -inf, div0"),
        (OP_DIV, MODE_RNE, m1s, z, infs, d0, "-1/0 -> -inf, div0"),
        (OP_DIV, MODE_RNE, m1s, zs, inf, d0, "-1/-0 -> +inf, div0"),
        (OP_DIV, MODE_RNE, z, z, qnan, inv, "0/0 -> qNaN, invalid (7.2f)"),
        (OP_DIV, MODE_RNE, z, zs, qnan, inv, "0/-0 -> qNaN, invalid (7.2f)"),
    ]

    # --- infinities (6.3, 7.2f)
    v += [
        (OP_DIV, MODE_RNE, inf, m2, inf, 0, "inf/2 = +inf"),
        (OP_DIV, MODE_RNE, infs, m2, infs, 0, "-inf/2 = -inf"),
        (OP_DIV, MODE_RNE, m2, inf, z, 0, "2/inf = +0"),
        (OP_DIV, MODE_RNE, m2, infs, zs, 0, "2/-inf = -0"),
        (OP_DIV, MODE_RNE, inf, z, inf, 0, "inf/0 = +inf (not div0)"),
        (OP_DIV, MODE_RNE, z, inf, z, 0, "0/inf = +0"),
        (OP_DIV, MODE_RNE, inf, inf, qnan, inv, "inf/inf -> qNaN, invalid (7.2f)"),
        (OP_DIV, MODE_RNE, infs, infs, qnan, inv, "-inf/-inf -> qNaN, invalid"),
        (OP_DIV, MODE_RNE, inf, infs, qnan, inv, "inf/-inf -> qNaN, invalid"),
    ]

    # --- NaNs (6.2.3, 7.2a). Only meaningful where NaN encodings exist.
    if fmt.W_MANT > 0:
        v += [
            (OP_DIV, MODE_RNE, qnan, m1, qnan, 0, "qNaN/1 -> qNaN"),
            (OP_DIV, MODE_RNE, m1, qnan, qnan, 0, "1/qNaN -> qNaN"),
            (OP_DIV, MODE_RNE, inf, qnan, qnan, 0, "inf/qNaN -> qNaN"),
        ]
    if w == 32:
        v += [
            (OP_DIV, MODE_RNE, 0x7FC00001, m2, 0x7FC00001, 0, "qNaN payload passthrough"),
            (OP_DIV, MODE_RNE, 0x7F800001, m2, 0x7FC00001, inv, "sNaN -> qNaN, invalid"),
            (OP_DIV, MODE_RNE, m2, 0xFF80000F, 0x7FC0000F, inv, "sNaN payload kept, invalid"),
        ]

    # --- exact quotients (RNE)
    v += [
        (OP_DIV, MODE_RNE, m1, m1, m1, 0, "1/1 = 1"),
        (OP_DIV, MODE_RNE, m2, m1, m2, 0, "2/1 = 2"),
        (OP_DIV, MODE_RNE, m1, m2, m05, 0, "1/2 = 0.5"),
        (OP_DIV, MODE_RNE, m4, m2, m2, 0, "4/2 = 2"),
        (OP_DIV, MODE_RNE, m05, m2, m025, 0, "0.5/2 = 0.25"),
        (OP_DIV, MODE_RNE, m1, m05, m2, 0, "1/0.5 = 2"),
        (OP_DIV, MODE_RNE, m1s, m1s, m1, 0, "-1/-1 = 1"),
        (OP_DIV, MODE_RNE, m1s, m1, m1s, 0, "-1/1 = -1"),
        (OP_DIV, MODE_RNE, m1, m1s, m1s, 0, "1/-1 = -1"),
        (OP_DIV, MODE_RNE, maxf, m1, maxf, 0, "max/1 = max"),
    ]
    if fmt.W_MANT >= 3:
        m15 = encode_finite(0, fmt.bias, 1 << (m0 - 1), fmt)      # 1.5
        m3  = encode_finite(0, fmt.bias + 1, 1 << (m0 - 1), fmt)  # 3.0
        inv1 = encode_finite(0, fmt.bias, 1, fmt)                 # 1 + 2^-W_MANT
        below1 = encode_finite(0, fmt.bias - 1, (1 << m0) - 2, fmt)  # 1 - 2^-W_MANT
        up1 = encode_finite(0, fmt.bias - 1, (1 << m0) - 1, fmt)  # 1 - 2^-(W_MANT+1)
        v += [
            (OP_DIV, MODE_RNE, m15, m3, m05, 0, "1.5/3 = 0.5"),
            (OP_DIV, MODE_RNE, m3, m15, m2, 0, "3/1.5 = 2"),
            (OP_DIV, MODE_RNE, m15, m1s, neg(m15), 0, "1.5/-1 = -1.5"),
            # 1/(1+2^-m) = 1 - 2^-m + 2^-2m - ...: on the [0.5,1) grid the
            # value is 2^m - 2 + 2^-m ulps, so RNE/RZ/RM drop to 1 - 2^-m and
            # RP rounds up to 1 - 2^-(m+1).
            (OP_DIV, MODE_RNE, m1, inv1, below1, ine, "1/(1+2^-m) -> 1-2^-m (RNE, inexact)"),
            (OP_DIV, MODE_RZ,  m1, inv1, below1, ine, "1/(1+2^-m) -> 1-2^-m (RZ)"),
            (OP_DIV, MODE_RM,  m1, inv1, below1, ine, "1/(1+2^-m) (pos) -> 1-2^-m (RM)"),
            (OP_DIV, MODE_RP,  m1, inv1, up1, ine, "1/(1+2^-m) (RP) -> 1-2^-(m+1), inexact"),
        ]

    # --- inexact / tie rounding, binary32 only
    if w == 32:
        v += [
            # 1/3 = 0.3333... -> mantissa 0x2AAAAAB (round up) / 0x2AAAAAA (down).
            (OP_DIV, MODE_RNE, m1, 0x40400000, 0x3EAAAAAB, ine, "1/3 -> up (RNE)"),
            (OP_DIV, MODE_RNA, m1, 0x40400000, 0x3EAAAAAB, ine, "1/3 -> up (RNA)"),
            (OP_DIV, MODE_RZ,  m1, 0x40400000, 0x3EAAAAAA, ine, "1/3 -> down (RZ)"),
            (OP_DIV, MODE_RP,  m1, 0x40400000, 0x3EAAAAAB, ine, "1/3 -> up (RP)"),
            (OP_DIV, MODE_RM,  m1, 0x40400000, 0x3EAAAAAA, ine, "1/3 (pos) -> down (RM)"),
            # 2/3 = 0.666... = 1.333...*2^-1 -> mantissa 0x2AAAAB, exp 0x7E.
            (OP_DIV, MODE_RNE, m2, 0x40400000, 0x3F2AAAAB, ine, "2/3 -> up (RNE)"),
            (OP_DIV, MODE_RZ,  m2, 0x40400000, 0x3F2AAAAA, ine, "2/3 -> down (RZ)"),
        ]

    # --- subnormal / underflow quotients (7.5, tininess after rounding).
    # Subnormals do not exist for W_MANT = 0 (E8M0).
    if fmt.W_MANT > 0:
        # min normal / 2 = 2^(emin-1): an exact subnormal (significand 2^(W_MANT-1)).
        v += [
            (OP_DIV, MODE_RNE, minn, m2, encode_finite(0, 0, 1 << (m0 - 1), fmt), 0,
             "min normal/2 = exact subnormal"),
        ]
        # min sub / 2 = 2^(emin-W_MANT-1) = half the min subnormal: RNE tie -> 0.
        v += [
            (OP_DIV, MODE_RNE, minsn, m2, z, ine, "min sub/2 (RNE tie -> 0, inexact)"),
            (OP_DIV, MODE_RNA, minsn, m2, minsn, uf | ine, "min sub/2 (RNA -> min sub, underflow)"),
            (OP_DIV, MODE_RZ,  minsn, m2, z, ine, "min sub/2 (RZ -> 0, inexact)"),
            (OP_DIV, MODE_RP,  minsn, m2, minsn, uf | ine, "min sub/2 (RP -> min sub, underflow)"),
            (OP_DIV, MODE_RM,  minsn, m2, z, ine, "min sub/2 (RM, positive -> 0, inexact)"),
            # max sub / 2 = (2^W_MANT-1)/2 ulps: RNE tie -> even (up), RZ down.
            (OP_DIV, MODE_RNE, maxsn, m2, encode_finite(0, 0, 1 << (m0 - 1), fmt), uf | ine,
             "max sub/2 (RNE tie -> even up, underflow)"),
            (OP_DIV, MODE_RZ,  maxsn, m2, encode_finite(0, 0, (1 << (m0 - 1)) - 1, fmt), uf | ine,
             "max sub/2 (RZ -> down, underflow)"),
        ]

    # --- overflow (7.4): dividing by a value < 1 inflates the quotient.
    v += [
        (OP_DIV, MODE_RNE, maxf, m05, inf, 0x05, "max/0.5 -> +inf (RNE)"),
        (OP_DIV, MODE_RZ,  maxf, m05, maxf, 0x05, "max/0.5 -> max (RZ)"),
        (OP_DIV, MODE_RM,  maxf, m05, maxf, 0x05, "max/0.5 -> max (RM, positive)"),
        (OP_DIV, MODE_RP,  maxf, m05, inf, 0x05, "max/0.5 -> +inf (RP)"),
        (OP_DIV, MODE_RNE, maxs, m05, infs, 0x05, "-max/0.5 -> -inf (RNE)"),
        (OP_DIV, MODE_RP,  maxs, m05, maxs, 0x05, "-max/0.5 (RP, negative) -> -max"),
        (OP_DIV, MODE_RM,  maxs, m05, infs, 0x05, "-max/0.5 (RM, negative) -> -inf"),
        (OP_DIV, MODE_RNE, maxf, m025, inf, 0x05, "max/0.25 -> +inf (RNE)"),
    ]

    # --- E8M0 (W_MANT = 0): quotients of exact powers of two (6.3, 7.3, 7.4).
    if fmt.W_MANT == 0:
        pe  = maxf                                                # 2^EMAX
        p10 = encode_finite(0, 10 + fmt.bias, 0, fmt)             # 2^10
        p5  = encode_finite(0, 5 + fmt.bias, 0, fmt)              # 2^5
        p15 = encode_finite(0, 15 + fmt.bias, 0, fmt)             # 2^15
        pn5 = encode_finite(0, -5 + fmt.bias, 0, fmt)             # 2^-5
        pn100 = encode_finite(0, -100 + fmt.bias, 0, fmt)         # 2^-100
        # Tie at 2^(emin-1): e_a - e_b = emin - 1. For emax = 2^(W_EXP-1)-1
        # (odd), e_a = -(emax-1)/2 and e_b = e_a + emax give exactly that.
        ea = -(fmt.emax - 1) // 2
        eb = ea + fmt.emax
        tie_a = encode_finite(0, ea + fmt.bias, 0, fmt)
        tie_b = encode_finite(0, eb + fmt.bias, 0, fmt)
        v += [
            (OP_DIV, MODE_RNE, p10, p5, p5, 0, "e8m0: 2^10/2^5 = 2^5"),
            (OP_DIV, MODE_RNE, p10, pn5, p15, 0, "e8m0: 2^10/2^-5 = 2^15"),
            (OP_DIV, MODE_RNE, pe, pn100, inf, 0x05, "e8m0: 2^EMAX/2^-100 -> inf (RNE, OF)"),
            (OP_DIV, MODE_RZ,  pe, pn100, maxf, 0x05, "e8m0: 2^EMAX/2^-100 -> max (RZ, OF+INE)"),
            (OP_DIV, MODE_RNE, pn100, pe, z, ine, "e8m0: tiny quotient -> 0 (RNE, inexact)"),
            (OP_DIV, MODE_RP,  pn100, pe, minn, ine, "e8m0: tiny quotient -> 2^emin (RP, inexact)"),
            (OP_DIV, MODE_RNE, tie_a, tie_b, z, ine, "e8m0: half-2^emin tie -> 0 (RNE, inexact)"),
            (OP_DIV, MODE_RNA, tie_a, tie_b, minn, ine, "e8m0: half-2^emin tie -> 2^emin (RNA)"),
            (OP_DIV, MODE_RP,  tie_a, tie_b, minn, ine, "e8m0: half-2^emin tie -> 2^emin (RP)"),
            (OP_DIV, MODE_RM,  tie_a, tie_b, z, ine, "e8m0: half-2^emin tie (pos) -> 0 (RM)"),
            (OP_DIV, MODE_RNE, pe, pe, m1, 0, "e8m0: 2^EMAX/2^EMAX = 1"),
            (OP_DIV, MODE_RNE, inf, z, inf, 0, "e8m0: inf/0 -> +inf (not div0)"),
            (OP_DIV, MODE_RNE, z, z, inf, inv, "e8m0: 0/0 -> +inf, invalid (7.2f)"),
            (OP_DIV, MODE_RNE, pe, z, inf, d0, "e8m0: 2^EMAX/0 -> +inf, div0 (7.3)"),
        ]
    return v


def _directed_sqrt_vectors(fmt):
    """Hand-verified directed vectors for square root (5.4.1)."""
    w = fmt.width
    neg = lambda x: x ^ (1 << (w - 1))
    m0 = fmt.W_MANT
    m1 = _norm1(fmt)          # 1.0
    m1s = neg(m1)
    m2 = encode_finite(0, fmt.bias + 1, 0, fmt)         # 2.0
    m4 = encode_finite(0, fmt.bias + 2, 0, fmt)         # 4.0
    m05 = encode_finite(0, fmt.bias - 1, 0, fmt)        # 0.5
    m025 = encode_finite(0, fmt.bias - 2, 0, fmt)       # 0.25
    minn = encode_finite(0, 1, 0, fmt)                  # min normal
    z = encode_zero(0, fmt)
    zs = encode_zero(1, fmt)
    inf = encode_inf(0, fmt)
    infs = encode_inf(1, fmt)
    qnan = encode_nan(0, fmt)
    inv = 1 << formats.FLAG_INVALID
    ine = 1 << formats.FLAG_INEXACT
    v = []

    # --- specials (6.3, 7.2g)
    v += [
        (OP_SQRT, MODE_RNE, z, 0, z, 0, "sqrt(0) = 0"),
        (OP_SQRT, MODE_RNE, zs, 0, zs, 0, "sqrt(-0) = -0"),
        (OP_SQRT, MODE_RNE, m1, 0, m1, 0, "sqrt(1) = 1"),
        (OP_SQRT, MODE_RNE, m4, 0, m2, 0, "sqrt(4) = 2"),
        (OP_SQRT, MODE_RNE, m025, 0, m05, 0, "sqrt(0.25) = 0.5"),
        (OP_SQRT, MODE_RNE, m1s, 0, qnan, inv, "sqrt(-1) -> qNaN, invalid (7.2g)"),
        (OP_SQRT, MODE_RNE, inf, 0, inf, 0, "sqrt(inf) = inf"),
        (OP_SQRT, MODE_RNE, infs, 0, qnan, inv, "sqrt(-inf) -> qNaN, invalid"),
    ]

    # --- NaNs (6.2.3, 7.2a). Only meaningful where NaN encodings exist.
    if fmt.W_MANT > 0:
        v += [
            (OP_SQRT, MODE_RNE, qnan, 0, qnan, 0, "sqrt(qNaN) -> qNaN"),
        ]
    if w == 32:
        v += [
            (OP_SQRT, MODE_RNE, 0x7FC00001, 0, 0x7FC00001, 0, "qNaN payload passthrough"),
            (OP_SQRT, MODE_RNE, 0x7F800001, 0, 0x7FC00001, inv, "sNaN -> qNaN, invalid"),
        ]

    # --- exact squares (RNE)
    if fmt.W_MANT >= 3:
        m9   = encode_finite(0, fmt.bias + 3, 1 << (m0 - 3), fmt)   # 9.0 = 1.125*2^3
        m225 = encode_finite(0, fmt.bias + 1, 1 << (m0 - 3), fmt)   # 2.25
        m15  = encode_finite(0, fmt.bias, 1 << (m0 - 1), fmt)       # 1.5
        m3   = encode_finite(0, fmt.bias + 1, 1 << (m0 - 1), fmt)   # 3.0
        v += [
            (OP_SQRT, MODE_RNE, m9, 0, m3, 0, "sqrt(9) = 3"),
            (OP_SQRT, MODE_RNE, m225, 0, m15, 0, "sqrt(2.25) = 1.5"),
        ]

    # --- irrational root sqrt(2) ~ 1.4142, binary16-only hand-computed value
    if fmt.W_EXP == 5 and fmt.W_MANT == 10:
        v += [
            (OP_SQRT, MODE_RNE, m2, 0, 0x3DA8, ine, "sqrt(2) (RNE)"),
            (OP_SQRT, MODE_RZ,  m2, 0, 0x3DA8, ine, "sqrt(2) (RZ)"),
            (OP_SQRT, MODE_RM,  m2, 0, 0x3DA8, ine, "sqrt(2) (RM, positive)"),
            (OP_SQRT, MODE_RP,  m2, 0, 0x3DA9, ine, "sqrt(2) (RP)"),
        ]

    # --- boundary: sqrt of min normal is exact (emin is even for W_EXP >= 2).
    v += [
        (OP_SQRT, MODE_RNE, minn, 0, encode_finite(0, fmt.emin // 2 + fmt.bias, 0, fmt), 0,
         "sqrt(min normal) = 2^(emin/2)"),
    ]

    # --- E8M0 (W_MANT = 0): roots of exact powers of two.
    if fmt.W_MANT == 0:
        p10 = encode_finite(0, 10 + fmt.bias, 0, fmt)   # 2^10
        p5  = encode_finite(0, 5 + fmt.bias, 0, fmt)    # 2^5
        p4  = encode_finite(0, 4 + fmt.bias, 0, fmt)    # 2^4
        p9  = encode_finite(0, 9 + fmt.bias, 0, fmt)    # 2^9
        v += [
            (OP_SQRT, MODE_RNE, p10, 0, p5, 0, "e8m0: sqrt(2^10) = 2^5 exact"),
            (OP_SQRT, MODE_RNE, p9, 0, p4, ine, "e8m0: sqrt(2^9) -> 2^4 (RNE, inexact)"),
            (OP_SQRT, MODE_RNA, p9, 0, p4, ine, "e8m0: sqrt(2^9) -> 2^4 (RNA)"),
            (OP_SQRT, MODE_RZ,  p9, 0, p4, ine, "e8m0: sqrt(2^9) -> 2^4 (RZ)"),
            (OP_SQRT, MODE_RP,  p9, 0, p5, ine, "e8m0: sqrt(2^9) -> 2^5 (RP)"),
            (OP_SQRT, MODE_RM,  p9, 0, p4, ine, "e8m0: sqrt(2^9) -> 2^4 (RM)"),
            (OP_SQRT, MODE_RNE, neg(p5), 0, inf, inv, "e8m0: sqrt(-2^5) -> +inf, invalid"),
            (OP_SQRT, MODE_RNE, infs, 0, inf, inv, "e8m0: sqrt(-inf) -> +inf, invalid"),
        ]
    return v


def _directed_fma_vectors(fmt):
    """Hand-verified directed vectors for fused multiply-add (5.4.1)."""
    w = fmt.width
    neg = lambda x: x ^ (1 << (w - 1))
    m0 = fmt.W_MANT
    m1 = _norm1(fmt)          # 1.0
    m1s = neg(m1)
    m2 = encode_finite(0, fmt.bias + 1, 0, fmt)         # 2.0
    m05 = encode_finite(0, fmt.bias - 1, 0, fmt)        # 0.5
    m025 = encode_finite(0, fmt.bias - 2, 0, fmt)       # 0.25
    maxf = max_finite_bits(0, fmt)
    minn = encode_finite(0, 1, 0, fmt)                  # min normal
    minsn = encode_finite(0, 0, 1, fmt)                 # min subnormal
    z = encode_zero(0, fmt)
    zs = encode_zero(1, fmt)
    inf = encode_inf(0, fmt)
    infs = encode_inf(1, fmt)
    qnan = encode_nan(0, fmt)
    inv = 1 << formats.FLAG_INVALID
    ine = 1 << formats.FLAG_INEXACT
    uf = 1 << formats.FLAG_UNDERFLOW
    v = []

    # --- exact arithmetic (RNE)
    v += [
        (OP_FMA, MODE_RNE, m1, m1, m1, m2, 0, "1x1+1 = 2"),
        (OP_FMA, MODE_RNE, m05, m05, m025, m05, 0, "0.5x0.5+0.25 = 0.5"),
        (OP_FMA, MODE_RNE, m2, m05, m1, m2, 0, "2x0.5+1 = 2"),
        (OP_FMA, MODE_RNE, m1, m1, z, m1, 0, "1x1+0 = 1"),
        (OP_FMA, MODE_RNE, m1, m2, m1s, m1, 0, "1x2-1 = 1"),
        (OP_FMA, MODE_RNE, minn, m2, z, encode_finite(0, fmt.emin + 1 + fmt.bias, 0, fmt), 0,
         "min x 2 + 0 exact"),
    ]
    if fmt.W_MANT >= 3:
        m3 = encode_finite(0, fmt.bias + 1, 1 << (m0 - 1), fmt)  # 3.0
        v += [
            (OP_FMA, MODE_RNE, m1, m2, m1, m3, 0, "1x2+1 = 3"),
        ]
    if fmt.W_MANT >= 3:
        m5 = encode_finite(0, fmt.bias + 2, 1 << (m0 - 2), fmt)   # 5.0 = 1.25*2^2
        u = encode_finite(0, fmt.bias, 1, fmt)                    # 1 + 2^-W_MANT
        half = encode_finite(0, fmt.bias - m0 - 1, 0, fmt)        # 2^-(W_MANT+1)
        v += [
            (OP_FMA, MODE_RNE, m2, m2, m1, m5, 0, "2x2+1 = 5"),
            # Single rounding tie: (1+2^-m)x1 + 2^-(m+1) = 1 + 1.5*2^-m.
            (OP_FMA, MODE_RNE, u, m1, half, encode_finite(0, fmt.bias, 2, fmt), ine,
             "single-round tie -> even (up)"),
            (OP_FMA, MODE_RNA, u, m1, half, encode_finite(0, fmt.bias, 2, fmt), ine,
             "single-round tie -> away"),
            (OP_FMA, MODE_RZ, u, m1, half, u, ine, "single-round tie -> toward zero"),
            (OP_FMA, MODE_RP, u, m1, half, encode_finite(0, fmt.bias, 2, fmt), ine,
             "single-round tie -> +inf direction"),
            (OP_FMA, MODE_RM, u, m1, half, u, ine, "single-round tie (pos) -> -inf direction"),
        ]

    # --- cancellation / zero signs (6.3)
    v += [
        (OP_FMA, MODE_RNE, m1, m1, m1s, z, 0, "1x1-1 = +0 (cancellation)"),
        (OP_FMA, MODE_RM,  m1, m1, m1s, zs, 0, "cancellation -> -0 under RM"),
        (OP_FMA, MODE_RNE, z, m2, m1, m1, 0, "0x2+1 = 1"),
        (OP_FMA, MODE_RNE, z, m2, z, z, 0, "0x2+0 = +0"),
        (OP_FMA, MODE_RNE, zs, m2, z, z, 0, "-0x2+0 = +0 (opposite zeros)"),
        (OP_FMA, MODE_RM,  zs, m2, z, zs, 0, "-0x2+0 = -0 under RM"),
        (OP_FMA, MODE_RNE, zs, m2, zs, zs, 0, "-0x2-0 = -0"),
        (OP_FMA, MODE_RM,  z, m2, zs, zs, 0, "0x2-0 = -0 under RM"),
        (OP_FMA, MODE_RNE, m1, m2, zs, m2, 0, "1x2-0 = 2"),
    ]

    # --- infinities (7.2d, 7.2e)
    v += [
        (OP_FMA, MODE_RNE, inf, z, m1, qnan, inv, "inf x 0 + 1 -> qNaN, invalid (7.2e)"),
        (OP_FMA, MODE_RNE, z, inf, m1, qnan, inv, "0 x inf + 1 -> qNaN, invalid"),
        (OP_FMA, MODE_RNE, inf, m2, m1, inf, 0, "inf x 2 + 1 = +inf"),
        (OP_FMA, MODE_RNE, inf, m2, infs, qnan, inv, "inf x 2 + -inf -> invalid (7.2d)"),
        (OP_FMA, MODE_RNE, m2, m2, inf, inf, 0, "2 x 2 + inf = +inf"),
        (OP_FMA, MODE_RNE, m2, m2, infs, infs, 0, "2 x 2 + -inf = -inf"),
        (OP_FMA, MODE_RNE, inf, m1, m1, inf, 0, "inf x 1 + 1 = +inf"),
    ]

    # --- overflow (7.4)
    v += [
        (OP_FMA, MODE_RNE, maxf, m2, m1, inf, 0x05, "max x 2 + 1 -> +inf (RNE)"),
        (OP_FMA, MODE_RZ,  maxf, m2, m1, maxf, 0x05, "max x 2 + 1 -> max (RZ)"),
        (OP_FMA, MODE_RNE, maxf, m1, maxf, inf, 0x05, "max x 1 + max -> +inf"),
    ]

    # --- subnormal / underflow products (7.5)
    if fmt.W_MANT > 0:
        v += [
            (OP_FMA, MODE_RNE, minn, minn, z, z, ine, "min x min + 0 -> 0 (RNE, inexact)"),
            (OP_FMA, MODE_RP,  minn, minn, z, minsn, uf | ine, "min x min + 0 (RP) -> min sub"),
            (OP_FMA, MODE_RNE, minn, minn, minsn, minsn, uf | ine,
             "min x min + min sub (RNE) -> min sub"),
        ]

    # --- E8M0 (W_MANT = 0)
    if fmt.W_MANT == 0:
        p2 = encode_finite(0, 2 + fmt.bias, 0, fmt)    # 2^2
        p3 = encode_finite(0, 3 + fmt.bias, 0, fmt)    # 2^3
        p4 = encode_finite(0, 4 + fmt.bias, 0, fmt)    # 2^4
        p5 = encode_finite(0, 5 + fmt.bias, 0, fmt)    # 2^5
        v += [
            (OP_FMA, MODE_RNE, p2, p2, p2, p4, ine, "e8m0: 2^2 x 2^2 + 2^2 = 2^4 (20 -> 16, inexact)"),
            (OP_FMA, MODE_RNE, p2, p2, p3, p5, ine,
             "e8m0: 2^2 x 2^2 + 2^3 = 2^5 (24 tie -> larger, RNE)"),
            (OP_FMA, MODE_RZ,  p2, p2, p3, p4, ine, "e8m0: 2^2 x 2^2 + 2^3 (RZ) = 2^4"),
            (OP_FMA, MODE_RNE, inf, z, p2, inf, inv, "e8m0: inf x 0 + 2 -> +inf, invalid"),
            (OP_FMA, MODE_RNE, inf, p2, inf, inf, 0, "e8m0: inf x 2 + inf = +inf"),
            (OP_FMA, MODE_RNE, inf, p2, neg(inf), inf, inv, "e8m0: inf x 2 - inf -> +inf, invalid"),
            (OP_FMA, MODE_RNE, p2, z, p3, p3, 0, "e8m0: 2^2 x 0 + 2^3 = 2^3"),
        ]
    return v


def _directed_minmax_vectors(fmt):
    """Hand-verified directed vectors for minimum/maximum (5.6.1)."""
    w = fmt.width
    neg = lambda x: x ^ (1 << (w - 1))
    m0 = fmt.W_MANT
    m1 = _norm1(fmt)
    m1s = neg(m1)
    m2 = encode_finite(0, fmt.bias + 1, 0, fmt)
    m05 = encode_finite(0, fmt.bias - 1, 0, fmt)
    maxf = max_finite_bits(0, fmt)
    minn = encode_finite(0, 1, 0, fmt)
    z = encode_zero(0, fmt)
    zs = encode_zero(1, fmt)
    inf = encode_inf(0, fmt)
    infs = encode_inf(1, fmt)
    qnan = encode_nan(0, fmt)
    inv = 1 << formats.FLAG_INVALID
    v = []

    v += [
        (OP_MIN, MODE_RNE, m1, m2, m1, 0, "min(1,2) = 1"),
        (OP_MAX, MODE_RNE, m1, m2, m2, 0, "max(1,2) = 2"),
        (OP_MIN, MODE_RNE, m2, m1, m1, 0, "min(2,1) = 1"),
        (OP_MAX, MODE_RNE, m2, m1, m2, 0, "max(2,1) = 2"),
        (OP_MIN, MODE_RNE, m1, m1, m1, 0, "min(1,1) = 1"),
        (OP_MIN, MODE_RNE, m1s, m1, m1s, 0, "min(-1,1) = -1"),
        (OP_MAX, MODE_RNE, m1s, m1, m1, 0, "max(-1,1) = 1"),
        (OP_MIN, MODE_RNE, m1, m1s, m1s, 0, "min(1,-1) = -1"),
        (OP_MAX, MODE_RNE, m1, m1s, m1, 0, "max(1,-1) = 1"),
        (OP_MIN, MODE_RNE, m05, m2, m05, 0, "min(0.5,2) = 0.5"),
        (OP_MAX, MODE_RNE, m05, m2, m2, 0, "max(0.5,2) = 2"),
        (OP_MIN, MODE_RNE, minn, maxf, minn, 0, "min(min,max) = min"),
        (OP_MAX, MODE_RNE, minn, maxf, maxf, 0, "max(min,max) = max"),
        # infinities
        (OP_MIN, MODE_RNE, inf, m1, m1, 0, "min(inf,1) = 1"),
        (OP_MAX, MODE_RNE, inf, m1, inf, 0, "max(inf,1) = inf"),
        (OP_MIN, MODE_RNE, infs, inf, infs, 0, "min(-inf,inf) = -inf"),
        (OP_MAX, MODE_RNE, infs, inf, inf, 0, "max(-inf,inf) = inf"),
        (OP_MIN, MODE_RNE, m1, infs, infs, 0, "min(1,-inf) = -inf"),
        (OP_MAX, MODE_RNE, m1, infs, m1, 0, "max(1,-inf) = 1"),
        (OP_MIN, MODE_RNE, infs, infs, infs, 0, "min(-inf,-inf) = -inf"),
        (OP_MAX, MODE_RNE, inf, inf, inf, 0, "max(inf,inf) = inf"),
        # zeros (5.6.1): minimum(-0,+0) = -0, maximum(-0,+0) = +0
        (OP_MIN, MODE_RNE, z, zs, zs, 0, "min(+0,-0) = -0"),
        (OP_MIN, MODE_RNE, zs, z, zs, 0, "min(-0,+0) = -0"),
        (OP_MAX, MODE_RNE, z, zs, z, 0, "max(+0,-0) = +0"),
        (OP_MAX, MODE_RNE, zs, z, z, 0, "max(-0,+0) = +0"),
        (OP_MIN, MODE_RNE, z, z, z, 0, "min(+0,+0) = +0"),
        (OP_MIN, MODE_RNE, zs, zs, zs, 0, "min(-0,-0) = -0"),
        (OP_MAX, MODE_RNE, z, z, z, 0, "max(+0,+0) = +0"),
    ]
    if fmt.W_MANT > 0:
        v += [
            (OP_MIN, MODE_RNE, qnan, m1, qnan, 0, "min(qNaN,1) -> qNaN"),
            (OP_MIN, MODE_RNE, m1, qnan, qnan, 0, "min(1,qNaN) -> qNaN"),
            (OP_MAX, MODE_RNE, qnan, inf, qnan, 0, "max(qNaN,inf) -> qNaN"),
        ]
    if w == 32:
        v += [
            (OP_MIN, MODE_RNE, 0x7F800001, m1, 0x7FC00001, inv, "min(sNaN,1) -> qNaN, invalid"),
            (OP_MIN, MODE_RNE, 0x7FC00003, m1, 0x7FC00003, 0, "min(qNaN,1) payload passthrough"),
        ]
    return v


def _directed_cmp_vectors(fmt):
    """Hand-verified directed vectors for quiet comparison (5.11).

    Tuples are (mode, rm, a, b, exp_y, exp_f, exp_cmp, note); y is unused (0).
    """
    w = fmt.width
    neg = lambda x: x ^ (1 << (w - 1))
    m1 = _norm1(fmt)
    m1s = neg(m1)
    m2 = encode_finite(0, fmt.bias + 1, 0, fmt)
    m05 = encode_finite(0, fmt.bias - 1, 0, fmt)
    maxf = max_finite_bits(0, fmt)
    z = encode_zero(0, fmt)
    zs = encode_zero(1, fmt)
    inf = encode_inf(0, fmt)
    infs = encode_inf(1, fmt)
    qnan = encode_nan(0, fmt)
    inv = 1 << formats.FLAG_INVALID
    v = []

    v += [
        (OP_CMP, MODE_RNE, m1, m1, 0, 0, CMP_EQ, "1 == 1"),
        (OP_CMP, MODE_RNE, m1, m2, 0, 0, CMP_LT, "1 < 2"),
        (OP_CMP, MODE_RNE, m2, m1, 0, 0, CMP_GT, "2 > 1"),
        (OP_CMP, MODE_RNE, m1s, m1, 0, 0, CMP_LT, "-1 < 1"),
        (OP_CMP, MODE_RNE, m1, m1s, 0, 0, CMP_GT, "1 > -1"),
        (OP_CMP, MODE_RNE, m1s, m2, 0, 0, CMP_LT, "-1 < 2"),
        (OP_CMP, MODE_RNE, m2, m1s, 0, 0, CMP_GT, "2 > -1"),
        (OP_CMP, MODE_RNE, m05, m2, 0, 0, CMP_LT, "0.5 < 2"),
        (OP_CMP, MODE_RNE, m05, m1, 0, 0, CMP_LT, "0.5 < 1"),
        (OP_CMP, MODE_RNE, m1, maxf, 0, 0, CMP_LT, "1 < max"),
        (OP_CMP, MODE_RNE, maxf, m1, 0, 0, CMP_GT, "max > 1"),
        # zeros compare equal (including -0 vs +0)
        (OP_CMP, MODE_RNE, z, z, 0, 0, CMP_EQ, "+0 == +0"),
        (OP_CMP, MODE_RNE, z, zs, 0, 0, CMP_EQ, "+0 == -0"),
        (OP_CMP, MODE_RNE, zs, z, 0, 0, CMP_EQ, "-0 == +0"),
        (OP_CMP, MODE_RNE, zs, zs, 0, 0, CMP_EQ, "-0 == -0"),
        (OP_CMP, MODE_RNE, z, m1, 0, 0, CMP_LT, "+0 < 1"),
        (OP_CMP, MODE_RNE, zs, m1, 0, 0, CMP_LT, "-0 < 1"),
        (OP_CMP, MODE_RNE, m1, z, 0, 0, CMP_GT, "1 > +0"),
        (OP_CMP, MODE_RNE, m1s, z, 0, 0, CMP_LT, "-1 < -0"),
        (OP_CMP, MODE_RNE, zs, m1s, 0, 0, CMP_GT, "-0 > -1"),
        # infinities
        (OP_CMP, MODE_RNE, inf, m1, 0, 0, CMP_GT, "inf > 1"),
        (OP_CMP, MODE_RNE, m1, inf, 0, 0, CMP_LT, "1 < inf"),
        (OP_CMP, MODE_RNE, infs, m1, 0, 0, CMP_LT, "-inf < 1"),
        (OP_CMP, MODE_RNE, infs, inf, 0, 0, CMP_LT, "-inf < inf"),
        (OP_CMP, MODE_RNE, inf, infs, 0, 0, CMP_GT, "inf > -inf"),
        (OP_CMP, MODE_RNE, inf, inf, 0, 0, CMP_EQ, "inf == inf"),
        (OP_CMP, MODE_RNE, infs, infs, 0, 0, CMP_EQ, "-inf == -inf"),
        (OP_CMP, MODE_RNE, infs, maxf, 0, 0, CMP_LT, "-inf < max"),
        (OP_CMP, MODE_RNE, inf, maxf, 0, 0, CMP_GT, "inf > max"),
        (OP_CMP, MODE_RNE, neg(maxf), maxf, 0, 0, CMP_LT, "-max < max"),
    ]
    # NaNs compare unordered; only a signaling NaN signals invalid (quiet
    # comparison). Only meaningful where NaN encodings exist (W_MANT > 0).
    if fmt.W_MANT > 0:
        v += [
            (OP_CMP, MODE_RNE, qnan, m1, 0, 0, CMP_UN, "qNaN unordered"),
            (OP_CMP, MODE_RNE, m1, qnan, 0, 0, CMP_UN, "qNaN unordered (b)"),
            (OP_CMP, MODE_RNE, qnan, qnan, 0, 0, CMP_UN, "qNaN vs qNaN unordered"),
            (OP_CMP, MODE_RNE, qnan, inf, 0, 0, CMP_UN, "qNaN vs inf unordered"),
            (OP_CMP, MODE_RNE, infs, qnan, 0, 0, CMP_UN, "-inf vs qNaN unordered"),
        ]
    if w == 32:
        v += [
            (OP_CMP, MODE_RNE, 0x7F800001, m1, 0, inv, CMP_UN, "sNaN unordered, invalid"),
            (OP_CMP, MODE_RNE, m1, 0x7F800001, 0, inv, CMP_UN, "sNaN unordered, invalid (b)"),
            (OP_CMP, MODE_RNE, 0x7FC00001, 0x7F800001, 0, inv, CMP_UN,
             "qNaN/sNaN unordered, invalid"),
        ]
    return v


def _directed_totalorder_vectors(fmt):
    """Hand-verified directed vectors for totalOrder (5.10).

    Tuples are (mode, rm, a, b, exp_y, exp_f, exp_cmp, note); y is unused (0),
    cmp[0] = 1 iff a precedes-or-equals b. Never signals.
    """
    w = fmt.width
    neg = lambda x: x ^ (1 << (w - 1))
    m1 = _norm1(fmt)
    m1s = neg(m1)
    m2 = encode_finite(0, fmt.bias + 1, 0, fmt)
    m2s = neg(m2)
    m05 = encode_finite(0, fmt.bias - 1, 0, fmt)
    maxf = max_finite_bits(0, fmt)
    z = encode_zero(0, fmt)
    zs = encode_zero(1, fmt)
    inf = encode_inf(0, fmt)
    infs = encode_inf(1, fmt)
    v = []

    v += [
        # identical encodings: totalOrder(x,x) is true (non-strict).
        (OP_TOTALORDER, MODE_RNE, m1, m1, 0, 0, 1, "1 <= 1"),
        (OP_TOTALORDER, MODE_RNE, z, z, 0, 0, 1, "+0 <= +0"),
        (OP_TOTALORDER, MODE_RNE, zs, zs, 0, 0, 1, "-0 <= -0"),
        (OP_TOTALORDER, MODE_RNE, inf, inf, 0, 0, 1, "inf <= inf"),
        # numeric ordering
        (OP_TOTALORDER, MODE_RNE, m1, m2, 0, 0, 1, "1 <= 2"),
        (OP_TOTALORDER, MODE_RNE, m2, m1, 0, 0, 0, "2 <= 1 false"),
        (OP_TOTALORDER, MODE_RNE, m1s, m1, 0, 0, 1, "-1 <= 1"),
        (OP_TOTALORDER, MODE_RNE, m2s, m1s, 0, 0, 1, "-2 <= -1"),
        (OP_TOTALORDER, MODE_RNE, m1s, m2s, 0, 0, 0, "-1 <= -2 false"),
        (OP_TOTALORDER, MODE_RNE, m05, m1, 0, 0, 1, "0.5 <= 1"),
        # -0 sorts below +0 (5.10), opposite to min/max
        (OP_TOTALORDER, MODE_RNE, zs, z, 0, 0, 1, "-0 <= +0"),
        (OP_TOTALORDER, MODE_RNE, z, zs, 0, 0, 0, "+0 <= -0 false"),
        (OP_TOTALORDER, MODE_RNE, m1s, z, 0, 0, 1, "-1 <= +0"),
        (OP_TOTALORDER, MODE_RNE, zs, m1, 0, 0, 1, "-0 <= 1"),
        (OP_TOTALORDER, MODE_RNE, z, m1, 0, 0, 1, "+0 <= 1"),
        (OP_TOTALORDER, MODE_RNE, zs, m1s, 0, 0, 0, "-0 <= -1 false"),
        (OP_TOTALORDER, MODE_RNE, maxf, inf, 0, 0, 1, "max <= inf"),
        (OP_TOTALORDER, MODE_RNE, inf, maxf, 0, 0, 0, "inf <= max false"),
        (OP_TOTALORDER, MODE_RNE, infs, m1s, 0, 0, 1, "-inf <= -1"),
        (OP_TOTALORDER, MODE_RNE, infs, inf, 0, 0, 1, "-inf <= inf"),
        (OP_TOTALORDER, MODE_RNE, inf, infs, 0, 0, 0, "inf <= -inf false"),
    ]
    # NaN ordering: -qNaN < -sNaN < -inf < ... < +inf < +sNaN < +qNaN.
    # Only meaningful where NaN encodings exist (W_MANT > 0).
    if fmt.W_MANT > 0:
        qnan = encode_nan(0, fmt)
        qnan_p = encode_nan(1, fmt)
        snan = encode_nan(1, fmt) & ~(1 << (fmt.W_MANT - 1))
        nq = qnan ^ (1 << (w - 1))
        ns = snan ^ (1 << (w - 1))
        v += [
            (OP_TOTALORDER, MODE_RNE, qnan, inf, 0, 0, 0, "+qNaN >= +inf"),
            (OP_TOTALORDER, MODE_RNE, inf, qnan, 0, 0, 1, "inf <= +qNaN"),
            (OP_TOTALORDER, MODE_RNE, nq, infs, 0, 0, 1, "-qNaN <= -inf"),
            (OP_TOTALORDER, MODE_RNE, infs, nq, 0, 0, 0, "-inf <= -qNaN false"),
            (OP_TOTALORDER, MODE_RNE, snan, qnan_p, 0, 0, 1, "+sNaN <= +qNaN"),
            (OP_TOTALORDER, MODE_RNE, nq, ns, 0, 0, 1, "-qNaN <= -sNaN"),
            (OP_TOTALORDER, MODE_RNE, qnan_p, qnan_p, 0, 0, 1, "qNaN <= itself"),
            (OP_TOTALORDER, MODE_RNE, nq, nq, 0, 0, 1, "-qNaN <= itself"),
            # sNaN never signals (5.10 is not a comparison).
            (OP_TOTALORDER, MODE_RNE, snan, m1, 0, 0, 0, "+sNaN >= 1 (no signal)"),
        ]
    return v


def _directed_rndint_vectors(fmt):
    """Hand-verified directed vectors for roundToIntegral (5.9).

    Tuples are (mode, rm, a, b, exp_y, exp_f, note); b is ignored, cmp = 0.
    roundToIntegral never signals inexact.
    """
    w = fmt.width
    neg = lambda x: x ^ (1 << (w - 1))
    m0 = fmt.W_MANT
    m1 = _norm1(fmt)
    m1s = neg(m1)
    m2 = encode_finite(0, fmt.bias + 1, 0, fmt)
    z = encode_zero(0, fmt)
    zs = encode_zero(1, fmt)
    inf = encode_inf(0, fmt)
    infs = encode_inf(1, fmt)
    inv = 1 << formats.FLAG_INVALID
    v = []

    # Infinity and zero are returned unchanged (zero keeps its sign).
    v += [
        (OP_RNDINT, MODE_RNE, inf, 0, inf, 0, "inf unchanged"),
        (OP_RNDINT, MODE_RNE, infs, 0, infs, 0, "-inf unchanged"),
        (OP_RNDINT, MODE_RNE, z, 0, z, 0, "+0 unchanged"),
        (OP_RNDINT, MODE_RNE, zs, 0, zs, 0, "-0 unchanged"),
        (OP_RNDINT, MODE_RNE, m1, 0, m1, 0, "1.0 integral unchanged"),
        (OP_RNDINT, MODE_RNE, m2, 0, m2, 0, "2.0 integral unchanged"),
        (OP_RNDINT, MODE_RNE, m1s, 0, m1s, 0, "-1.0 integral unchanged"),
    ]
    # Fractional values (no subnormals / mantissa for W_MANT = 0, so these are
    # guarded; the E8M0 equivalents follow below).
    if fmt.W_MANT > 0:
        half = encode_finite(0, fmt.bias - 1, 0, fmt)          # 0.5
        quarter = encode_finite(0, fmt.bias - 2, 0, fmt)       # 0.25
        one_half = encode_finite(0, fmt.bias, 1 << (m0 - 1), fmt)  # 1.5
        qnan_p = encode_nan(1, fmt)
        snan = encode_nan(1, fmt) & ~(1 << (m0 - 1))
        v += [
            # 0.5: the only tie among fractions below 1.
            (OP_RNDINT, MODE_RNE, half, 0, z, 0, "0.5 (RNE) -> +0"),
            (OP_RNDINT, MODE_RNA, half, 0, m1, 0, "0.5 (RNA) -> 1"),
            (OP_RNDINT, MODE_RZ,  half, 0, z, 0, "0.5 (RZ) -> +0"),
            (OP_RNDINT, MODE_RP,  half, 0, m1, 0, "0.5 (RP) -> 1"),
            (OP_RNDINT, MODE_RM,  half, 0, z, 0, "0.5 (RM) -> +0"),
            (OP_RNDINT, MODE_RNE, neg(half), 0, zs, 0, "-0.5 (RNE) -> -0"),
            (OP_RNDINT, MODE_RNA, neg(half), 0, m1s, 0, "-0.5 (RNA) -> -1"),
            (OP_RNDINT, MODE_RZ,  neg(half), 0, zs, 0, "-0.5 (RZ) -> -0"),
            (OP_RNDINT, MODE_RP,  neg(half), 0, zs, 0, "-0.5 (RP) -> -0"),
            (OP_RNDINT, MODE_RM,  neg(half), 0, m1s, 0, "-0.5 (RM) -> -1"),
            (OP_RNDINT, MODE_RNE, quarter, 0, z, 0, "0.25 (RNE) -> +0"),
            (OP_RNDINT, MODE_RNA, quarter, 0, z, 0, "0.25 (RNA) -> +0"),
            (OP_RNDINT, MODE_RZ,  quarter, 0, z, 0, "0.25 (RZ) -> +0"),
            (OP_RNDINT, MODE_RP,  quarter, 0, m1, 0, "0.25 (RP) -> 1"),
            (OP_RNDINT, MODE_RM,  quarter, 0, z, 0, "0.25 (RM) -> +0"),
            # 1.5 / 2.5 tie behavior.
            (OP_RNDINT, MODE_RNE, one_half, 0, m2, 0, "1.5 (RNE) -> 2"),
            (OP_RNDINT, MODE_RZ,  one_half, 0, m1, 0, "1.5 (RZ) -> 1"),
            (OP_RNDINT, MODE_RP,  one_half, 0, m2, 0, "1.5 (RP) -> 2"),
            (OP_RNDINT, MODE_RM,  one_half, 0, m1, 0, "1.5 (RM) -> 1"),
        ]
        if m0 >= 2:
            # 2.5 = 1.25 x 2^1: the 0.25 fraction is the (m0-2) mantissa bit.
            two_half = encode_finite(0, fmt.bias + 1, 1 << (m0 - 2), fmt)
            m3 = encode_finite(0, fmt.bias + 1, 1 << (m0 - 1), fmt)   # 3.0
            v += [
                (OP_RNDINT, MODE_RNE, two_half, 0, m2, 0, "2.5 (RNE) -> 2 (even)"),
                (OP_RNDINT, MODE_RNA, two_half, 0, m3, 0, "2.5 (RNA) -> 3"),
                (OP_RNDINT, MODE_RZ,  two_half, 0, m2, 0, "2.5 (RZ) -> 2"),
                (OP_RNDINT, MODE_RP,  two_half, 0, m3, 0, "2.5 (RP) -> 3"),
                (OP_RNDINT, MODE_RM,  two_half, 0, m2, 0, "2.5 (RM) -> 2"),
                (OP_RNDINT, MODE_RNE, neg(two_half), 0, neg(m2), 0, "-2.5 (RNE) -> -2"),
                (OP_RNDINT, MODE_RNA, neg(two_half), 0, neg(m3), 0, "-2.5 (RNA) -> -3"),
                (OP_RNDINT, MODE_RZ,  neg(two_half), 0, neg(m2), 0, "-2.5 (RZ) -> -2"),
                (OP_RNDINT, MODE_RP,  neg(two_half), 0, neg(m2), 0, "-2.5 (RP) -> -2"),
                (OP_RNDINT, MODE_RM,  neg(two_half), 0, neg(m3), 0, "-2.5 (RM) -> -3"),
            ]
        # NaN: sign and payload preserved, quiet bit forced (5.9).
        v += [
            (OP_RNDINT, MODE_RNE, qnan_p, 0, qnan_p, 0, "qNaN payload preserved"),
            (OP_RNDINT, MODE_RNE, neg(qnan_p), 0, neg(qnan_p), 0, "-qNaN sign preserved"),
            (OP_RNDINT, MODE_RNE, snan, 0, qnan_p, inv, "sNaN quieted, invalid"),
        ]
    # E8M0 (W_MANT = 0): powers of two; only 2^e for e < 0 need rounding.
    if fmt.W_MANT == 0:
        p05 = encode_finite(0, fmt.bias - 1, 0, fmt)   # 2^-1
        p025 = encode_finite(0, fmt.bias - 2, 0, fmt)  # 2^-2
        p1 = encode_finite(0, fmt.bias, 0, fmt)        # 1.0
        v += [
            (OP_RNDINT, MODE_RNE, p05, 0, z, 0, "e8m0: 0.5 (RNE) -> +0"),
            (OP_RNDINT, MODE_RNA, p05, 0, p1, 0, "e8m0: 0.5 (RNA) -> 1"),
            (OP_RNDINT, MODE_RZ,  p05, 0, z, 0, "e8m0: 0.5 (RZ) -> +0"),
            (OP_RNDINT, MODE_RP,  p05, 0, p1, 0, "e8m0: 0.5 (RP) -> 1"),
            (OP_RNDINT, MODE_RM,  p05, 0, z, 0, "e8m0: 0.5 (RM) -> +0"),
            (OP_RNDINT, MODE_RNE, neg(p05), 0, zs, 0, "e8m0: -0.5 (RNE) -> -0"),
            (OP_RNDINT, MODE_RNA, neg(p05), 0, neg(p1), 0, "e8m0: -0.5 (RNA) -> -1"),
            (OP_RNDINT, MODE_RP,  neg(p05), 0, zs, 0, "e8m0: -0.5 (RP) -> -0"),
            (OP_RNDINT, MODE_RM,  neg(p05), 0, neg(p1), 0, "e8m0: -0.5 (RM) -> -1"),
            (OP_RNDINT, MODE_RNE, p025, 0, z, 0, "e8m0: 0.25 (RNE) -> +0"),
            (OP_RNDINT, MODE_RP,  p025, 0, p1, 0, "e8m0: 0.25 (RP) -> 1"),
            (OP_RNDINT, MODE_RNE, neg(p025), 0, zs, 0, "e8m0: -0.25 (RNE) -> -0"),
            (OP_RNDINT, MODE_RM,  neg(p025), 0, neg(p1), 0, "e8m0: -0.25 (RM) -> -1"),
            (OP_RNDINT, MODE_RNE, p1, 0, p1, 0, "e8m0: 1.0 integral unchanged"),
        ]
    return v


def _norm1(fmt):
    return encode_finite(0, fmt.bias, 0, fmt)


@cocotb.test()
async def test_directed(dut):
    for mode, rm, a, b, exp_y, exp_f, note in _directed_vectors(FMT):
        await check(dut, mode, rm, a, b, exp_y, exp_f, f"directed: {note}")


@cocotb.test()
async def test_directed_mul(dut):
    for mode, rm, a, b, exp_y, exp_f, note in _directed_mul_vectors(FMT):
        await check(dut, mode, rm, a, b, exp_y, exp_f, f"directed mul: {note}")


@cocotb.test()
async def test_directed_div(dut):
    for mode, rm, a, b, exp_y, exp_f, note in _directed_div_vectors(FMT):
        await check(dut, mode, rm, a, b, exp_y, exp_f, f"directed div: {note}")


@cocotb.test()
async def test_directed_sqrt(dut):
    for mode, rm, a, b, exp_y, exp_f, note in _directed_sqrt_vectors(FMT):
        await check(dut, mode, rm, a, b, exp_y, exp_f, f"directed sqrt: {note}")


@cocotb.test()
async def test_directed_fma(dut):
    for mode, rm, a, b, c, exp_y, exp_f, note in _directed_fma_vectors(FMT):
        await check(dut, mode, rm, a, b, exp_y, exp_f, f"directed fma: {note}", c=c)


@cocotb.test()
async def test_directed_minmax(dut):
    for mode, rm, a, b, exp_y, exp_f, note in _directed_minmax_vectors(FMT):
        await check(dut, mode, rm, a, b, exp_y, exp_f, f"directed minmax: {note}")


@cocotb.test()
async def test_directed_cmp(dut):
    for mode, rm, a, b, exp_y, exp_f, exp_c, note in _directed_cmp_vectors(FMT):
        await check(dut, mode, rm, a, b, exp_y, exp_f, f"directed cmp: {note}", exp_cmp=exp_c)


@cocotb.test()
async def test_directed_totalorder(dut):
    for mode, rm, a, b, exp_y, exp_f, exp_c, note in _directed_totalorder_vectors(FMT):
        await check(dut, mode, rm, a, b, exp_y, exp_f, f"directed totalorder: {note}",
                    exp_cmp=exp_c)


@cocotb.test()
async def test_directed_rndint(dut):
    for mode, rm, a, b, exp_y, exp_f, note in _directed_rndint_vectors(FMT):
        await check(dut, mode, rm, a, b, exp_y, exp_f, f"directed rndint: {note}")


@cocotb.test()
async def test_random_mixed(dut):
    rng = random.Random(SEED)
    for i in range(ITERS):
        a, b = gen.pair_stream(rng, FMT, 1)[0]
        mode = rng.randrange(11)
        rm = rng.randrange(5)
        exp_c = 0
        if mode == OP_MUL:
            exp_y, exp_f = ops.fp_mul(a, b, rm, FMT)
        elif mode == OP_DIV:
            exp_y, exp_f = ops.fp_div(a, b, rm, FMT)
        elif mode == OP_SQRT:
            exp_y, exp_f = ops.fp_sqrt(a, rm, FMT)
        elif mode == OP_FMA:
            c = gen.operand(rng, FMT)
            exp_y, exp_f = ops.fp_fma(a, b, c, rm, FMT)
        elif mode == OP_MIN:
            exp_y, exp_f = ops.fp_min(a, b, FMT)
        elif mode == OP_MAX:
            exp_y, exp_f = ops.fp_max(a, b, FMT)
        elif mode == OP_CMP:
            exp_y, exp_c, exp_f = ops.fp_cmp(a, b, FMT)
        elif mode == OP_RNDINT:
            exp_y, exp_f = ops.fp_roundint(a, rm, FMT)
        elif mode == OP_TOTALORDER:
            exp_y, exp_c, exp_f = ops.fp_totalorder(a, b, FMT)
        else:
            exp_y, exp_f = ops.fp_add(a, b, rm, FMT, sub=(mode == OP_SUB))
        await check(dut, mode, rm, a, b, exp_y, exp_f, f"random[{i}]",
                    c=c if mode == OP_FMA else 0, exp_cmp=exp_c)


@cocotb.test()
async def test_mul_random(dut):
    rng = random.Random(SEED ^ 0x51CE)
    for i in range(ITERS):
        a, b = gen.pair_stream(rng, FMT, 1)[0]
        rm = rng.randrange(5)
        exp_y, exp_f = ops.fp_mul(a, b, rm, FMT)
        await check(dut, OP_MUL, rm, a, b, exp_y, exp_f, f"mul[{i}]")


@cocotb.test()
async def test_div_random(dut):
    rng = random.Random(SEED ^ 0xD1AB0)
    for i in range(ITERS):
        a, b = gen.pair_stream(rng, FMT, 1)[0]
        rm = rng.randrange(5)
        exp_y, exp_f = ops.fp_div(a, b, rm, FMT)
        await check(dut, OP_DIV, rm, a, b, exp_y, exp_f, f"div[{i}]")


@cocotb.test()
async def test_sqrt_random(dut):
    rng = random.Random(SEED ^ 0x5A27)
    for i in range(ITERS):
        # b is driven with a random value to confirm sqrt ignores it.
        a, b = gen.pair(rng, FMT, rng.choice(["sqrt", "independent", "boundary"]))
        rm = rng.randrange(5)
        exp_y, exp_f = ops.fp_sqrt(a, rm, FMT)
        await check(dut, OP_SQRT, rm, a, b, exp_y, exp_f, f"sqrt[{i}]")


@cocotb.test()
async def test_fma_random(dut):
    rng = random.Random(SEED ^ 0xF7A)
    for i in range(ITERS):
        a, b = gen.pair_stream(rng, FMT, 1)[0]
        c = gen.operand(rng, FMT)
        rm = rng.randrange(5)
        exp_y, exp_f = ops.fp_fma(a, b, c, rm, FMT)
        await check(dut, OP_FMA, rm, a, b, exp_y, exp_f, f"fma[{i}]", c=c)


@cocotb.test()
async def test_minmax_random(dut):
    rng = random.Random(SEED ^ 0x00AA)
    for i in range(ITERS):
        a, b = gen.pair_stream(rng, FMT, 1)[0]
        mode = rng.choice([OP_MIN, OP_MAX])
        exp_y, exp_f = ops.fp_min(a, b, FMT) if mode == OP_MIN else ops.fp_max(a, b, FMT)
        await check(dut, mode, MODE_RNE, a, b, exp_y, exp_f, f"mm[{i}]")


@cocotb.test()
async def test_cmp_random(dut):
    rng = random.Random(SEED ^ 0xC0CC)
    for i in range(ITERS):
        a, b = gen.pair_stream(rng, FMT, 1)[0]
        exp_y, exp_c, exp_f = ops.fp_cmp(a, b, FMT)
        await check(dut, OP_CMP, MODE_RNE, a, b, exp_y, exp_f, f"cmp[{i}]", exp_cmp=exp_c)


@cocotb.test()
async def test_totalorder_random(dut):
    rng = random.Random(SEED ^ 0x70A1)
    for i in range(ITERS):
        a, b = gen.pair_stream(rng, FMT, 1)[0]
        exp_y, exp_c, exp_f = ops.fp_totalorder(a, b, FMT)
        await check(dut, OP_TOTALORDER, MODE_RNE, a, b, exp_y, exp_f, f"totalorder[{i}]",
                    exp_cmp=exp_c)


@cocotb.test()
async def test_rndint_random(dut):
    rng = random.Random(SEED ^ 0x81D1)
    for i in range(ITERS):
        a, _b = gen.pair(rng, FMT, "independent")
        rm = rng.randrange(5)
        exp_y, exp_f = ops.fp_roundint(a, rm, FMT)
        await check(dut, OP_RNDINT, rm, a, _b, exp_y, exp_f, f"rndint[{i}]")


@cocotb.test()
async def test_cancellation_stress(dut):
    rng = random.Random(SEED ^ 0xC0FFEE)
    for i in range(ITERS // 2):
        style = rng.choice(["same", "opposite", "near", "same_exp"])
        a, b = gen.pair(rng, FMT, style)
        mode = rng.randrange(2)
        rm = rng.randrange(5)
        exp_y, exp_f = ops.fp_add(a, b, rm, FMT, sub=(mode == OP_SUB))
        await check(dut, mode, rm, a, b, exp_y, exp_f, f"cancel[{i}]")


@cocotb.test()
async def test_boundary_stress(dut):
    rng = random.Random(SEED ^ 0xB0BA)
    for i in range(ITERS // 2):
        if i % 50 == 0:
            dut._log.info("boundary iteration %d", i)
        a, b = gen.pair(rng, FMT, "boundary")
        mode = rng.randrange(2)
        rm = rng.randrange(5)
        exp_y, exp_f = ops.fp_add(a, b, rm, FMT, sub=(mode == OP_SUB))
        await check(dut, mode, rm, a, b, exp_y, exp_f, f"boundary[{i}]")
