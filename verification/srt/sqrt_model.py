#!/usr/bin/env python3
# Copyright 2026 Jesse Smedberg
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
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

# ---------------------------------------------------------------------------
# RTL-shaped model of rtl/jsm_fp_sqrt_srt.sv: the same digit loop with the RTL's
# truncated carry-save estimate (`est_pe`) and threshold selection
# (`thr_digit`). csw=None runs on exact integers; csw=N keeps S and C modulo
# 2^N with no carry-propagate fold (what the RTL does, CSW = 2*NDIG + 5,
# EW = 12).

import random


def sx(v, w):
    v &= (1 << w) - 1
    return v - (1 << w) if v >> (w - 1) else v

def sh_ar(v, sh):           # 16'(v >>> sh) / 16'(v <<< -sh), v exact signed
    return sx(v >> sh if sh >= 0 else v << -sh, 16)

def thr_digit(q, pe, sh):
    qs = sh_ar(q, sh)
    # the RTL keeps qs in 6 bits and compares at 13 bits: check the ranges
    assert 0 <= qs < 64 and -4096 <= pe < 4096, (qs, pe)
    q4 = sx(qs << 2, 16)
    ts = [-7*q4, -5*q4, -3*q4, -q4, q4, 3*q4, 5*q4, 7*q4]
    ts = [sx(t, 16) for t in ts]
    return sum(pe >= t for t in ts) - 4

def run_rtl(X, S_W, csw=None, ew=16):
    """RTL-shaped jsm_fp_sqrt_srt digit loop. csw=None: exact integers (= the
    folded RTL); csw=N: S, C modulo 2^N with no fold, estimate window ew bits."""
    pad = 2 if S_W % 2 == 0 else 0
    RW = 2 * S_W + 6
    RE = RW + pad
    ndig = (RE - 4) // 4
    Xp = X << pad
    M = (1 << csw) - 1 if csw else None
    v = (Xp >> (RE - 4)) & 0xF
    d0 = 3 if v >= 9 else 2
    q, qm = d0, d0 - 1
    S, C = v - d0 * d0, 0
    for t in range(ndig):
        bits = (Xp >> (RE - 8 - 4 * t)) & 0xF
        if t == 0:
            d = first_digit(q, (S + C) & 7, bits)
        else:
            sh = 2 * t - 6
            if csw is None:
                pe = sx(sh_ar(S, sh) + sh_ar(C, sh) + sh_ar(bits, 2 * t - 2), 16)
            else:
                win = lambda z: (z >> sh) if sh >= 0 else (z << -sh)
                bsh = 2 * t - 2
                pe = sx(win(S) + win(C) + ((bits >> bsh) if bsh >= 0 else bits << -bsh), ew)
            d = thr_digit(q, pe, 2 * t - 2)
        term = d * (8 * q) + d * d
        a, b, c = S << 4, C << 4, bits - term
        if M is not None:
            a, b, c = a & M, b & M, c & M
        S = a ^ b ^ c
        C = ((a & b) | (a & c) | (b & c)) << 1
        if M is not None:
            S &= M; C &= M
        if d >= 0:
            q, qm = 4 * q + d, 4 * qm + d + 3
        else:
            q, qm = 4 * qm + d + 4, 4 * qm + d + 3
    r = (S + C) if csw is None else sx(S + C, csw)
    qf = q
    sticky = r != 0
    if pad: sticky = sticky or (q & 1)
    if r < 0:
        qf = qm
        rc = r + 2 * qm - 1
        sticky = rc != 0
        if pad: sticky = sticky or (qm & 1)
    placed = qf >> 1 if pad else qf
    return placed, bool(sticky)

def check(X, S_W, **kw):
    p, s = run_rtl(X, S_W, **kw)
    t = isqrt(X)
    return p == t and s == (X != t * t)

def radicands(S_W, exhaustive_limit=12, n=3000, rng=None):
    rng = rng or random.Random(5)
    if S_W <= exhaustive_limit:
        for m in range(1 << (S_W - 1), 1 << S_W):
            for par in (0, 1):
                yield m << (S_W + 5 + par)
    else:
        for _ in range(n):
            m = rng.randrange(1 << (S_W - 1), 1 << S_W)
            yield m << (S_W + 5 + rng.randrange(2))

if __name__ == "__main__":
    import random
    rng = random.Random(77)
    grand = 0
    # RTL-shaped model, exact and fixed-width carry-save (CSW = 2*NDIG + 5)
    for S_W in (2, 3, 4, 5, 8, 9, 10, 11, 12, 16, 24, 25, 32, 40, 53, 54):
        ndig = (2 * S_W + 6 + (2 if S_W % 2 == 0 else 0) - 4) // 4
        bad = 0
        for X in radicands(S_W):
            bad += not check(X, S_W)
            bad += not check(X, S_W, csw=2 * ndig + 5, ew=12)
        print(f"[rtl exact+fixed] S_W={S_W}: bad={bad}")
        grand += bad
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
