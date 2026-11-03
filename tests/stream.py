#!/usr/bin/env python3
"""Streaming / mixed-issue test of fp_unit (back-to-back requests).

Every other fp_unit-level harness issues one operation and waits for its
result. This one offers a request EVERY cycle (tests/stream_main.cpp) and
matches results to requests through in_tag/out_tag, so it checks:

  * same-op mode: each pipeline accepts one request per cycle and keeps its
    per-stage context aligned (the FMA/MUL back-to-back bug class);
  * mixed mode: requests of different latencies never collide on the result
    port (in_ready backpressure) and every request returns exactly once.

The vector stream is the soak stream (tests/soak.py: boundary-biased
operands, all ops, all five rounding modes) checked against the bit-exact
oracle.

Usage:
    uv run python tests/stream.py                     # default widths, both modes
    uv run python tests/stream.py --width 8 23 --mode mixed
    uv run python tests/stream.py --vectors 1000000
"""

from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import soak  # noqa: E402  (vector generation and record layout)
from reference.formats import NUM_OPS, OP_NAMES, BinFormat  # noqa: E402
from rtl_files import rtl_paths  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RTL = rtl_paths()
HARNESS = os.path.join(HERE, "stream_main.cpp")
BUILD_DIR = os.path.join(ROOT, "stream_build")

DEFAULT_WIDTHS = [(5, 10), (8, 7), (4, 3), (8, 23), (8, 0)]  # binary16, BF16, E4M3, binary32, E8M0
DEFAULT_VECTORS = 200_000


def _env() -> dict:
    env = dict(os.environ)
    env["PATH"] = "/usr/bin:/bin" + os.pathsep + env.get("PATH", "")
    return env


def _stamp(params: list[str]) -> str:
    h = hashlib.sha256()
    for f in RTL + [HARNESS, os.path.abspath(__file__)]:
        with open(f, "rb") as fh:
            h.update(fh.read())
    h.update(" ".join(params).encode())
    return h.hexdigest()


def _read(path: str) -> str | None:
    return open(path).read().strip() if os.path.exists(path) else None


def build(wexp: int, wmant: int, params: list[str], tag: str) -> str:
    build_dir = os.path.join(BUILD_DIR, f"exp{wexp}_mant{wmant}{tag}")
    os.makedirs(build_dir, exist_ok=True)
    binary = os.path.join(build_dir, "fp_stream")
    want = _stamp(params)
    if (os.path.exists(binary) and os.environ.get("FORCE_REBUILD", "0") != "1"
            and _read(os.path.join(build_dir, "binary.stamp")) == want):
        return binary
    subprocess.check_call([
        "verilator", "--cc", "--exe", "--build", "--timing", "--assert",
        "--top-module", "fp_unit",
        "-CFLAGS", f"-DNUM_OPS={NUM_OPS}",
        f"-GW_EXP={wexp}", f"-GW_MANT={wmant}", "-GTAG_W=32", *params,
        "--Mdir", build_dir, "--prefix", "Vfp_unit",
        "-o", "fp_stream",
        *RTL, HARNESS,
    ], env=_env(), stdout=subprocess.DEVNULL)
    with open(os.path.join(build_dir, "binary.stamp"), "w") as f:
        f.write(want + "\n")
    return binary


def expected_file(wexp: int, wmant: int, n: int, seed: int) -> str:
    """Soak-format vector file (regenerated when n/seed/oracle change)."""
    fmt = BinFormat(wexp, wmant)
    d = os.path.join(BUILD_DIR, f"exp{wexp}_mant{wmant}_vectors")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "expected.bin")
    h = hashlib.sha256(f"{n} {seed}".encode())
    for f in soak.REF + [soak.__file__]:
        with open(f, "rb") as fh:
            h.update(fh.read())
    want = h.hexdigest()
    stamp = os.path.join(d, "expected.stamp")
    if _read(stamp) != want or not os.path.exists(path):
        print(f"  generating {n:,} vectors for ({wexp},{wmant}) ...", flush=True)
        soak.generate_expected(fmt, path, n, seed)
        with open(stamp, "w") as f:
            f.write(want + "\n")
    return path


def run(job: tuple) -> bool:
    wexp, wmant, n, seed, modes, params, tag, nostall = job
    fmt = BinFormat(wexp, wmant)
    vec = expected_file(wexp, wmant, n, seed)
    binary = build(wexp, wmant, params, tag)
    ok = True
    for mode in modes:
        proc = subprocess.run([binary, vec, str(fmt.width), str(soak.fma_c(fmt)), mode,
                               hex(nostall)],
                              capture_output=True, text=True)
        out = proc.stdout + proc.stderr
        status = [ln for ln in out.splitlines() if ln.startswith("STREAM ") and "vectors" in ln]
        detail = [ln for ln in out.splitlines()
                  if ln.startswith(("MISMATCH", "LOST", "UNKNOWN", "UNEXPECTED", "STALL",
                                    "NEVER", "%Error", "[")) or "fp_unit:" in ln]
        print(f"[{wexp},{wmant}{tag}] " + (status[0] if status else f"rc={proc.returncode}"),
              flush=True)
        for ln in detail[:20]:
            print("    " + ln, flush=True)
        if mode == "same":
            for ln in proc.stdout.splitlines():
                if ln.startswith("STREAM op="):
                    fields = dict(kv.split("=") for kv in ln.split()[1:])
                    op = int(fields["op"])
                    print(f"    {OP_NAMES[op]:>10}: issued {fields['issued']:>7} "
                          f"stalls {fields['stalls']:>7}", flush=True)
        ok = ok and proc.returncode == 0
    return ok


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--width", nargs=2, type=int, action="append",
                    metavar=("W_EXP", "W_MANT"), help="format (repeatable)")
    ap.add_argument("--vectors", type=int, default=DEFAULT_VECTORS)
    ap.add_argument("--seed", type=lambda s: int(s, 0), default=0x57EA)
    ap.add_argument("--mode", choices=("same", "mixed", "both"), default="both")
    ap.add_argument("--param", action="append", default=[],
                    help="extra Verilator -G parameter, e.g. --param ITER_DIVSQRT=0")
    ap.add_argument("--nostall", type=lambda s: int(s, 0), default=(1 << NUM_OPS) - 1,
                    help="bitmask of ops that must stream without stalls (same mode)")
    ap.add_argument("--jobs", type=int, default=0)
    args = ap.parse_args()

    widths = [tuple(w) for w in args.width] if args.width else DEFAULT_WIDTHS
    modes = ("same", "mixed") if args.mode == "both" else (args.mode,)
    params = [f"-G{p}" for p in args.param]
    tag = "".join("_" + p.replace("=", "") for p in args.param)
    work = [(we, wm, args.vectors, args.seed, modes, params, tag, args.nostall)
            for we, wm in widths]
    jobs = args.jobs if args.jobs > 0 else min(len(work), os.cpu_count() or 1)
    if jobs > 1 and len(work) > 1:
        with ProcessPoolExecutor(max_workers=jobs) as ex:
            results = list(ex.map(run, work))
    else:
        results = [run(j) for j in work]
    ok = all(results)
    print("ALL STREAM PASS" if ok else "SOME STREAM FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
