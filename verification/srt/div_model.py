#!/usr/bin/env python3
"""Final validated radix-4 SRT divider model (RTL-shaped).

ND=5 divisor cells (1/32), estimate k = floor(64R) (1/16), one-sided +1
padding, exact carry-save, on-the-fly Q/QM, final sign correction.
"""

from fractions import Fraction as F
import random

def ceil_f(x): return -((-x.numerator) // x.denominator)
def floor_f(x): return x.numerator // x.denominator

DSTEP = F(1, 32)

def gen_table():
    tab = {}
    for d in range(16):
        D_lo = F(1, 2) + d * DSTEP
        D_hi = D_lo + DSTEP
        for k in range(-64, 65):
            y, yhi = F(k, 16), F(k + 2, 16)
            c = [y / D_lo, y / D_hi, yhi / D_lo, yhi / D_hi]
            sup = min(max(c), F(8, 3))
            inf = max(min(c), F(-8, 3))
            qmin = max(ceil_f(sup - F(2, 3)), -2)
            qmax = min(floor_f(inf + F(2, 3)), 2)
            if qmin <= qmax:
                qmid = (qmin + qmax) / 2
                tab[(k, d)] = qmin if abs(qmin - qmid) <= abs(qmax - qmid) else qmax
    for d in range(16):
        for k in range(-64, 65):
            if (k, d) not in tab:
                ks = sorted((kk for kk in range(-64, 65) if (kk, d) in tab),
                            key=lambda kk: abs(kk - k))
                if ks:
                    tab[(k, d)] = tab[(ks[0], d)]
    return tab

TAB = gen_table()

def _sx(v, w):
    """two's-complement value of the low w bits of v"""
    v &= (1 << w) - 1
    return v - (1 << w) if v >> (w - 1) else v


def run(Num, Den, S_W, csw=None):
    """csw=None: exact (unbounded) carry-save integers.
    csw=N: RTL-shaped fixed-width carry-save, S and C kept modulo 2^N with no
    carry-propagate fold between digits; the estimate is the 8-bit wrapped
    sum of the top windows and the remainder is folded once, at the end."""
    if csw is not None:
        return run_mod(Num, Den, S_W, csw)
    target = S_W + 2
    n = (target // 2 + 1) if target % 2 == 0 else ((target + 1) // 2 + 1)
    SH = S_W - 4
    S, C = Num, 0
    Q, QM = 0, -1
    for i in range(n):
        k_est = (S >> SH) + (C >> SH)
        dcell = int((F(Den, 1 << S_W) - F(1, 2)) / DSTEP)
        dcell = max(0, min(15, dcell))
        d = TAB.get((max(-64, min(64, k_est)), dcell))
        if d is None:
            return None, None, ("nodigit", i, k_est, dcell)
        a, b, c = S << 2, C << 2, -4 * d * Den
        S, C = (a ^ b ^ c), (((a & b) | (a & c) | (b & c)) << 1)
        assert S + C == a + b + c
        if d >= 0:
            Q, QM = 4 * Q + d, 4 * QM + d + 3
        else:
            Q, QM = 4 * QM + d + 4, 4 * QM + d + 3
    u = S + C
    if u < 0:
        Q = QM
        u += 4 * Den
    if target % 2 == 0:
        return Q, (u != 0), None
    return Q >> 1, ((u != 0) or bool(Q & 1)), None

def run_mod(Num, Den, S_W, CSW):
    target = S_W + 2
    n = (target // 2 + 1) if target % 2 == 0 else ((target + 1) // 2 + 1)
    SH = S_W - 4
    M = (1 << CSW) - 1
    win = lambda v: (v >> SH) if SH >= 0 else (v << -SH)
    S, C = Num & M, 0
    Q, QM = 0, -1
    dcell = max(0, min(15, int((F(Den, 1 << S_W) - F(1, 2)) / DSTEP)))
    for i in range(n):
        k_est = _sx((win(S) & 0xFF) + (win(C) & 0xFF), 8)
        d = TAB.get((max(-64, min(64, k_est)), dcell))
        if d is None:
            return None, None, ("nodigit", i, k_est, dcell)
        a, b, c = (S << 2) & M, (C << 2) & M, (-4 * d * Den) & M
        S, C = (a ^ b ^ c) & M, (((a & b) | (a & c) | (b & c)) << 1) & M
        if d >= 0:
            Q, QM = 4 * Q + d, 4 * QM + d + 3
        else:
            Q, QM = 4 * QM + d + 4, 4 * QM + d + 3
    u = _sx(S + C, CSW)
    if u < 0:
        Q = QM
        u += 4 * Den
    if target % 2 == 0:
        return Q, (u != 0), None
    return Q >> 1, ((u != 0) or bool(Q & 1)), None


# fixed carry-save width used by rtl/fp_div_srt.sv (CSW = S_W + CSW_MARGIN)
CSW_MARGIN = 4


def check(Num, Den, S_W, csw=None):
    q, s, err = run(Num, Den, S_W, csw)
    tq, tr = divmod(Num << (S_W + 2), Den)
    return not err and q == tq and s == (tr != 0)


if __name__ == "__main__":
    rng = random.Random(1234)
    grand = 0
    for mode in ("exact", "fixed"):
        cs = (lambda S_W: None) if mode == "exact" else (lambda S_W: S_W + CSW_MARGIN)
        # (a) random
        for S_W in (4, 5, 8, 9, 10, 11, 13, 16, 24, 25, 32, 40, 53, 54):
            bad = 0
            for _ in range(3000):
                Num = rng.randrange(1 << (S_W - 1), 1 << S_W)
                Den = rng.randrange(1 << (S_W - 1), 1 << S_W)
                bad += not check(Num, Den, S_W, cs(S_W))
            print(f"[{mode}] random S_W={S_W}: bad={bad}")
            grand += bad
        # (b) exact divisions Num = k*Den and (c) near-exact k*Den +/- 1
        for S_W in (4, 8, 16, 24, 53):
            lo, hi = 1 << (S_W - 1), 1 << S_W
            bad = 0
            for Den in range(lo, min(hi, lo + 2000)):
                for k in range(1, 3):
                    for off in (-1, 0, 1):
                        Num = k * Den + off
                        if lo <= Num < hi and not check(Num, Den, S_W, cs(S_W)):
                            bad += 1
                            if bad < 3:
                                print("FAIL", mode, S_W, hex(Num), hex(Den))
            print(f"[{mode}] exact/near S_W={S_W}: bad={bad}")
            grand += bad
    # (d) fixed-width carry-save, exhaustive for the narrow significands
    # (every 8-bit-format significand width and binary16's S_W = 11)
    for S_W in range(3, 12):
        lo, hi = 1 << (S_W - 1), 1 << S_W
        bad = sum(not check(N, D, S_W, S_W + CSW_MARGIN)
                  for N in range(lo, hi) for D in range(lo, hi))
        print(f"[fixed] exhaustive S_W={S_W}: bad={bad}")
        grand += bad
    print("TOTAL", grand, "PASS" if grand == 0 else "FAIL")
