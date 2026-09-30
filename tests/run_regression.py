#!/usr/bin/env python3
"""Build and run the cocotb regression across all format widths.

Usage:
  uv run python tests/run_regression.py                  # default matrix
  uv run python tests/run_regression.py --all            # full width matrix
  uv run python tests/run_regression.py --width 8 23     # single width
  FP_ITERS=200 uv run python tests/run_regression.py     # volume override

Notes:
  * Verilator 5.020 + cocotb 1.9.2 are used (see pyproject.toml). The sim is
    fast (~1 s for the whole matrix at FP_ITERS=100) but occasionally hangs at
    startup; each width is therefore retried up to --retries times. A hang is
    detected either by a per-attempt wall-clock timeout (--timeout, default
    60 s) or by a startup watchdog that kills the sim after --startup-grace
    seconds of no output.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import sysconfig
import time
from pathlib import Path

try:
    from cocotb.runner import get_runner  # cocotb 1.9.x
except ImportError:
    from cocotb_tools.runner import get_runner  # cocotb 2.x

ROOT = Path(__file__).resolve().parent.parent
RTL = [ROOT / "rtl" / f for f in ("fp_pkg.sv", "fp_add.sv", "fp_add_e8m0.sv",
       "fp_mul.sv", "fp_mul_e8m0.sv", "fp_div.sv", "fp_div_e8m0.sv",
       "fp_sqrt.sv", "fp_sqrt_e8m0.sv", "fp_divsqrt_iter.sv",
       "fp_fma.sv", "fp_fma_e8m0.sv",
       "fp_minmax.sv", "fp_cmp.sv", "fp_totalorder.sv", "fp_roundint.sv",
       "fp_roundint_e8m0.sv", "fp_unit.sv", "fp_unit_axilite.sv",
       "fp32_to_bf16_round.sv", "fp_exp_seq.sv")]

# (W_EXP, W_MANT) matrix: standard interchange formats plus FP8/BF16/E8M0.
# Default = the formats the user exercises routinely; --all adds odd sizes.
WIDTHS = [(5, 10), (8, 23), (11, 52), (4, 3), (8, 7), (8, 0)]
WIDTHS_ALL = [(4, 3), (5, 10), (8, 23), (11, 52), (6, 16), (10, 40), (8, 7), (8, 0)]


def _sim_env(tests_dir: Path, wexp: int, wmant: int) -> dict:
    env = dict(os.environ)
    # The simulator binary embeds Python; give it the venv site-packages
    # (uv does not export PYTHONPATH for subprocesses) plus the test dir.
    env["PYTHONPATH"] = (
        str(tests_dir)
        + os.pathsep
        + sysconfig.get_paths()["purelib"]
        + os.pathsep
        + env.get("PYTHONPATH", "")
    )
    # cocotb links against the shared libpython at runtime (via the VPI lib);
    # uv-managed Pythons keep it in a non-standard location.
    libdir = sysconfig.get_config_var("LIBDIR")
    if libdir:
        env["LD_LIBRARY_PATH"] = str(libdir) + os.pathsep + env.get("LD_LIBRARY_PATH", "")
    env["FP_W_EXP"] = str(wexp)
    env["FP_W_MANT"] = str(wmant)
    env["FP_ITERS"] = os.environ.get("FP_ITERS", "100")
    env["FP_SEED"] = os.environ.get("FP_SEED", "0x5eed")
    return env


def _run_attempt(bin_path: Path, env: dict, timeout: int, test_module: str,
                 startup_grace: int = 10) -> tuple[int, str, str]:
    """Run the sim binary once; returns (rc, log, sim-log tail).

    A wall-clock `timeout` guards the whole run, and a `startup_grace` watchdog
    kills the process early if it produces no output at all within the first
    few seconds (the cocotb 1.9.2 + Verilator 5.020 startup race hangs before
    the sim prints anything). rc = 124 on either kind of hang, which the caller
    turns into a retry.
    """
    import tempfile

    with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as f:
        log_path = f.name
    run_env = dict(env)
    run_env["MODULE"] = test_module
    t0 = time.time()
    log_fh = open(log_path, "w")
    proc = subprocess.Popen(
        [str(bin_path)], cwd=str(bin_path.parent), env=run_env,
        stdout=log_fh, stderr=subprocess.STDOUT,
    )
    start = time.time()
    saw_output = False
    rc = None
    while proc.poll() is None:
        if os.path.getsize(log_path) > 0:
            saw_output = True
        elapsed = time.time() - start
        if elapsed > timeout or (not saw_output and elapsed > startup_grace):
            proc.kill()
            rc = 124
            break
        time.sleep(0.1)
    if rc is None:
        rc = proc.returncode
    log_fh.close()
    elapsed = time.time() - t0
    log = Path(log_path).read_text(errors="replace")
    return rc, log, f"({elapsed:.0f}s)"


def _patch_verilator_helper() -> None:
    """Apply the Verilated::time(main_time) fix to cocotb 1.9.2's
    verilator.cpp if not already applied.

    Without it, Verilator's internal clock never advances, so every cocotb
    Timer wait stalls for the embed's poll interval (~2 s per transaction).
    The venv copy is recreated by `uv sync`, so this runs on every invocation.
    """
    p = Path(sysconfig.get_paths()["purelib"]) / "cocotb" / "share" / "lib" / "verilator" / "verilator.cpp"
    if not p.exists():
        return
    src = p.read_text()
    if "Verilated::time(main_time)" in src:
        return
    old = """        } else {
            main_time = next_time;
        }"""
    new = """        } else {
            main_time = next_time;
            // Keep Verilator's internal clock in sync (cocotb 1.9.2 fix):
            // without this, gpi_get_sim_time() never advances and every
            // cocotb Timer wait stalls for the embed's poll interval (~2 s).
            Verilated::time(main_time);
        }"""
    if old not in src:
        return
    p.write_text(src.replace(old, new))
    # Bump the mtime past the second granularity so `make` reliably rebuilds
    # verilator.o even if it was compiled in the same wall-clock second.
    st = p.stat()
    os.utime(p, (st.st_atime, st.st_mtime + 2))
    print("patched cocotb verilator.cpp (Verilated::time fix)", flush=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--width", nargs=2, type=int, metavar=("W_EXP", "W_MANT"),
                    help="run a single width instead of the default matrix")
    ap.add_argument("--all", action="store_true",
                    help="run the full width matrix (6 widths)")
    ap.add_argument("--tests", default="test_fp_unit",
                    help="cocotb test module (default: test_fp_unit)")
    ap.add_argument("--top", default="fp_unit",
                    help="hdl toplevel DUT (default: fp_unit; fp_unit_axilite "
                         "for the AXI-Lite wrapper tests)")
    ap.add_argument("--retries", type=int, default=3,
                    help="attempts per width when the sim times out (default 3)")
    ap.add_argument("--timeout", type=int, default=60,
                    help="per-attempt wall-clock timeout in seconds (default 60)")
    args = ap.parse_args()

    widths = [tuple(args.width)] if args.width else (WIDTHS_ALL if args.all else WIDTHS)
    tests_dir = Path(__file__).resolve().parent
    _patch_verilator_helper()

    # FP_ITER_DIVSQRT=1 builds the DUT with the iterative div/sqrt engine; the
    # test must then honor the in_valid/out_valid handshake (the AXI-Lite
    # wrapper does; test_fp_unit samples the 1-cycle combinational path and is
    # only valid with the default 0).
    iter_mode = int(os.environ.get("FP_ITER_DIVSQRT", "0"))
    failures = 0
    for wexp, wmant in widths:
        params = {"W_EXP": wexp, "W_MANT": wmant}
        if iter_mode:
            params["ITER_DIVSQRT"] = 1
        build_dir = ROOT / "sim_build" / (
            f"exp{wexp}_mant{wmant}" + ("_iter" if iter_mode else ""))
        env = _sim_env(tests_dir, wexp, wmant)
        print(f"=== width W_EXP={wexp} W_MANT={wmant} ===", flush=True)
        runner = get_runner("verilator")
        runner.build(
            sources=RTL,
            hdl_toplevel=args.top,
            parameters=params,
            build_args=["--timing"],
            timescale=("1ns", "1ps"),
            build_dir=build_dir,
        )
        bin_path = build_dir / args.top
        if not bin_path.exists():
            print(f"    ERROR: no simulator binary at {bin_path}", flush=True)
            failures += 1
            continue

        attempt = 0
        while True:
            attempt += 1
            rc, log, timing = _run_attempt(bin_path, env, args.timeout, args.tests)
            if rc == 0 and "TESTS=" in log:
                m = re.search(r"\*\* TESTS=\d+ PASS=(\d+) FAIL=(\d+)", log)
                if m:
                    passed, failed = int(m.group(1)), int(m.group(2))
                    print(f"    attempt {attempt}: TESTS PASS={passed} FAIL={failed} {timing}",
                          flush=True)
                    failures += failed
                    for line in log.splitlines():
                        if "ERROR" in line and "cocotb.fp_unit" in line:
                            print("    " + line.strip(), flush=True)
                    break
            if rc == 124:
                print(f"    attempt {attempt}: TIMED OUT {timing} - retrying", flush=True)
            else:
                print(f"    attempt {attempt}: rc={rc} {timing} - retrying", flush=True)
            if attempt >= args.retries:
                print("    giving up on this width", flush=True)
                failures += 1
                break

    if failures:
        print(f"REGRESSION FAILED: {failures} failing tests", flush=True)
        return 1
    print("all widths passed", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
