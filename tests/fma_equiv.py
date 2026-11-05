# Copyright 2026 Jesse Smedberg
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

"""Pipelined FMA (jsm_fp_fma_pipe) against the combinational jsm_fp_fma.

Exhaustive over every (rm, a, b, c) for the 8-bit formats (5 * 2^24 vectors
each, back to back), and biased random vectors (cancellation, alignment
saturation, subnormal factors, special values) for the wider formats. The
latency (lat_fma below, a copy of jsm_fp_pkg::lat_fma) is checked against
out_valid. Verilator C++ harness: tests/fma_equiv_main.cpp.

  uv run python tests/fma_equiv.py                  # default matrix
  uv run python tests/fma_equiv.py --width 8 23 --vectors 10000000
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from rtl_files import ROOT

BUILD_DIR = ROOT / "fma_equiv_build"
HARNESS = ROOT / "tests" / "fma_equiv_main.cpp"
TB = ROOT / "tests" / "fma_equiv_tb.sv"
RTL = [ROOT / "rtl" / f for f in ("jsm_fp_pkg.sv", "jsm_fp_mul_core.sv", "jsm_fp_fma.sv",
                                  "jsm_fp_fma_pipe.sv")]

EXHAUSTIVE = [(4, 3), (5, 2), (3, 4), (2, 5)]
RANDOM = [(5, 10), (8, 7), (8, 23), (6, 16), (11, 52), (10, 40), (4, 12), (3, 20)]


def lat_fma(wmant: int) -> int:
    """jsm_fp_pkg::lat_fma."""
    return 4 if wmant + 1 <= 32 else 5


def build(wexp: int, wmant: int) -> Path:
    bdir = BUILD_DIR / f"exp{wexp}_mant{wmant}"
    bdir.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["verilator", "--cc", "--exe", "--build", "-O3", "--top-module", "fma_equiv_tb",
         f"-GW_EXP={wexp}", f"-GW_MANT={wmant}", "--Mdir", str(bdir), "-o", "fma_equiv",
         "-Wno-fatal", "-Wno-lint", "-Wno-style",
         *map(str, RTL), str(TB), str(HARNESS)],
        check=True, stdout=subprocess.DEVNULL)
    return bdir / "fma_equiv"


def run(wexp: int, wmant: int, n: int) -> bool:
    binary = build(wexp, wmant)
    proc = subprocess.run([str(binary), str(wexp), str(wmant), str(lat_fma(wmant)), str(n)],
                          capture_output=True, text=True)
    sys.stdout.write(proc.stdout)
    sys.stderr.write(proc.stderr)
    return proc.returncode == 0


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--width", nargs=2, type=int, metavar=("W_EXP", "W_MANT"))
    ap.add_argument("--vectors", type=int, default=2_000_000,
                    help="random vectors per wide format (0 = exhaustive, <= 8 bits)")
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    args = ap.parse_args()

    if args.width:
        we, wm = args.width
        n = 0 if (1 + we + wm <= 8 and args.vectors == 0) else args.vectors
        jobs = [(we, wm, n)]
    else:
        jobs = [(we, wm, 0) for we, wm in EXHAUSTIVE] + [(we, wm, args.vectors) for we, wm in RANDOM]
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        ok = all(ex.map(lambda j: run(*j), jobs))
    print("FMA EQUIV PASS" if ok else "FMA EQUIV FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
