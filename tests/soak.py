#!/usr/bin/env python3
# Copyright 2026 Jesse Smedberg
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Cross-width randomized soak of the FPU against the bit-exact reference
oracle (tests/reference/ops.py).

Unlike tests/exhaustive.py -- which enumerates every 8-bit (op, rm, a, b)
combination -- the soak drives a seeded stream of boundary-biased random
operands through all 11 ops at arbitrary widths. The intended targets are the
medium formats (binary16, BF16, E4M3, optionally binary32) where exhaustive
enumeration of the 2^32+ operand pairs is infeasible; a soak of tens of
millions of vectors gives dense, reproducible cross-width coverage.

Usage:
    uv run python tests/soak.py                      # default widths
    uv run python tests/soak.py --width 8 23         # single width
    uv run python tests/soak.py --vectors 10000000   # vectors per width
    uv run python tests/soak.py --seed 0xdeadbeef

The expected records are precomputed with the reference oracle: per vector a
boundary-biased operand pair, an op and a rounding mode are drawn from a
seeded PRNG, and (a, b, y, flags, cmp) is written to a binary file.
tests/soak_main.cpp replays the same vector stream through the DUT (no
cocotb), so the whole soak runs at C++ speed after the Python expected
generation (~200k vec/s). After RTL/reference/harness changes the stale
expected.bin and binary are detected automatically via a content-hash stamp
(expected.stamp) and rebuilt; FORCE_REBUILD=1 remains as a manual override.
"""

import argparse
import hashlib
import os
import random
import struct
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from reference import gen, ops  # noqa: E402
from reference.formats import NUM_OPS, BinFormat, encode_finite  # noqa: E402
from rtl_files import rtl_paths  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RTL = rtl_paths()
REF = [os.path.join(HERE, "reference", f) for f in
       ("formats.py", "rounding.py", "ops.py", "gen.py")]
HARNESS = os.path.join(HERE, "soak_main.cpp")
BUILD_DIR = os.path.join(ROOT, "soak_build")

# Medium widths where the soak earns its keep (exhaustive is infeasible).
DEFAULT_WIDTHS = [(5, 10), (8, 7), (4, 3)]  # binary16, BF16, E4M3
DEFAULT_VECTORS = 5_000_000

N_OPS = NUM_OPS  # tests/reference/formats.py OP_NAMES


def _suffix(impl: int) -> str:
    """Build-dir/stamp suffix of a DIVSQRT_IMPL value (1 = default)."""
    return "" if impl == 1 else ("_iter" if impl == 2 else f"_ds{impl}")


def _stamp() -> str:
    """Content hash over the RTL, reference oracle and this harness, so a stale
    expected.bin or binary is detected after any relevant change."""
    h = hashlib.sha256()
    for f in RTL + REF + [HARNESS, os.path.abspath(__file__)]:
        with open(f, "rb") as fh:
            h.update(fh.read())
    return h.hexdigest()


def fma_c(fmt: BinFormat) -> int:
    """The fixed c operand used for the soak FMA op (1.0)."""
    return encode_finite(0, fmt.bias, 0, fmt)


def _run_width(job: tuple) -> bool:
    """ProcessPool entry point (widths are independent and GIL-bound)."""
    wexp, wmant, n, seed, keep, iter_mode = job
    return run(wexp, wmant, n, seed, keep, iter_mode)


def _pack_fmt(opbytes: int) -> str:
    return {1: "B", 2: "H", 4: "I", 8: "Q"}[opbytes]


def generate_expected(fmt: BinFormat, path: str, n: int, seed: int,
                      ops_en: int = 0xFFFF) -> None:
    """Write n (a, b, y, flags, cmp, op, rm) records for a seeded stream."""
    rng = random.Random(seed)
    c = fma_c(fmt)
    opbytes = (fmt.width + 7) // 8
    if opbytes not in (1, 2, 4, 8):
        raise ValueError(f"unsupported width {fmt.width} (opbytes {opbytes})")
    ab = _pack_fmt(opbytes)
    # a, b and the width-wide result y are opbytes each; flags/cmp/op/rm bytes.
    rec = struct.Struct("<" + ab + ab + ab + "BBBB")
    with open(path, "wb") as f:
        for _ in range(n):
            a, b = gen.pair_stream(rng, fmt, 1)[0]
            rm = rng.randrange(5)
            op = rng.randrange(N_OPS)
            y, flags, cmp = ops.dispatch(op, a, b, c, rm, fmt, ops_en)
            f.write(rec.pack(a, b, y, flags, cmp, op, rm))


def _current_stamp(build_dir: str) -> str | None:
    p = os.path.join(build_dir, "expected.stamp")
    if not os.path.exists(p):
        return None
    return open(p).read().strip()


def _read_stamp(build_dir: str, name: str) -> str | None:
    p = os.path.join(build_dir, name)
    if not os.path.exists(p):
        return None
    return open(p).read().strip()


def _write_stamp(build_dir: str, name: str, val: str) -> None:
    with open(os.path.join(build_dir, name), "w") as f:
        f.write(val + "\n")


def build(wexp: int, wmant: int, iter_mode: int) -> str:
    # Each div/sqrt implementation gets its own build dir (the Verilator
    # model differs; sharing an Mdir would rebuild on every switch).
    suffix = _suffix(iter_mode)
    build_dir = os.path.join(BUILD_DIR, f"exp{wexp}_mant{wmant}{suffix}")
    os.makedirs(build_dir, exist_ok=True)
    binary = os.path.join(build_dir, "fp_soak")
    want = _stamp() + _suffix(iter_mode)
    if (os.path.exists(binary) and os.environ.get("FORCE_REBUILD", "0") != "1"
            and _read_stamp(build_dir, "binary.stamp") == want):
        return binary
    subprocess.check_call([
        "verilator", "--cc", "--exe", "--build", "--timing", "--assert",
        "--coverage", "--coverage-line", "--coverage-toggle",
        "--top-module", "jsm_fp_unit",
        "-CFLAGS", f"-DNUM_OPS={N_OPS}",
        f"-GW_EXP={wexp}", f"-GW_MANT={wmant}",
        *([f"-GDIVSQRT_IMPL={iter_mode}"] if iter_mode != 1 else []),
        "--Mdir", build_dir, "--prefix", "Vjsm_fp_unit",
        "-o", "fp_soak",
        *RTL, HARNESS,
    ])
    _write_stamp(build_dir, "binary.stamp", want)
    return binary


def run(wexp: int, wmant: int, n: int, seed: int, keep: bool, iter_mode: int) -> bool:
    fmt = BinFormat(wexp, wmant)
    suffix = _suffix(iter_mode)
    build_dir = os.path.join(BUILD_DIR, f"exp{wexp}_mant{wmant}{suffix}")
    os.makedirs(build_dir, exist_ok=True)
    expected = os.path.join(build_dir, "expected.bin")
    meta = os.path.join(build_dir, "expected.meta")
    stale = True
    if os.path.exists(expected) and os.path.exists(meta):
        try:
            with open(meta) as f:
                mn, ms = (int(x.split("=")[1]) for x in f.read().split())
            stale = (mn != n) or (ms != seed)
        except (OSError, ValueError, IndexError):
            stale = True
    # The content stamp (RTL/reference/harness hash) also invalidates the
    # expected stream; n/seed above only cover the PRNG parameters. The
    # expected results do not depend on the build mode.
    want = _stamp() + _suffix(iter_mode)
    if _read_stamp(build_dir, "expected.stamp") != want:
        stale = True
    if keep or stale:
        print(f"  generating {n:,} expected vectors for ({wexp},{wmant}) ...")
        generate_expected(fmt, expected, n, seed)
        with open(meta, "w") as f:
            f.write(f"n={n} seed={seed}\n")
        _write_stamp(build_dir, "expected.stamp", want)
    binary = build(wexp, wmant, iter_mode)
    print(f"  running {binary} ...")
    # The harness asserts a constant latency per op on its own (first value
    # seen); jsm_fp_unit's out_valid == resv[0] assertion ties it to jsm_fp_pkg.
    proc = subprocess.run([binary, expected, str(fmt.width), str(fma_c(fmt)),
                           str(iter_mode), "0"],
                          capture_output=True, text=True)
    sys.stderr.write(proc.stderr)
    return proc.returncode == 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--width", nargs=2, type=int, metavar=("W_EXP", "W_MANT"),
                    help="single format to test (default: binary16, BF16, E4M3)")
    ap.add_argument("--vectors", type=int, default=DEFAULT_VECTORS,
                    help="vectors per width (default %(default)s)")
    ap.add_argument("--seed", type=lambda s: int(s, 0), default=0x50AC,
                    help="PRNG seed for the operand stream (default 0x50ac)")
    ap.add_argument("--keep", action="store_true",
                    help="keep previously generated expected files")
    ap.add_argument("--divsqrt", type=int, choices=(0, 1, 2, 3), default=1,
                    help="jsm_fp_unit DIVSQRT_IMPL: 1 SRT pipelines (default), "
                         "2 iterative engine, 3 SRT 250 MHz form, 0 combinational reference")
    ap.add_argument("--iter", action="store_true",
                    help="shorthand for --divsqrt 2 (iterative div/sqrt engine)")
    ap.add_argument("--jobs", type=int, default=0,
                    help="widths to run concurrently (0 = auto: one per core)")
    args = ap.parse_args()

    widths = [tuple(args.width)] if args.width else DEFAULT_WIDTHS
    impl = 2 if args.iter else args.divsqrt
    mode = {0: " (combinational div/sqrt)", 1: "", 2: " (iterative div/sqrt)",
            3: " (SRT div/sqrt, 250 MHz form)"}[impl]
    for wexp, wmant in widths:
        print(f"=== soak W_EXP={wexp} W_MANT={wmant} ({args.vectors:,} vectors){mode} ===",
              flush=True)

    jobs = args.jobs if args.jobs > 0 else min(len(widths), os.cpu_count() or 1)
    work = [(wexp, wmant, args.vectors, args.seed, args.keep, impl)
            for wexp, wmant in widths]
    if jobs > 1 and len(widths) > 1:
        with ProcessPoolExecutor(max_workers=jobs) as ex:
            results = list(ex.map(_run_width, work))
    else:
        results = [_run_width(job) for job in work]
    ok = all(results)
    print("ALL SOAK PASS" if ok else "SOME SOAK FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
