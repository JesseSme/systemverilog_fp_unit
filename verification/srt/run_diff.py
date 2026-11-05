#!/usr/bin/env python3
# Copyright 2026 Jesse Smedberg
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Streaming differential for the SRT div/sqrt pipelines.

Builds one Verilator model per format (`jsm_fp_div_srt` vs combinational
`jsm_fp_div`, `jsm_fp_sqrt_srt` vs combinational `jsm_fp_sqrt`), then streams one start
per cycle and compares every pipelined result against the combinational
datapath evaluated on the operands that started it (FIFO-tracked in the C++
harness). This is the check that caught the digit-selection, signed-cast and
radicand-slice bugs during the SRT rework.

Usage:
    uv run python verification/srt/run_diff.py                 # default matrix
    uv run python verification/srt/run_diff.py --width 8 23 --vectors 2000000
    uv run python verification/srt/run_diff.py --param DPS=1 --param FOLD_STG=1
"""

import argparse
import os
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
COMMON_RTL = [os.path.join(ROOT, "rtl", f) for f in
              ("jsm_fp_pkg.sv", "jsm_fp_div.sv", "jsm_fp_sqrt.sv")]
BUILD = os.path.join(ROOT, "srt_diff_build")

OPS = {
    "div":  ("div_srt_diff_top",  "jsm_fp_div_srt.sv",  "div_diff_top.sv",  "div_diff_main.cpp"),
    "sqrt": ("sqrt_srt_diff_top", "jsm_fp_sqrt_srt.sv", "sqrt_diff_top.sv", "sqrt_diff_main.cpp"),
}

DEFAULT_FORMATS = [(5, 10), (8, 23), (4, 3), (5, 2), (8, 7), (11, 52), (10, 40)]


def _env() -> dict:
    env = dict(os.environ)
    env["PATH"] = "/usr/bin:/bin" + os.pathsep + env.get("PATH", "")
    return env


def build_and_run(job) -> tuple:
    wexp, wmant, vectors, seed, params = job
    psuffix = "".join(f"_{k}{v}" for k, v in params)
    results = []
    for op, (top, module, wrapper, harness) in OPS.items():
        name = f"{op}_{wexp}x{wmant}{psuffix}"
        bdir = os.path.join(BUILD, name)
        exe = os.path.join(bdir, op)
        os.makedirs(bdir, exist_ok=True)
        cmd = ["verilator", "--cc", "--exe", "--build", "--timing",
               "--top-module", top, f"-GW_EXP={wexp}", f"-GW_MANT={wmant}",
               *[f"-G{k}={v}" for k, v in params],
               "--Mdir", bdir, "--prefix", "V" + top, "-o", op,
               *COMMON_RTL,
               os.path.join(ROOT, "rtl", module),
               os.path.join(HERE, wrapper),
               os.path.join(HERE, harness)]
        try:
            subprocess.check_call(cmd, env=_env(), stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            results.append((op, False, "build failed"))
            continue
        proc = subprocess.run([exe, str(wexp), str(wmant), str(vectors), hex(seed)],
                              capture_output=True, text=True)
        ok = proc.returncode == 0 and "PASS" in proc.stderr
        tail = proc.stderr.strip().splitlines()[-1] if proc.stderr.strip() else ""
        results.append((op, ok, tail))
    return wexp, wmant, results


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--width", nargs=2, type=int, action="append",
                    metavar=("W_EXP", "W_MANT"), help="format (repeatable)")
    ap.add_argument("--vectors", type=int, default=300000)
    ap.add_argument("--seed", type=lambda s: int(s, 0), default=0x123456789abcdef)
    ap.add_argument("--jobs", type=int, default=0)
    ap.add_argument("--param", action="append", default=[], metavar="K=V",
                    help="SRT module parameter override, e.g. DPS=1 or FOLD_STG=1")
    args = ap.parse_args()

    formats = [tuple(w) for w in args.width] if args.width else DEFAULT_FORMATS
    params = tuple(tuple(p.split("=", 1)) for p in args.param)
    work = [(we, wm, args.vectors, args.seed, params) for we, wm in formats]
    jobs = args.jobs if args.jobs > 0 else min(len(work), os.cpu_count() or 1)
    if jobs > 1 and len(work) > 1:
        with ProcessPoolExecutor(max_workers=jobs) as ex:
            results = list(ex.map(build_and_run, work))
    else:
        results = [build_and_run(j) for j in work]

    ok = True
    for wexp, wmant, res in results:
        for op, op_ok, line in res:
            ok = ok and op_ok
            print(f"W_EXP={wexp} W_MANT={wmant}{''.join(f' {k}={v}' for k, v in params)} {op:4s}: {'PASS' if op_ok else 'FAIL'}  {line}")
    print("ALL SRT DIFFERENTIALS PASS" if ok else "SOME SRT DIFFERENTIALS FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
