#!/usr/bin/env python3
"""Vivado xsim check of the Verilog and VHDL tops (rtl/top/).

Compiles the SystemVerilog core, the Verilog-2001 tops and the VHDL tops
with xvlog/xvhdl, then for each configuration elaborates a testbench that
drives the Verilog top and the VHDL top side by side and checks every result
against the bit-exact oracle (tests/vivado/gen_vectors.py):

  * tb_fp_unit_tops: fp_unit_top.v + fp_unit_vhd.vhd, streaming requests
    with random gaps, in_ready backpressure, out-of-order completion by tag;
  * tb_fp_unit_axilite_tops: fp_unit_axilite_top.v + fp_unit_axilite_vhd.vhd
    through an AXI4-Lite master.

Needs Vivado (xvlog/xvhdl/xelab/xsim): on PATH, or found via VIVADO_SETTINGS
(path to settings64.sh; default /media/lfs/2026.1.1/Vivado/settings64.sh).

Usage:
    uv run python tests/vivado/run_xsim.py            # default matrix
    uv run python tests/vivado/run_xsim.py --quick    # binary32 only
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
HERE = Path(__file__).resolve().parent
BUILD = ROOT / "xsim_build"
SETTINGS = os.environ.get("VIVADO_SETTINGS", "/media/lfs/2026.1.1/Vivado/settings64.sh")

sys.path.insert(0, str(ROOT / "tests"))
from rtl_files import rtl_files  # noqa: E402

# (tb, W_EXP, W_MANT, DIVSQRT_IMPL, OPS_EN, N)
MATRIX = [
    ("tb_fp_unit_tops", 8, 23, 1, 0xFFFF, 3000),
    ("tb_fp_unit_tops", 8, 23, 3, 0xFFFF, 3000),
    ("tb_fp_unit_tops", 8, 23, 2, 0xFFFF, 1500),
    ("tb_fp_unit_tops", 5, 10, 1, 0xFFFF, 3000),
    ("tb_fp_unit_tops", 11, 52, 1, 0xFFFF, 1500),
    ("tb_fp_unit_tops", 8, 0, 1, 0xFFFF, 2000),
    ("tb_fp_unit_tops", 5, 10, 1, 0x8A24, 2000),   # OPS_EN subset through the generics
    ("tb_fp_unit_axilite_tops", 8, 23, 1, None, 300),
    ("tb_fp_unit_axilite_tops", 4, 3, 3, None, 300),
    ("tb_fp_unit_axilite_tops", 11, 52, 1, None, 200),
]
QUICK = [MATRIX[0], MATRIX[7]]


def sh(cmd: str, cwd: Path, log: Path) -> int:
    """Run cmd in bash with the Vivado environment; output to log."""
    prefix = "" if shutil.which("xvlog") else f"source {SETTINGS} >/dev/null; "
    env = dict(os.environ)
    env["PATH"] = "/usr/bin:/bin" + os.pathsep + env.get("PATH", "")
    with open(log, "w") as f:
        return subprocess.call(["bash", "-c", prefix + cmd], cwd=cwd, stdout=f,
                               stderr=subprocess.STDOUT, env=env)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--quick", action="store_true", help="binary32 stream + AXI only")
    args = ap.parse_args()

    BUILD.mkdir(exist_ok=True)
    files = rtl_files(wrappers=True)
    sv = [str(p) for p in files if p.suffix == ".sv"]
    sv += [str(HERE / "tb_fp_unit_tops.sv"), str(HERE / "tb_fp_unit_axilite_tops.sv")]
    v = [str(p) for p in files if p.suffix == ".v"]
    vhd = [str(ROOT / line.split("#")[0].strip())
           for line in (ROOT / "rtl" / "filelist_vhdl.f").read_text().splitlines()
           if line.split("#")[0].strip()]

    print("compiling (xvlog -sv, xvlog, xvhdl) ...", flush=True)
    rc = sh(f"xvlog -sv {' '.join(sv)} && xvlog {' '.join(v)} && xvhdl {' '.join(vhd)}",
            BUILD, BUILD / "compile.log")
    if rc != 0:
        print(f"COMPILE FAILED (see {BUILD / 'compile.log'})")
        return 1

    ok = True
    for tb, we, wm, impl, ops_en, n in (QUICK if args.quick else MATRIX):
        tag = f"{tb}_{we}x{wm}_ds{impl}" + (f"_ops{ops_en:04x}" if ops_en not in (None, 0xFFFF) else "")
        vec = BUILD / f"{tag}.vec"
        gen = [sys.executable, str(HERE / "gen_vectors.py"), str(we), str(wm), str(n), str(vec)]
        if ops_en is not None:
            gen += ["--ops-en", hex(ops_en)]
        subprocess.check_call(gen)
        generics = [f"W_EXP={we}", f"W_MANT={wm}", f"DIVSQRT_IMPL={impl}", f"N={n}"]
        if ops_en is not None:
            generics.append(f"OPS_EN={ops_en}")
        gtop = " ".join(f"-generic_top {g}" for g in generics)
        log = BUILD / f"{tag}.log"
        rc = sh(f"xelab {tb} {gtop} -s {tag} -timescale 1ns/1ps -nolog && "
                f"xsim {tag} -R -testplusarg VEC={vec} -nolog", BUILD, log)
        text = log.read_text(errors="replace")
        line = next((ln for ln in text.splitlines() if ln.startswith("XSIM ")), None)
        passed = rc == 0 and line is not None and line.endswith("PASS")
        ok = ok and passed
        print(line if line else f"{tag}: NO RESULT (rc={rc}, see {log})", flush=True)
        if not passed:
            for ln in text.splitlines():
                if "ERROR" in ln:
                    print("   ", ln)
    print("ALL XSIM TOPS PASS" if ok else "SOME XSIM TOPS FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
