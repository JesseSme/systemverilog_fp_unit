"""Single source of truth for the RTL file lists used by every harness.

The lists live in rtl/filelist.f (fp_unit and its datapaths, in compile
order) and rtl/filelist_wrappers.f (wrappers/users of fp_unit). Paths in the
.f files are relative to the repository root; blank lines and '#' comments
are ignored.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _read(name: str) -> list[Path]:
    out = []
    for line in (ROOT / "rtl" / name).read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            out.append(ROOT / line)
    return out


def rtl_files(wrappers: bool = False) -> list[Path]:
    """fp_unit + datapaths; with wrappers=True also the wrapper modules."""
    files = _read("filelist.f")
    if wrappers:
        files += _read("filelist_wrappers.f")
    return files


def rtl_paths(wrappers: bool = False) -> list[str]:
    """rtl_files() as plain strings (for subprocess command lines)."""
    return [str(p) for p in rtl_files(wrappers)]
