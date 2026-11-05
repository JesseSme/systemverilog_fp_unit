# Copyright 2026 Jesse Smedberg
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""cocotb tests for the AXI4-Stream wrapper (rtl/jsm_fp_unit_axis.sv).

Run via tests/run_regression.py --top jsm_fp_unit_axis --tests test_fp_unit_axis
(or --top jsm_fp_unit_axis_top for the Verilog-2001 top).

Requests are driven and results sampled at the falling clock edge, so the
valid/ready values seen there are the ones the next rising edge uses. Every
result is checked against the bit-exact oracle in request order, together
with the tuser/tlast passed through with it.
"""

import os
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from reference import gen, ops
from reference.formats import NUM_OPS, OP_ADD, BinFormat

W_EXP = int(os.environ.get("FP_W_EXP", "8"))
W_MANT = int(os.environ.get("FP_W_MANT", "23"))
ITERS = int(os.environ.get("FP_ITERS", "100"))
SEED = int(os.environ.get("FP_SEED", "0x5eed"), 0)

FMT = BinFormat(W_EXP, W_MANT)
W = 1 + W_EXP + W_MANT
OPB = ((W + 7) // 8) * 8


def pack_req(op, rm, a, b, c):
    return a | (b << OPB) | (c << (2 * OPB)) | ((op & 0xF) << (3 * OPB)) | ((rm & 0x7) << (3 * OPB + 4))


def unpack_res(v):
    y = v & ((1 << OPB) - 1)
    flags = (v >> OPB) & 0x1F
    cmp = (v >> (OPB + 5)) & 0x3
    return y, flags, cmp


def requests(dut, rng, n, ops_list=None):
    user_w = len(dut.s_axis_tuser)
    out = []
    for _ in range(n):
        a, b = gen.pair_stream(rng, FMT, 1)[0]
        op = rng.choice(ops_list) if ops_list else rng.randrange(NUM_OPS)
        rm = rng.randrange(5)
        c = gen.operand(rng, FMT)
        y, flags, cmp = ops.dispatch(op, a, b, c, rm, FMT)
        out.append(dict(data=pack_req(op, rm, a, b, c), user=rng.randrange(1 << user_w),
                        last=rng.randrange(2), exp=(y, flags, cmp), op=op, rm=rm, a=a, b=b))
    return out


async def reset(dut):
    cocotb.start_soon(Clock(dut.aclk, 10, units="ns").start())
    dut.aresetn.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tdata.value = 0
    dut.s_axis_tuser.value = 0
    dut.s_axis_tlast.value = 0
    dut.m_axis_tready.value = 0
    for _ in range(3):
        await RisingEdge(dut.aclk)
    await FallingEdge(dut.aclk)
    dut.aresetn.value = 1


async def run_stream(dut, reqs, p_gap, p_ready, stall_cycles=0, max_cycles=None):
    """Drive reqs, collect results; returns (results, cycles, idle_ready_low)."""
    pending = None
    accepted = False
    queue = list(reqs)
    results = []
    cycles = 0
    tready_low_with_data = 0
    limit = max_cycles or (len(reqs) * 200 + 2000)
    while len(results) < len(reqs):
        await FallingEdge(dut.aclk)
        cycles += 1
        assert cycles < limit, f"timeout: {len(results)}/{len(reqs)} results after {cycles} cycles"
        # request side
        if pending is not None and accepted:
            pending = None
        if pending is None and queue and random.random() >= p_gap:
            pending = queue.pop(0)
            dut.s_axis_tdata.value = pending["data"]
            dut.s_axis_tuser.value = pending["user"]
            dut.s_axis_tlast.value = pending["last"]
            dut.s_axis_tvalid.value = 1
        elif pending is None:
            dut.s_axis_tvalid.value = 0
        ready_in = int(dut.s_axis_tready.value)
        accepted = pending is not None and ready_in == 1
        if pending is not None and not ready_in:
            tready_low_with_data += 1
        # result side
        take = 1 if (cycles > stall_cycles and random.random() < p_ready) else 0
        dut.m_axis_tready.value = take
        if take and int(dut.m_axis_tvalid.value):
            results.append((int(dut.m_axis_tdata.value), int(dut.m_axis_tuser.value),
                            int(dut.m_axis_tlast.value)))
    dut.s_axis_tvalid.value = 0
    dut.m_axis_tready.value = 0
    return results, cycles, tready_low_with_data


def check(dut, reqs, results, what):
    bad = 0
    for i, (req, (data, user, last)) in enumerate(zip(reqs, results)):
        got = unpack_res(data)
        if got != req["exp"] or user != req["user"] or last != req["last"]:
            bad += 1
            if bad <= 5:
                dut._log.error("%s[%d] op=%d rm=%d a=%x b=%x: got (y=%x f=%x c=%d) user=%d last=%d, "
                               "want (y=%x f=%x c=%d) user=%d last=%d", what, i, req["op"], req["rm"],
                               req["a"], req["b"], *got, user, last, *req["exp"], req["user"], req["last"])
        if data >> (OPB + 7):
            bad += 1
    assert bad == 0, f"{what}: {bad} mismatches"


@cocotb.test()
async def test_axis_random_backpressure(dut):
    """Mixed ops, random request gaps, m_axis_tready ~50%: every result in
    request order with its tuser/tlast."""
    await reset(dut)
    random.seed(SEED)
    rng = random.Random(SEED)
    reqs = requests(dut, rng, max(ITERS, 50) * 4)
    results, _, _ = await run_stream(dut, reqs, p_gap=0.3, p_ready=0.5)
    check(dut, reqs, results, "random")


@cocotb.test()
async def test_axis_throughput(dut):
    """A continuous same-op stream with m_axis_tready high sustains one
    operation per cycle: s_axis_tready never drops."""
    await reset(dut)
    random.seed(SEED + 1)
    rng = random.Random(SEED + 1)
    n = max(ITERS, 50) * 2
    reqs = requests(dut, rng, n, ops_list=[OP_ADD])
    results, cycles, low = await run_stream(dut, reqs, p_gap=0.0, p_ready=1.0)
    check(dut, reqs, results, "throughput")
    assert low == 0, f"s_axis_tready was low for {low} cycles with a request waiting"
    assert cycles <= n + 40, f"{n} results took {cycles} cycles"


@cocotb.test()
async def test_axis_output_stall(dut):
    """m_axis_tready held low for a long time: the wrapper must stop
    accepting requests (no result can be lost), then drain everything."""
    await reset(dut)
    random.seed(SEED + 2)
    rng = random.Random(SEED + 2)
    reqs = requests(dut, rng, 200)
    results, _, low = await run_stream(dut, reqs, p_gap=0.0, p_ready=0.7, stall_cycles=150)
    check(dut, reqs, results, "stall")
    assert low > 0, "s_axis_tready never dropped although the output was stalled"


@cocotb.test()
async def test_axis_latency(dut):
    """One request with m_axis_tready high: m_axis_tvalid rises L + 2 cycles
    after the handshake cycle (L = jsm_fp_unit latency; ADD: 3, or 1 at
    W_MANT = 0): one cycle in the skid buffer, one to the reorder buffer."""
    await reset(dut)
    lat_add = 1 if W_MANT == 0 else 3
    one = (FMT.bias << W_MANT) if W_MANT else FMT.bias
    dut.m_axis_tready.value = 1
    await FallingEdge(dut.aclk)
    dut.s_axis_tdata.value = pack_req(OP_ADD, 0, one, one, 0)
    dut.s_axis_tvalid.value = 1
    assert int(dut.s_axis_tready.value) == 1
    await FallingEdge(dut.aclk)                 # handshake happened at the rising edge
    dut.s_axis_tvalid.value = 0
    cycles = 1
    while not int(dut.m_axis_tvalid.value):
        await FallingEdge(dut.aclk)
        cycles += 1
        assert cycles < 100
    assert cycles == lat_add + 2, f"ADD through the AXI4-Stream wrapper took {cycles} cycles"
