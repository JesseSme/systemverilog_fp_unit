#!/usr/bin/env python3
"""Per-operation latency probe for the pipelined fp_unit.

Builds one Verilator model per format and drives a small set of boundary /
special vectors through every op, reporting the in_valid -> out_valid cycle
count (tests/latency_main.cpp). All vectors of an op must show the same
latency, so this doubles as a fixed-latency check for the fused pipelines.

Usage:
    uv run python tests/latency.py                    # default matrix
    uv run python tests/latency.py --width 8 23       # single format
    uv run python tests/latency.py --json out.json    # machine-readable

The cycle counts are measured at the design's operating clock (250 MHz here);
the printed table is the canonical per-op latency reference (README/HANDOFF).
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RTL = [os.path.join(ROOT, "rtl", f) for f in
       ("fp_pkg.sv", "fp_add.sv", "fp_add_pipe.sv", "fp_add_e8m0.sv",
        "fp_mul.sv", "fp_mul_core.sv", "fp_mul_pipe.sv", "fp_mul_e8m0.sv", "fp_div.sv", "fp_div_e8m0.sv",
        "fp_sqrt.sv", "fp_sqrt_e8m0.sv", "fp_divsqrt_iter.sv",
        "fp_fma.sv", "fp_fma_pipe.sv", "fp_fma_e8m0.sv",
        "fp_minmax.sv", "fp_minmax_pipe.sv", "fp_cmp.sv", "fp_cmp_pipe.sv", "fp_totalorder.sv", "fp_totalorder_pipe.sv",
        "fp_roundint.sv", "fp_roundint_pipe.sv", "fp_roundint_e8m0.sv", "fp_unit.sv")]
HARNESS = os.path.join(HERE, "latency_main.cpp")
BUILD_DIR = os.path.join(ROOT, "latency_build")

# Standard width matrix (binary16, binary32, E4M3, BF16, E8M0).
DEFAULT_FORMATS = [(5, 10), (8, 23), (4, 3), (8, 7), (8, 0)]

OPS = ["add", "sub", "mul", "div", "sqrt", "fma",
       "min", "max", "cmp", "rndint", "totalorder"]


def _env() -> dict:
    """Pin the distro toolchain ahead of the Siemens Catapult g++/make on PATH
    (verilator's --build shell-out resolves make/g++ from PATH; the Catapult
    copies break the C++ header search)."""
    env = dict(os.environ)
    env["PATH"] = "/usr/bin:/bin" + os.pathsep + env.get("PATH", "")
    return env


def _stamp() -> str:
    h = hashlib.sha256()
    for f in RTL + [HARNESS, os.path.abspath(__file__)]:
        with open(f, "rb") as fh:
            h.update(fh.read())
    return h.hexdigest()


def _read_stamp(build_dir: str, name: str) -> str | None:
    p = os.path.join(build_dir, name)
    if not os.path.exists(p):
        return None
    return open(p).read().strip()


def build(wexp: int, wmant: int) -> str:
    build_dir = os.path.join(BUILD_DIR, f"exp{wexp}_mant{wmant}")
    os.makedirs(build_dir, exist_ok=True)
    binary = os.path.join(build_dir, "fp_latency")
    want = _stamp()
    if (os.path.exists(binary) and os.environ.get("FORCE_REBUILD", "0") != "1"
            and _read_stamp(build_dir, "binary.stamp") == want):
        return binary
    subprocess.check_call([
        "verilator", "--cc", "--exe", "--build", "--timing",
        "--top-module", "fp_unit",
        f"-GW_EXP={wexp}", f"-GW_MANT={wmant}",
        "--Mdir", build_dir, "--prefix", "Vfp_unit",
        "-o", "fp_latency",
        *RTL, HARNESS,
    ], env=_env())
    with open(os.path.join(build_dir, "binary.stamp"), "w") as f:
        f.write(want + "\n")
    return binary


def run_width(job: tuple) -> tuple:
    wexp, wmant = job
    binary = build(wexp, wmant)
    proc = subprocess.run([binary, str(wexp), str(wmant)],
                          capture_output=True, text=True)
    sys.stderr.write(proc.stderr)
    cycles = {}
    for line in proc.stdout.splitlines():
        if line.startswith("LATENCY op="):
            fields = dict(kv.split("=") for kv in line.split()[1:])
            cycles[int(fields["op"])] = int(fields["cycles"])
    ok = proc.returncode == 0 and len(cycles) == 11
    return (wexp, wmant, cycles, ok)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--width", nargs=2, type=int, action="append",
                    metavar=("W_EXP", "W_MANT"),
                    help="single format to probe (repeatable; default: matrix)")
    ap.add_argument("--json", type=str, default=None,
                    help="write the measured table as JSON")
    ap.add_argument("--jobs", type=int, default=0,
                    help="widths to run concurrently (0 = one per core)")
    args = ap.parse_args()

    formats = [tuple(w) for w in args.width] if args.width else DEFAULT_FORMATS
    jobs = args.jobs if args.jobs > 0 else min(len(formats), os.cpu_count() or 1)
    work = [(wexp, wmant) for wexp, wmant in formats]
    if jobs > 1 and len(work) > 1:
        with ProcessPoolExecutor(max_workers=jobs) as ex:
            results = list(ex.map(run_width, work))
    else:
        results = [run_width(job) for job in work]

    # Pretty table: latency in cycles per format.
    names = [f"W_EXP={wexp} W_MANT={wmant}" for wexp, wmant, _, _ in results]
    colw = max(len(n) for n in names) + 2
    header = " " * colw + "  ".join(f"{op:>9}" for op in OPS)
    print(header)
    table = {}
    ok = True
    for (wexp, wmant, cycles, wok), name in zip(results, names):
        row = "  ".join(f"{cycles.get(i, 0):>9}" for i in range(11))
        print(f"{name:<{colw}}{row}")
        table[f"{wexp}x{wmant}"] = {OPS[i]: cycles.get(i) for i in range(11)}
        ok = ok and wok
    print("ALL LATENCY PROBES PASS" if ok else "SOME LATENCY PROBES FAILED")

    if args.json:
        with open(args.json, "w") as f:
            json.dump(table, f, indent=2, sort_keys=True)
            f.write("\n")
        print(f"wrote {args.json}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
