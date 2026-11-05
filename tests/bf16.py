#!/usr/bin/env python3
"""Exhaustive check of rtl/jsm_fp32_to_bf16_round.sv (binary32 -> bfloat16 RNE).

Writes oracle records (tests/reference/ops.py:f32_to_bf16_rne) for every
special/boundary encoding plus random inputs, then runs tests/bf16_main.cpp,
which checks the DUT against them and sweeps all 2^32 inputs against a C++
rule that the oracle records validate.

Usage:
    uv run python tests/bf16.py              # full 2^32 sweep
    uv run python tests/bf16.py --stride 97  # sampled sweep (quick)
"""

from __future__ import annotations

import argparse
import os
import random
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from reference.ops import f32_to_bf16_rne  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "rtl", "jsm_fp32_to_bf16_round.sv")
HARNESS = os.path.join(HERE, "bf16_main.cpp")
BUILD_DIR = os.path.join(ROOT, "bf16_build")


def oracle_inputs(n_random: int, seed: int) -> list[int]:
    xs = set()
    for sign in (0, 1):
        for e in range(256):
            for m in (0, 1, 2, 0x7FFF, 0x8000, 0x8001, 0xFFFF, 0x10000, 0x17FFF,
                      0x18000, 0x18001, 0x200000, 0x3F0000, 0x400000, 0x400001,
                      0x7F7FFF, 0x7F8000, 0x7FFFFF, 0x7FFF7FFF & 0x7FFFFF):
                xs.add((sign << 31) | (e << 23) | m)
    rng = random.Random(seed)
    for _ in range(n_random):
        xs.add(rng.getrandbits(32))
    return sorted(xs)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--stride", type=int, default=1)
    ap.add_argument("--random", type=int, default=200_000)
    ap.add_argument("--seed", type=lambda s: int(s, 0), default=0xBF16)
    args = ap.parse_args()

    os.makedirs(BUILD_DIR, exist_ok=True)
    oracle = os.path.join(BUILD_DIR, "oracle.bin")
    with open(oracle, "wb") as f:
        for x in oracle_inputs(args.random, args.seed):
            f.write(struct.pack("<IH", x, f32_to_bf16_rne(x)))
    env = dict(os.environ)
    env["PATH"] = "/usr/bin:/bin" + os.pathsep + env.get("PATH", "")
    subprocess.check_call([
        "verilator", "--cc", "--exe", "--build", "-O3",
        "--top-module", "jsm_fp32_to_bf16_round",
        "--Mdir", BUILD_DIR, "-o", "fp_bf16", SRC, HARNESS,
    ], env=env, stdout=subprocess.DEVNULL)
    proc = subprocess.run([os.path.join(BUILD_DIR, "fp_bf16"), oracle, str(args.stride)],
                          capture_output=True, text=True)
    sys.stderr.write(proc.stderr)
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
