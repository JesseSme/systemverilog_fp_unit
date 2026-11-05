# Copyright 2026 Jesse Smedberg
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""cocotb tests for rtl/jsm_fp_exp_seq.sv (sequential fp32 exp).

jsm_fp_exp_seq computes y = exp(clamp(x, -16, 16)) by range reduction x/32, a
degree-6 Horner polynomial and five squarings on two jsm_fp_unit instances (RNE).
The reference is math.exp in double precision rounded to binary32; the
result must lie within the per-|x|-band ULP bound ULP_BOUNDS (measured, see
docs/user_guide.md).

Run: uv run python tests/run_regression.py --top jsm_fp_exp_seq --tests test_fp_exp_seq --width 8 23
"""

from __future__ import annotations

import math
import os
import random
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cocotb  # noqa: E402
from cocotb.clock import Clock  # noqa: E402
from cocotb.triggers import RisingEdge  # noqa: E402

ITERS = int(os.environ.get("FP_ITERS", "100")) * 20
SEED = int(os.environ.get("FP_SEED", "0x5eed"), 0)

# Error bounds in units in the last place of the correctly rounded result,
# per |x| band (measured maxima over 5 seeds x 2000 vectors, rounded up).
# The degree-6 polynomial on r = x/32 has a truncation error ~r^7/5040 and
# the five squarings multiply the relative error of exp(r) by 32, so the
# error is ~40 ulp (~5e-6 relative) for |x| <= 8 and grows to ~1.3k ulp
# (~1.5e-4 relative) close to |x| = 16. See the jsm_fp_exp_seq header.
ULP_BOUNDS = ((1.0, 48), (4.0, 64), (8.0, 64), (16.0, 1536))


def ulp_bound(x: float) -> int:
    ax = min(abs(x), 16.0)
    for lim, bound in ULP_BOUNDS:
        if ax <= lim:
            return bound
    return ULP_BOUNDS[-1][1]


def f2b(v: float) -> int:
    return struct.unpack("<I", struct.pack("<f", v))[0]


def b2f(b: int) -> float:
    return struct.unpack("<f", struct.pack("<I", b & 0xFFFFFFFF))[0]


def ordered(b: int) -> int:
    """Map a binary32 encoding to an integer that is monotone in its value."""
    return -(b & 0x7FFFFFFF) if b & 0x80000000 else b


def ulp_diff(a: int, b: int) -> int:
    return abs(ordered(a) - ordered(b))


def reference(x_bits: int) -> int:
    x = b2f(x_bits)
    xc = max(-16.0, min(16.0, x))
    return f2b(math.exp(xc))


async def reset(dut):
    dut.rst_n.value = 0
    dut.start.value = 0
    dut.x.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_exp(dut, x_bits: int) -> tuple[int, int]:
    """Start one exp; returns (y bits, cycles from start to done)."""
    dut.x.value = x_bits
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    cycles = 0
    while True:
        await RisingEdge(dut.clk)
        cycles += 1
        if int(dut.done.value):
            break
        assert cycles < 2000, "jsm_fp_exp_seq: done never asserted"
    # done is registered with y; both valid in this cycle. done must be a
    # single-cycle pulse.
    y = int(dut.y.value)
    await RisingEdge(dut.clk)
    assert not int(dut.done.value), "done held for more than one cycle"
    return y, cycles


def _directed() -> list[int]:
    vals = [0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 2.0, -2.0, 1e-3, -1e-3, 1e-20, -1e-20,
            15.999, -15.999, 16.0, -16.0, 10.0, -10.0, math.log(2.0), 0.1, -0.1]
    bits = [f2b(v) for v in vals]
    bits += [0x00000001, 0x80000001]  # +-min subnormal
    return bits


@cocotb.test()
async def test_exp_accuracy(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(SEED)
    vec = _directed() + [f2b(rng.uniform(-16.0, 16.0)) for _ in range(ITERS)]
    worst = {lim: (0, 0, 0, 0) for lim, _ in ULP_BOUNDS}
    lat = None
    fails = []
    for xb in vec:
        y, cycles = await run_exp(dut, xb)
        if lat is None:
            lat = cycles
        assert cycles == lat, f"latency varies: {cycles} vs {lat}"
        want = reference(xb)
        d = ulp_diff(y, want)
        x = b2f(xb)
        band = next(lim for lim, _ in ULP_BOUNDS if min(abs(x), 16.0) <= lim)
        if d > worst[band][0]:
            worst[band] = (d, xb, y, want)
        if d > ulp_bound(x):
            fails.append((x, d))
    for lim, (d, xb, y, want) in worst.items():
        dut._log.info("|x| <= %4.1f: max error %4d ulp at x=%r (got %r, want %r)",
                      lim, d, b2f(xb), b2f(y), b2f(want))
    dut._log.info("latency %d cycles", lat)
    assert not fails, f"{len(fails)} results exceed the ULP bound, e.g. {fails[:3]}"


@cocotb.test()
async def test_exp_clamp_and_specials(dut):
    """Documented behaviour: |x| > 16 (including +-Inf) clamps to +-16; a NaN
    input compares as a huge magnitude and clamps to +-16 as well."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset(dut)
    e16 = await run_exp(dut, f2b(16.0))
    em16 = await run_exp(dut, f2b(-16.0))
    for xb, want in ((f2b(16.5), e16[0]), (f2b(100.0), e16[0]), (0x7F800000, e16[0]),
                     (f2b(-16.5), em16[0]), (f2b(-1e30), em16[0]), (0xFF800000, em16[0]),
                     (0x7FC00000, e16[0]), (0xFFC00001, em16[0])):
        y, _ = await run_exp(dut, xb)
        assert y == want, f"x={xb:08x}: got {y:08x}, want {want:08x} (clamp)"
