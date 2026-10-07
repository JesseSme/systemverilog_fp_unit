# SRT div/sqrt verification

Two layers protect the `fp_div_srt` / `fp_sqrt_srt` pipelines:

1. **Reference models** (pure Python, bit-level recurrence + selection):
   * `div_model.py`  — radix-4 SRT division: QST derivation/validation,
     carry-save integer model, on-the-fly Q/QM, random + exact + near-exact
     vectors for every width.
   * `sqrt_model.py` — radix-4 SRT sqrt: carry-save integer model with the
     `round(p/(8q))` threshold selection, random + exact-square vectors.
   Run: `python3 verification/srt/div_model.py` and
   `python3 verification/srt/sqrt_model.py` (both print `TOTAL 0 PASS`).

2. **Streaming RTL differential** (`run_diff.py` + the `*_diff_top.sv` /
   `*_diff_main.cpp` harnesses): drives `fp_div_srt` / `fp_sqrt_srt` with one
   start per cycle and compares each result against the combinational
   `fp_div` / `fp_sqrt` on the operands that started it (FIFO-tracked).
   This is the check that found the multi-driven reset, the unsigned-cast
   and the radicand-slice bugs.
   Run: `uv run python verification/srt/run_diff.py`
   (default: 7 formats x 300k vectors; `--width W_EXP W_MANT --vectors N`
   for a single format).

These are development/verification harnesses; the canonical regression is
still `make regress` / `make exhaustive-iter` / `make soak-iter` through
`fp_unit`.
