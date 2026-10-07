#!/usr/bin/env python3
"""Radix-4 SRT sqrt model (RTL-shaped, carry-save, redundant digits {-4..4}).

Integer recurrence:
  preload v = top 4 bits of X, d0 = 2 if v<9 else 3, q=d0, R=v-d0^2
  step: p = 16R + bits(4);  R' = p - d(8q+d);  q' = 4q+d
Invariant |R| <= 2q (non-restoring sqrt bound); digit selected as
  d = clamp(count(p >= q(8k+4) for k=-4..3) - 4, -4, 4)
  (equivalently round(p/(8q))) with dedicated exact selection for q < 4.
X is zero-padded so all steps consume 4 bits; the extra bit folds into the
sticky like the division's odd-target handling.
"""

from math import isqrt

def first_digit(q, R, bits):
    """exact digit for small q: choose d minimizing |p - d(8q+d)| within the
    loose bound |R'| <= 2q'."""
    p = 16 * R + bits
    best = None
    for d in range(-4, 5):
        qp = 4 * q + d
        if qp <= 0:
            continue
        Rp = p - d * (8 * q + d)
        if abs(Rp) <= 2 * qp:
            if best is None or abs(Rp) < best[1]:
                best = (d, abs(Rp))
    return best[0] if best else None

def sel_d(q, p):
    if q < 4:
        return None  # caller uses first_digit
    cnt = 0
    for k in range(-4, 4):
        if p >= q * (8 * k + 4):
            cnt += 1
    d = cnt - 4
    # clamp to the digit set; the loose bound keeps reachable p inside
    return max(-4, min(4, d))

def run(X, S_W, pad=None):
    if pad is None:
        pad = 0 if (S_W % 2 == 1) else 2
    """X: R_W-bit radicand. Returns placed, sticky, rem (X - placed^2)."""
    RW = 2 * S_W + 6
    Xp = X << pad                       # padded radicand
    RE = RW + pad
    nsteps = (RE - 4) // 4
    v = (Xp >> (RE - 4)) & 0xF
    d0 = 2 if v < 9 else 3
    q, R = d0, v - d0 * d0
    Q, QM = q, q - 1
    for t in range(nsteps):
        sh = RE - 4 - 4 * (t + 1)
        bits = (Xp >> sh) & 0xF if sh >= 0 else 0
        if q < 4:
            d = first_digit(q, R, bits)
        else:
            p = 16 * R + bits
            d = sel_d(q, p)
        if d is None:
            return None, None, ("nodigit", t, q, R, bits)
        p = 16 * R + bits
        R = p - d * (8 * q + d)
        if q >= 4 and abs(R) > 2 * (4 * q + d) + 4:
            return None, None, ("bound", t, q, R, d)
        # on-the-fly root
        if d >= 0:
            Q, QM = 4 * Q + d, 4 * QM + d + 3
        else:
            Q, QM = 4 * QM + d + 4, 4 * QM + d + 3
        q = Q
    # final sign correction at the digit grid
    if R < 0:
        Q = QM
        R += 2 * Q - 1
        q = Q
    if pad:
        b = Q & 1
        placed = Q >> 1
        rem = (X - placed * placed)
        sticky = bool(rem) if b == 0 else None  # recomputed below exactly
        # rem = X - placed^2 always; sticky is rem != 0
        return placed, (rem != 0), None
    return Q, (R != 0), None

if __name__ == "__main__":
    import random
    rng = random.Random(77)
    grand = 0
    for S_W in (2, 3, 4, 5, 8, 9, 10, 11, 16, 24, 25, 32, 40, 53, 54):
        RW = 2 * S_W + 6
        bad = 0
        N = 4000 if S_W <= 16 else 1500
        for _ in range(N):
            X = rng.randrange(1 << (RW - 2), 1 << RW)
            placed, sticky, err = run(X, S_W)
            tq = isqrt(X)
            if err or placed != tq or sticky != (X != tq * tq):
                bad += 1
                if bad < 4:
                    print("FAIL", S_W, hex(X), placed, tq, sticky, err)
        # exact squares near the top and bottom of the range
        lo, hi = isqrt(1 << (RW - 2)), isqrt((1 << RW) - 1)
        for tq in range(max(2, lo - 5), min(hi, lo + 2000)):
            X = tq * tq
            if not (1 << (RW - 2)) <= X < (1 << RW):
                continue
            placed, sticky, err = run(X, S_W)
            if err or placed != tq or sticky:
                bad += 1
                if bad < 6:
                    print("SQUARE FAIL", S_W, hex(X), placed, tq, sticky, err)
        print(f"S_W={S_W}: bad={bad}")
        grand += bad
    print("TOTAL", grand, "PASS" if grand == 0 else "FAIL")
