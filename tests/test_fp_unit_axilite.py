# Copyright 2026 Jesse Smedberg
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Cocotb tests for the AXI-Lite FPU wrapper (jsm_fp_unit_axilite).

Run via tests/run_regression.py --top jsm_fp_unit_axilite --tests test_fp_unit_axilite,
which instantiates the DUT at several (W_EXP, W_MANT) widths and sets
FP_W_EXP/FP_W_MANT/FP_ITERS/FP_SEED.

A small AXI-Lite BFM drives the register interface; expected (result, flags,
cmp) pairs come from the bit-exact Python oracle in tests/reference, so the
wrapper's datapath matches the one verified by test_fp_unit.py.
"""

import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

from reference import gen, ops
from reference.formats import BinFormat, MODE_NAMES, encode_finite

from reference.formats import (  # noqa: E402  (op table: single source of truth)
    NUM_OPS,
    OP_ADD,
    OP_CMP,
    OP_DIV,
    OP_FMA,
    OP_MAX,
    OP_MIN,
    OP_MUL,
    OP_RNDINT,
    OP_SQRT,
    OP_SUB,
    OP_TOTALORDER,
)

W_EXP = int(os.environ.get("FP_W_EXP", "8"))
W_MANT = int(os.environ.get("FP_W_MANT", "23"))
FMT = BinFormat(W_EXP, W_MANT)
ITERS = int(os.environ.get("FP_ITERS", "100"))
SEED = int(os.environ.get("FP_SEED", "0x5eed"), 0)

# ---- Register map (mirrors rtl/jsm_fp_unit_axilite.sv) -------------------------
W = 1 + W_EXP + W_MANT
REG_W = 1 << (W - 1).bit_length()          # next power of two >= W
WORDS = (REG_W + 31) // 32                  # 32-bit words per operand/result
ADDR_CTRL = 0x00
ADDR_OPCODE = 0x04
ADDR_A = 0x08
ADDR_B = ADDR_A + 4 * WORDS
ADDR_C = ADDR_B + 4 * WORDS
ADDR_STATUS = ADDR_C + 4 * WORDS
ADDR_RESULT = ADDR_STATUS + 4
ADDR_CMP = ADDR_RESULT + 4 * WORDS
TOTAL_BYTES = ADDR_CMP + 4

CTRL_GO = 1 << 0
CTRL_CLR = 1 << 1
STATUS_FLAGS_MASK = 0x1F
STATUS_BUSY = 1 << 8
STATUS_VALID = 1 << 9
AXI_OKAY = 0
AXI_DECERR = 3


async def reset(dut):
    dut.s_axi_aresetn.value = 0
    dut.s_axi_awaddr.value = 0
    dut.s_axi_awvalid.value = 0
    dut.s_axi_wdata.value = 0
    dut.s_axi_wstrb.value = 0xF
    dut.s_axi_wvalid.value = 0
    dut.s_axi_bready.value = 0
    dut.s_axi_araddr.value = 0
    dut.s_axi_arvalid.value = 0
    dut.s_axi_rready.value = 0
    await RisingEdge(dut.s_axi_aclk)
    await FallingEdge(dut.s_axi_aclk)
    dut.s_axi_aresetn.value = 1
    await RisingEdge(dut.s_axi_aclk)
    await FallingEdge(dut.s_axi_aclk)


# When True, write_word/read_word raise BREADY/RREADY at the start of the
# transaction, before the slave's BVALID/RVALID (allowed by AXI, and what
# many masters do); test_ready_before_valid sets it.
EARLY_READY = False
HANDSHAKE_TIMEOUT = 100   # cycles


async def _wait_high(dut, sig, what):
    for _ in range(HANDSHAKE_TIMEOUT):
        if int(sig.value):
            return
        await RisingEdge(dut.s_axi_aclk)
    raise AssertionError(f"timed out waiting for {what}")


async def write_word(dut, addr, data, strb=0xF, idle=0):
    """A single AXI-Lite 32-bit write. Returns the write response code."""
    for _ in range(idle):
        await RisingEdge(dut.s_axi_aclk)
    if EARLY_READY:
        dut.s_axi_bready.value = 1
    dut.s_axi_awaddr.value = addr & ((1 << 32) - 1)
    dut.s_axi_awvalid.value = 1
    dut.s_axi_wdata.value = data & 0xFFFFFFFF
    dut.s_axi_wstrb.value = strb & 0xF
    dut.s_axi_wvalid.value = 1
    while not (int(dut.s_axi_awready.value) and int(dut.s_axi_wready.value)):
        await RisingEdge(dut.s_axi_aclk)
    await RisingEdge(dut.s_axi_aclk)          # acceptance posedge
    dut.s_axi_awvalid.value = 0
    dut.s_axi_wvalid.value = 0
    await _wait_high(dut, dut.s_axi_bvalid, "BVALID")
    resp = int(dut.s_axi_bresp.value)
    dut.s_axi_bready.value = 1
    await RisingEdge(dut.s_axi_aclk)
    dut.s_axi_bready.value = 0
    return resp


async def read_word(dut, addr, idle=0):
    """A single AXI-Lite 32-bit read. Returns (data, response code)."""
    for _ in range(idle):
        await RisingEdge(dut.s_axi_aclk)
    if EARLY_READY:
        dut.s_axi_rready.value = 1
    dut.s_axi_araddr.value = addr & ((1 << 32) - 1)
    dut.s_axi_arvalid.value = 1
    while not int(dut.s_axi_arready.value):
        await RisingEdge(dut.s_axi_aclk)
    await RisingEdge(dut.s_axi_aclk)          # accept + move to R_DATA
    dut.s_axi_arvalid.value = 0
    await _wait_high(dut, dut.s_axi_rvalid, "RVALID")
    data = int(dut.s_axi_rdata.value)
    resp = int(dut.s_axi_rresp.value)
    dut.s_axi_rready.value = 1
    await RisingEdge(dut.s_axi_aclk)
    dut.s_axi_rready.value = 0
    return data, resp


async def write_operand(dut, base, val):
    """Write a REG_W-bit operand as WORDS little-endian 32-bit words."""
    for w in range(WORDS):
        await write_word(dut, base + 4 * w, (val >> (32 * w)) & 0xFFFFFFFF)


async def read_operand(dut, base):
    """Read a REG_W-bit operand as WORDS little-endian 32-bit words."""
    val = 0
    for w in range(WORDS):
        word, _ = await read_word(dut, base + 4 * w)
        val |= (word & 0xFFFFFFFF) << (32 * w)
    return val


def _flag_names(f):
    names = []
    for bit, name in ((4, "invalid"), (3, "div0"), (2, "overflow"),
                      (1, "underflow"), (0, "inexact")):
        if f & (1 << bit):
            names.append(name)
    return ",".join(names) or "-"


async def run_op(dut, mode, rm, a, b, c=0):
    """Write operands/opcode, drop GO, assert GO to start, wait for VALID,
    return (result, flags, cmp, status)."""
    await write_operand(dut, ADDR_A, a)
    await write_operand(dut, ADDR_B, b)
    await write_operand(dut, ADDR_C, c)
    await write_word(dut, ADDR_OPCODE, (mode & 0xF) | ((rm & 0x7) << 4))
    await write_word(dut, ADDR_CTRL, 0)            # drop GO so the next write is a rising edge
    await write_word(dut, ADDR_CTRL, CTRL_GO)

    for _ in range(200):
        st, _ = await read_word(dut, ADDR_STATUS)
        if st & STATUS_VALID:
            break
        await FallingEdge(dut.s_axi_aclk)
    else:
        raise AssertionError("timed out waiting for STATUS.VALID")

    result = await read_operand(dut, ADDR_RESULT)
    cmp_reg, _ = await read_word(dut, ADDR_CMP)
    st, _ = await read_word(dut, ADDR_STATUS)
    return result, st & STATUS_FLAGS_MASK, cmp_reg & 0x3, st


async def check(dut, mode, rm, a, b, exp_y, exp_f, what, c=0, exp_cmp=0):
    result, flags, cc, _st = await run_op(dut, mode, rm, a, b, c)
    y = result & ((1 << W) - 1)
    if y != exp_y or flags != exp_f or cc != exp_cmp:
        w = (W + 3) // 4
        dut._log.error(
            "%s: mode=%s rm=%s a=%0*x b=%0*x: got y=%0*x flags=%s cmp=%d, "
            "want y=%0*x flags=%s cmp=%d",
            what, {OP_ADD: "add", OP_SUB: "sub", OP_MUL: "mul", OP_DIV: "div",
                   OP_SQRT: "sqrt", OP_FMA: "fma", OP_MIN: "min", OP_MAX: "max",
                   OP_CMP: "cmp", OP_RNDINT: "rndint", OP_TOTALORDER: "totalorder"}[mode],
            MODE_NAMES[rm], w, a, w, b,
            w, y, _flag_names(flags), cc,
            w, exp_y, _flag_names(exp_f), exp_cmp,
        )
        raise AssertionError(f"{what} mismatch (rm={MODE_NAMES[rm]})")


# ---------------------------------------------------------------------------
# Directed AXI protocol tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_protocol(dut):
    """Reset state, read-back of written registers, WSTRB masking, DECERR,
    read-only write protection, CLR/G0 re-trigger."""
    cocotb.start_soon(Clock(dut.s_axi_aclk, 10, units="ns").start())
    await reset(dut)

    # Reset state: ctrl/opcode zeroed, status cleared, format id present.
    ctrl, resp = await read_word(dut, ADDR_CTRL)
    assert resp == AXI_OKAY and ctrl == 0, (hex(ctrl), resp)
    st, resp = await read_word(dut, ADDR_STATUS)
    assert resp == AXI_OKAY and st & 0x3FF == 0, (hex(st), resp)
    fid = st >> 16
    assert fid == ((W_EXP & 0xFF) | ((W_MANT & 0xFF) << 8)), hex(fid)

    # Operand write/read-back round trip.
    pattern = 0xDEADBEEF & ((1 << REG_W) - 1)
    await write_operand(dut, ADDR_A, pattern)
    assert (await read_operand(dut, ADDR_A)) == pattern

    # A zero-strb write leaves the operand unchanged.
    await write_word(dut, ADDR_A, 0, strb=0)
    assert (await read_operand(dut, ADDR_A)) == pattern

    # Out-of-range write and read return DECERR.
    resp = await write_word(dut, TOTAL_BYTES, 0x1234)
    assert resp == AXI_DECERR, resp
    data, resp = await read_word(dut, TOTAL_BYTES)
    assert resp == AXI_DECERR and data == 0, (hex(data), resp)

    # Write to a read-only register is ignored but returns OKAY.
    resp = await write_word(dut, ADDR_STATUS, 0xFFFFFFFF)
    assert resp == AXI_OKAY, resp
    st, resp = await read_word(dut, ADDR_STATUS)
    assert resp == AXI_OKAY and st & STATUS_FLAGS_MASK == 0

    # Full compute round trip with a hand-verified value: 1.0 + 1.0 = 2.0.
    a = encode_finite(0, FMT.bias, 0, FMT)
    two = encode_finite(0, FMT.bias + 1, 0, FMT)
    result, flags, cc, st = await run_op(dut, OP_ADD, 0, a, a)
    assert (result & ((1 << W) - 1)) == two, hex(result)
    assert flags == 0 and cc == 0

    # CLR clears VALID; GO low does not disturb the result.
    st, _ = await read_word(dut, ADDR_STATUS)
    assert st & STATUS_VALID
    await write_word(dut, ADDR_CTRL, 0)           # drop GO
    st, _ = await read_word(dut, ADDR_STATUS)
    assert st & STATUS_VALID                       # result still valid
    await write_word(dut, ADDR_CTRL, CTRL_CLR)
    st, _ = await read_word(dut, ADDR_STATUS)
    assert not (st & STATUS_VALID)

    # Re-trigger with a new op: SUB a - a = 0.
    result, flags, cc, _st = await run_op(dut, OP_SUB, 0, a, a)
    assert (result & ((1 << W) - 1)) == 0, hex(result)


@cocotb.test()
async def test_ready_before_valid(dut):
    """BREADY/RREADY held high before BVALID/RVALID (legal AXI master
    behaviour): every transaction must still complete, with the right data.
    The slave used to deassert BVALID/RVALID in the cycle it would have
    asserted them, so such a master waited forever."""
    global EARLY_READY
    cocotb.start_soon(Clock(dut.s_axi_aclk, 10, units="ns").start())
    await reset(dut)
    EARLY_READY = True
    try:
        pattern = 0x5A5AA5A5 & ((1 << REG_W) - 1)
        await write_operand(dut, ADDR_B, pattern)
        assert (await read_operand(dut, ADDR_B)) == pattern
        data, resp = await read_word(dut, TOTAL_BYTES)
        assert resp == AXI_DECERR and data == 0, (hex(data), resp)
        rng = random.Random(SEED ^ 0xEA41)
        for i in range(20):
            a, b = gen.pair_stream(rng, FMT, 1)[0]
            mode = rng.randrange(NUM_OPS)
            rm = rng.randrange(5)
            c = gen.operand(rng, FMT)
            exp_y, exp_f, exp_c = ops.dispatch(mode, a, b, c, rm, FMT)
            result, flags, cc, _st = await run_op(dut, mode, rm, a, b, c)
            y = result & ((1 << W) - 1)
            assert (y, flags, cc) == (exp_y, exp_f, exp_c), \
                (i, mode, rm, hex(a), hex(b), hex(y), flags, cc, hex(exp_y), exp_f, exp_c)
    finally:
        EARLY_READY = False


@cocotb.test()
async def test_random_mixed(dut):
    """Randomized ops/operands through the AXI register interface, checked
    against the bit-exact oracle (same stream as test_fp_unit.py)."""
    cocotb.start_soon(Clock(dut.s_axi_aclk, 10, units="ns").start())
    await reset(dut)
    rng = random.Random(SEED)
    for i in range(ITERS):
        a, b = gen.pair_stream(rng, FMT, 1)[0]
        mode = rng.randrange(NUM_OPS)
        rm = rng.randrange(5)
        c = gen.operand(rng, FMT) if mode == OP_FMA else 0
        exp_y, exp_f, exp_c = ops.dispatch(mode, a, b, c, rm, FMT)
        await check(dut, mode, rm, a, b, exp_y, exp_f, f"random[{i}]",
                    c=c, exp_cmp=exp_c)