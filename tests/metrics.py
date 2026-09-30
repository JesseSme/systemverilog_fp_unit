#!/usr/bin/env python3
"""Quantitative optimization metrics for the FPU (area/timing proxy + runtime).

Area and timing are proxied with Yosys `synth; stat; ltp -noff` on the
parameterized top, per format:
  * cells -- post-synthesis generic-gate cell count (area proxy; the local
             counts of every elaborated module are summed)
  * ltp   -- longest topological path in logic levels (Fmax proxy)
Runtime metrics time the standard make/test targets so verification-flow
optimizations can be measured against a baseline.

Usage:
    uv run python tests/metrics.py --area --out metrics/area-baseline.json
    uv run python tests/metrics.py --runtime --targets lint smoke
    uv run python tests/metrics.py --compare metrics/area-baseline.json metrics/area-after.json
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RTL = [ROOT / "rtl" / f for f in (
    "fp_pkg.sv", "fp_add.sv", "fp_add_pipe.sv", "fp_add_e8m0.sv",
    "fp_mul.sv", "fp_mul_core.sv", "fp_mul_pipe.sv", "fp_mul_e8m0.sv", "fp_div.sv", "fp_div_e8m0.sv",
    "fp_sqrt.sv", "fp_sqrt_e8m0.sv", "fp_divsqrt_iter.sv",
    "fp_fma.sv", "fp_fma_pipe.sv", "fp_fma_e8m0.sv",
    "fp_minmax.sv", "fp_minmax_pipe.sv", "fp_cmp.sv", "fp_cmp_pipe.sv", "fp_totalorder.sv", "fp_totalorder_pipe.sv", "fp_roundint.sv", "fp_roundint_pipe.sv",
    "fp_roundint_e8m0.sv", "fp_unit.sv")]

OSS = Path(os.environ.get(
    "OSS", "/home/jesse/Documents/oss-cad-suite-linux-x64-20260813/oss-cad-suite"))
YOSYS = os.environ.get("YOSYS", str(OSS / "bin" / "yosys"))

# Standard width matrix (binary16, binary32, E4M3, BF16, E8M0).
DEFAULT_FORMATS = [(5, 10), (8, 23), (4, 3), (8, 7), (8, 0)]

# Runtime targets: make targets plus the exhaustive sweep (which has no target).
TARGETS: dict[str, list[str]] = {
    "lint": ["make", "lint"],
    "smoke": ["make", "smoke"],
    "regress": ["make", "regress"],
    "regress-all": ["make", "regress-all"],
    "exhaustive": ["uv", "run", "python", "tests/exhaustive.py"],
    "soak": ["make", "soak"],
    "coverage": ["make", "coverage"],
    "formal": ["make", "formal"],
}
DEFAULT_TARGETS = ["lint", "smoke", "regress"]


def _env() -> dict:
    """Subprocess environment for the runtime targets.

    Pin the distro toolchain ahead of the user PATH: the nested cocotb runner
    invokes `make` from PATH, which otherwise resolves to the Siemens Catapult
    make and fails the build, and rpm/deb verilator must stay ahead of the
    oss-cad-suite copy. Yosys is invoked by absolute path (YOSYS) and the
    `formal` target prepends oss-cad-suite itself, so OSS is not added here.
    """
    env = dict(os.environ)
    env["PATH"] = "/usr/bin:/bin" + os.pathsep + env.get("PATH", "")
    return env


def _tool_versions() -> dict:
    ver = {}
    for name, cmd in (("yosys", [YOSYS, "-V"]),
                      ("verilator", ["verilator", "--version"])):
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
            ver[name] = proc.stdout.strip().splitlines()[0]
        except (OSError, subprocess.SubprocessError, IndexError):
            ver[name] = "unavailable"
    try:
        proc = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                              cwd=ROOT, capture_output=True, text=True, timeout=30)
        ver["git_head"] = proc.stdout.strip() or "unknown"
    except (OSError, subprocess.SubprocessError):
        ver["git_head"] = "unknown"
    return ver


def _module_of(path: str) -> str:
    return path.rsplit("\\", 1)[-1].split("$")[0]


def parse_yosys(log: str) -> dict:
    """Extract per-module cell counts and ltp lengths from yosys stdout."""
    modules: dict[str, dict] = {}
    current = None
    for line in log.splitlines():
        m = re.match(r"^=== (.*) ===$", line)
        if m:
            name = _module_of(m.group(1))
            current = None if name == "design hierarchy" else name
            if current:
                modules.setdefault(current, {"cells": 0, "ltp": 0})
            continue
        m = re.match(r"^\s+(\d+) cells\s*$", line)
        if m and current:
            modules[current]["cells"] = int(m.group(1))
            continue
        m = re.match(r"^Longest topological path in (.*) \(length=(\d+)\)", line)
        if m:
            modules.setdefault(_module_of(m.group(1)), {"cells": 0, "ltp": 0})
            modules[_module_of(m.group(1))]["ltp"] = int(m.group(2))
    total = sum(d["cells"] for d in modules.values())
    return {"total_cells": total, "modules": modules}


def area_once(wexp: int, wmant: int, timeout: int, iter_mode: bool = False) -> dict:
    script = "; ".join([
        "read_verilog -sv " + " ".join(str(p) for p in RTL),
        f"chparam -set W_EXP {wexp} -set W_MANT {wmant}"
        + (" -set ITER_DIVSQRT 1" if iter_mode else "") + " fp_unit",
        "hierarchy -top fp_unit",
        # abc optimization is skipped: it is intractably slow on the
        # combinational divider/square root at binary32 and the pre-abc
        # gate count is a stable, comparable area proxy.
        "synth -top fp_unit -noabc",
        "stat",
        "ltp -noff",
    ])
    t0 = time.time()
    try:
        proc = subprocess.run([YOSYS, "-p", script], cwd=ROOT, env=_env(),
                              capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"yosys timed out after {timeout}s for ({wexp},{wmant})")
    elapsed = round(time.time() - t0, 2)
    if proc.returncode != 0:
        tail = "\n".join(proc.stdout.splitlines()[-20:] + proc.stderr.splitlines()[-20:])
        raise RuntimeError(f"yosys failed for ({wexp},{wmant}):\n{tail}")
    result = parse_yosys(proc.stdout)
    result["yosys_seconds"] = elapsed
    return result


def collect_area(formats: list[tuple[int, int]], timeout: int,
                 iter_mode: bool = False) -> dict:
    if not Path(YOSYS).exists():
        raise SystemExit(f"yosys not found at {YOSYS} (set OSS or YOSYS)")
    out = {}
    for wexp, wmant in formats:
        key = f"{wexp}x{wmant}"
        print(f"=== area {key}{' iter' if iter_mode else ''} ===", flush=True)
        out[key] = area_once(wexp, wmant, timeout, iter_mode)
        print(f"    cells={out[key]['total_cells']} yosys={out[key]['yosys_seconds']}s",
              flush=True)
    return out


def run_target(name: str, timeout: int) -> dict:
    cmd = TARGETS[name]
    t0 = time.time()
    rc = 0
    note = ""
    log = ""
    try:
        proc = subprocess.run(cmd, cwd=ROOT, env=_env(), capture_output=True,
                              text=True, timeout=timeout)
        rc = proc.returncode
        log = proc.stdout + proc.stderr
    except subprocess.TimeoutExpired:
        rc = 124
        note = f"timed out after {timeout}s"
    elapsed = round(time.time() - t0, 2)
    tail = [ln for ln in log.splitlines() if ln.strip()]
    record = {"seconds": elapsed, "rc": rc, "command": " ".join(cmd)}
    if tail:
        record["last_line"] = tail[-1].strip()
    if note:
        record["note"] = note
    return record


def collect_runtime(targets: list[str], timeout: int) -> dict:
    out = {}
    for name in targets:
        print(f"=== runtime {name} ===", flush=True)
        out[name] = run_target(name, timeout)
        print(f"    {out[name]['seconds']}s rc={out[name]['rc']}", flush=True)
    return out


def _pct(before: float, after: float) -> str:
    if before == 0:
        return "n/a"
    return f"{100.0 * (after - before) / before:+.1f}%"


def compare(pa: Path, pb: Path) -> int:
    a = json.loads(pa.read_text())
    b = json.loads(pb.read_text())
    if bool(a.get("iter_divsqrt")) != bool(b.get("iter_divsqrt")):
        print(f"note: config differs (ITER_DIVSQRT {a.get('iter_divsqrt')} -> "
              f"{b.get('iter_divsqrt')})")
    for section in ("area", "runtime"):
        if section not in a or section not in b:
            continue
        print(f"\n## {section}: {pa.name} -> {pb.name}")
        if section == "area":
            for key in sorted(set(a[section]) & set(b[section])):
                fa, fb = a[section][key], b[section][key]
                print(f"-- {key}: cells {fa['total_cells']} -> {fb['total_cells']} "
                      f"({_pct(fa['total_cells'], fb['total_cells'])})")
                names = sorted(set(fa["modules"]) | set(fb["modules"]))
                for name in names:
                    ma = fa["modules"].get(name)
                    mb = fb["modules"].get(name)
                    if not ma or not mb or ma == mb:
                        continue
                    print(f"   {name:<14} cells {ma['cells']:>6} -> {mb['cells']:>6} "
                          f"({_pct(ma['cells'], mb['cells']):>7})"
                          f"  ltp {ma['ltp']:>4} -> {mb['ltp']:>4}")
        else:
            for key in sorted(set(a[section]) & set(b[section])):
                ta, tb = a[section][key], b[section][key]
                print(f"-- {key}: {ta['seconds']}s -> {tb['seconds']}s "
                      f"({_pct(ta['seconds'], tb['seconds'])})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--area", action="store_true", help="collect area/timing proxies")
    ap.add_argument("--runtime", action="store_true", help="time the standard targets")
    ap.add_argument("--formats", nargs=2, type=int, action="append",
                    metavar=("W_EXP", "W_MANT"),
                    help="area format (repeatable; default: standard matrix)")
    ap.add_argument("--iter", action="store_true",
                    help="measure with ITER_DIVSQRT=1 (iterative div/sqrt engine)")
    ap.add_argument("--targets", nargs="+", choices=sorted(TARGETS),
                    default=DEFAULT_TARGETS, help="runtime targets to time")
    ap.add_argument("--out", type=Path, help="JSON output path")
    ap.add_argument("--area-timeout", type=int, default=1800,
                    help="per-format yosys timeout in seconds (default 1800)")
    ap.add_argument("--target-timeout", type=int, default=3600,
                    help="per-target wall-clock timeout in seconds (default 3600)")
    ap.add_argument("--compare", nargs=2, type=Path, metavar=("BEFORE", "AFTER"),
                    help="print deltas between two metrics JSON files")
    args = ap.parse_args()

    if args.compare:
        return compare(*args.compare)
    if not args.area and not args.runtime:
        args.area = True

    record: dict = {
        "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "tools": _tool_versions(),
        "iter_divsqrt": bool(args.iter),
    }
    if args.area:
        record["area"] = collect_area(args.formats or DEFAULT_FORMATS,
                                      args.area_timeout, args.iter)
    if args.runtime:
        record["runtime"] = collect_runtime(args.targets, args.target_timeout)

    text = json.dumps(record, indent=2, sort_keys=True)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text + "\n")
        print(f"wrote {args.out}")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
