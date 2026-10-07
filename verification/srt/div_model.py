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

def run(Num, Den, S_W):
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

if __name__ == "__main__":
    rng = random.Random(1234)
    grand = 0
    # (a) random
    for S_W in (4, 5, 8, 9, 10, 11, 13, 16, 24, 25, 32, 40, 53, 54):
        bad = 0
        for _ in range(3000):
            Num = rng.randrange(1 << (S_W - 1), 1 << S_W)
            Den = rng.randrange(1 << (S_W - 1), 1 << S_W)
            q, s, err = run(Num, Den, S_W)
            tq, tr = divmod(Num << (S_W + 2), Den)
            if err or q != tq or s != (tr != 0):
                bad += 1
        print(f"random S_W={S_W}: bad={bad}")
        grand += bad
    # (b) exact divisions: Num = k*Den
    for S_W in (4, 8, 16, 24, 53):
        lo, hi = 1 << (S_W - 1), 1 << S_W
        bad = 0
        for Den in range(lo, min(hi, lo + 2000)):
            for k in range(1, 3):
                Num = k * Den
                if not (lo <= Num < hi):
                    continue
                q, s, err = run(Num, Den, S_W)
                tq, tr = divmod(Num << (S_W + 2), Den)
                if err or q != tq or s != (tr != 0):
                    bad += 1
                    if bad < 3:
                        print("EXACT FAIL", S_W, hex(Num), hex(Den), (q, s), tq, tr != 0, err)
        print(f"exact S_W={S_W}: bad={bad}")
        grand += bad
    # (c) near-exact: Num = k*Den +/- 1
    for S_W in (8, 16, 24, 53):
        lo, hi = 1 << (S_W - 1), 1 << S_W
        bad = 0
        for Den in range(lo, min(hi, lo + 2000)):
            for k in range(1, 3):
                for off in (-1, 0, 1):
                    Num = k * Den + off
                    if not (lo <= Num < hi):
                        continue
                    q, s, err = run(Num, Den, S_W)
                    tq, tr = divmod(Num << (S_W + 2), Den)
                    if err or q != tq or s != (tr != 0):
                        bad += 1
                        if bad < 3:
                            print("NEAR FAIL", S_W, hex(Num), hex(Den), (q, s), tq, tr != 0, err)
        print(f"near S_W={S_W}: bad={bad}")
        grand += bad
    print("TOTAL", grand, "PASS" if grand == 0 else "FAIL")
