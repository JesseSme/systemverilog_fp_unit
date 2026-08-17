#!/usr/bin/env python3
"""Exhaustive all-vectors verification of the FPU against the bit-exact
reference oracle (tests/reference/ops.py).

For each 8-bit format (1 + W_EXP + W_MANT == 8), every (op, rm, a, b)
combination -- op in {add, sub, mul, div, sqrt, fma, min, max, cmp, rndint,
totalorder}, all five rounding modes, and all 2^8 values for each operand --
is checked. This is 11*5*256*256 = 3,604,480 vectors per format. The cocotb
VPI path is far too slow for that volume, so the DUT is exercised through a
standalone Verilator C++ harness (tests/exhaustive_main.cpp) instead.

Usage:
    uv run python tests/exhaustive.py                 # all 8-bit formats
    uv run python tests/exhaustive.py --width 5 2     # single format
    uv run python tests/exhaustive.py --width 4 3 --keep

The expected results are precomputed with the reference oracle and written to
a binary file; the C++ harness reads it and reports any mismatch.

After RTL/reference changes, rebuild with FORCE_REBUILD=1 and delete the stale
expected.bin files (the harness reports "truncated expected file" if the
record layout or op count is out of sync).
"""

import argparse
import os
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from reference import ops  # noqa: E402
from reference.formats import BinFormat, encode_finite  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RTL = [os.path.join(ROOT, "rtl", f) for f in
       ("fp_pkg.sv", "fp_add.sv", "fp_add_e8m0.sv",
        "fp_mul.sv", "fp_mul_e8m0.sv", "fp_div.sv", "fp_div_e8m0.sv",
        "fp_sqrt.sv", "fp_sqrt_e8m0.sv", "fp_fma.sv", "fp_fma_e8m0.sv",
        "fp_minmax.sv", "fp_cmp.sv", "fp_totalorder.sv", "fp_roundint.sv",
        "fp_roundint_e8m0.sv", "fp_unit.sv")]
HARNESS = os.path.join(HERE, "exhaustive_main.cpp")
BUILD_DIR = os.path.join(ROOT, "exhaustive_build")

# All 8-bit formats the RTL supports (W_EXP >= 1, W_MANT >= 0).
FORMATS_8BIT = [(1, 6), (2, 5), (3, 4), (4, 3), (5, 2), (6, 1), (7, 0)]

N_OPS = 11  # add, sub, mul, div, sqrt, fma, min, max, cmp, rndint, totalorder


def fma_c(fmt: BinFormat) -> int:
    """The fixed c operand used for the exhaustive FMA op (1.0)."""
    return encode_finite(0, fmt.bias, 0, fmt)


def generate_expected(fmt: BinFormat, path: str) -> None:
    a_max = 1 << fmt.width
    c = fma_c(fmt)
    with open(path, "wb") as f:
        for op in range(N_OPS):
            for rm in range(5):
                for a in range(a_max):
                    for b in range(a_max):
                        cmp = 0
                        if op == 2:
                            y, flags = ops.fp_mul(a, b, rm, fmt)
                        elif op == 3:
                            y, flags = ops.fp_div(a, b, rm, fmt)
                        elif op == 4:
                            y, flags = ops.fp_sqrt(a, rm, fmt)
                        elif op == 5:
                            y, flags = ops.fp_fma(a, b, c, rm, fmt)
                        elif op == 6:
                            y, flags = ops.fp_min(a, b, fmt)
                        elif op == 7:
                            y, flags = ops.fp_max(a, b, fmt)
                        elif op == 8:
                            y, cmp, flags = ops.fp_cmp(a, b, fmt)
                        elif op == 9:
                            y, flags = ops.fp_roundint(a, rm, fmt)
                        elif op == 10:
                            y, cmp, flags = ops.fp_totalorder(a, b, fmt)
                        else:
                            y, flags = ops.fp_add(a, b, rm, fmt, sub=(op == 1))
                        f.write(struct.pack("BBB", y, flags, cmp))


def build(wexp: int, wmant: int) -> str:
    build_dir = os.path.join(BUILD_DIR, f"exp{wexp}_mant{wmant}")
    os.makedirs(build_dir, exist_ok=True)
    binary = os.path.join(build_dir, "fp_exhaustive")
    if os.path.exists(binary) and os.environ.get("FORCE_REBUILD", "0") != "1":
        return binary
    subprocess.check_call([
        "verilator", "--cc", "--exe", "--build", "--timing",
        "--top-module", "fp_unit",
        f"-GW_EXP={wexp}", f"-GW_MANT={wmant}",
        "--Mdir", build_dir, "--prefix", "Vfp_unit",
        "-o", "fp_exhaustive",
        *RTL, HARNESS,
    ])
    return binary


def run(wexp: int, wmant: int, keep: bool) -> bool:
    fmt = BinFormat(wexp, wmant)
    build_dir = os.path.join(BUILD_DIR, f"exp{wexp}_mant{wmant}")
    os.makedirs(build_dir, exist_ok=True)
    expected = os.path.join(build_dir, "expected.bin")
    if keep or not os.path.exists(expected):
        print(f"  generating expected vectors for ({wexp},{wmant}) ...")
        generate_expected(fmt, expected)
    binary = build(wexp, wmant)
    print(f"  running {binary} ...")
    proc = subprocess.run([binary, expected, str(fmt.width), str(fma_c(fmt))],
                          capture_output=True, text=True)
    sys.stderr.write(proc.stderr)
    return proc.returncode == 0


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--width", nargs=2, type=int, metavar=("W_EXP", "W_MANT"),
                    help="single format to test (default: all 8-bit formats)")
    ap.add_argument("--keep", action="store_true",
                    help="keep previously generated expected files")
    args = ap.parse_args()

    if args.width:
        widths = [tuple(args.width)]
    else:
        widths = FORMATS_8BIT

    ok = True
    for wexp, wmant in widths:
        print(f"=== 8-bit format W_EXP={wexp} W_MANT={wmant} ===")
        ok &= run(wexp, wmant, args.keep)
    print("ALL FORMATS PASS" if ok else "SOME FORMATS FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
