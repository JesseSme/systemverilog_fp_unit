# SRT div/sqrt verification

Two layers protect the `jsm_fp_div_srt` / `jsm_fp_sqrt_srt` pipelines:

1. **Reference models** (pure Python, bit-level recurrence + selection):
   * `div_model.py`  — radix-4 SRT division: QST derivation/validation,
     carry-save integer model, on-the-fly Q/QM, random + exact + near-exact
     vectors for every width.
   * `sqrt_model.py` — radix-4 SRT sqrt: carry-save integer model with the
     `round(p/(8q))` threshold selection, random + exact-square vectors.
   Run: `python3 verification/srt/div_model.py` and
   `python3 verification/srt/sqrt_model.py` (both print `TOTAL 0 PASS`).
   Both models also run the RTL's **fixed-width carry-save** form: S and C
   kept modulo 2^CSW with no carry-propagate fold between digits (the
   recurrence is linear, so S+C stays congruent to the residual; the
   estimate window and the final residual fit in CSW bits).
   `div_model.py` checks CSW = S_W+4 (the minimum: S_W+3 fails) exhaustively
   for S_W <= 11; `sqrt_model.py` has an RTL-shaped model (`run_rtl`:
   the RTL's `est_pe` window, `thr_digit` selection and the adder-free
   two-level CSA update) and checks CSW = 2*NDIG+5, EW = 12 exhaustively for
   S_W <= 12 plus random wide formats, and asserts the 6-bit qs / 13-bit
   compare ranges the RTL relies on.

2. **Streaming RTL differential** (`run_diff.py` + the `*_diff_top.sv` /
   `*_diff_main.cpp` harnesses): drives `jsm_fp_div_srt` / `jsm_fp_sqrt_srt` with one
   start per cycle and compares each result against the combinational
   `jsm_fp_div` / `jsm_fp_sqrt` on the operands that started it (FIFO-tracked).
   This is the check that found the multi-driven reset, the unsigned-cast
   and the radicand-slice bugs.
   Run: `uv run python verification/srt/run_diff.py`
   (default: 7 formats x 300k vectors; `--width W_EXP W_MANT --vectors N`
   for a single format; `--param DPS=1 --param FOLD_STG=1` etc. for the
   module parameters: DPS digits per stage, STAGE_FOLD fold at every stage
   boundary, FOLD_STG register after the final fold). At DPS=2 and 5M
   vectors this found the sqrt digit-select counter overflow (digit +4
   returned as -4). The directed binary64 vectors from that run pass on
   the old jsm_fp_unit (sqrt at DPS=1 with a fold before every digit, so the
   estimate there was exact), so the bug was not observed through jsm_fp_unit.

These are development/verification harnesses; the canonical regression is
still `make regress` / `make exhaustive` / `make check-iter` through
`jsm_fp_unit`.
