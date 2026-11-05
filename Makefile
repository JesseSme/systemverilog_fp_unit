# Convenience wrappers around the cocotb runner and the verification harnesses.

SIM ?= verilator

# oss-cad-suite provides SymbiYosys (sby) + Yosys for formal verification.
OSS ?= /home/jesse/Documents/oss-cad-suite-linux-x64-20260813/oss-cad-suite

.PHONY: regress regress-all regress-axilite smoke soak coverage formal formal-equiv check-ds3 regress-tops xsim-tops vivado-bd-check vivado-top lint bf16 stream regress-exp vivado \
        exhaustive-iter soak-iter stream-iter regress-axilite-iter \
        metrics-area metrics-runtime metrics-latency metrics-compare clean

regress:
	uv run python tests/run_regression.py

# Full 8-width matrix (adds the odd sizes 6/16 and 10/40; ~1 s at FP_ITERS=100).
regress-all:
	uv run python tests/run_regression.py --all

# Quick smoke run: single small width, few iterations.
smoke:
	FP_ITERS=20 uv run python tests/run_regression.py --width 5 10

# AXI-Lite wrapper regression (jsm_fp_unit_axilite) across the width matrix.
regress-axilite:
	uv run python tests/run_regression.py --top jsm_fp_unit_axilite --tests test_fp_unit_axilite

# jsm_fp_exp_seq (fp32 exp sequencer on two jsm_fp_unit instances): accuracy vs
# math.exp within a measured ULP bound, clamp/special behaviour.
regress-exp:
	uv run python tests/run_regression.py --top jsm_fp_exp_seq --tests test_fp_exp_seq --width 8 23 --timeout 600

# jsm_fp32_to_bf16_round: oracle records + exhaustive 2^32 sweep (~1.5 min).
bf16:
	uv run python tests/bf16.py

# Streaming / mixed-issue test: a request every cycle, results matched by tag
# (same-op back-to-back per pipeline + mixed ops through the in_ready
# backpressure), binary16/BF16/E4M3/binary32.
stream:
	uv run python tests/stream.py
	uv run python tests/stream.py --width 8 23 --width 8 0 --ops-en 0x8a24 --vectors 50000

# Iterative div/sqrt engine (jsm_fp_unit DIVSQRT_IMPL=2, the 250 MHz build):
# exhaustive 8-bit sweep, medium-width soak, streaming test and the AXI-Lite
# handshake. (DIVSQRT_IMPL=1, the SRT pipelines, is the default everywhere.)
exhaustive-iter:
	uv run python tests/exhaustive.py --iter

soak-iter:
	uv run python tests/soak.py --iter

stream-iter:
	uv run python tests/stream.py --param DIVSQRT_IMPL=2 --allow-stall div sqrt

regress-axilite-iter:
	FP_DIVSQRT_IMPL=2 uv run python tests/run_regression.py --top jsm_fp_unit_axilite --tests test_fp_unit_axilite

# SRT pipelines in their 4.0 ns form (jsm_fp_unit DIVSQRT_IMPL=3): full cocotb
# matrix, exhaustive 8-bit sweep, soak, streaming test, plus the SRT
# module differential in that configuration.
check-ds3:
	FP_DIVSQRT_IMPL=3 uv run python tests/run_regression.py --all
	uv run python tests/exhaustive.py --divsqrt 3
	uv run python tests/soak.py --divsqrt 3
	uv run python tests/stream.py --param DIVSQRT_IMPL=3
	FP_DIVSQRT_IMPL=3 uv run python tests/run_regression.py --top jsm_fp_unit_axilite --tests test_fp_unit_axilite
	uv run python verification/srt/run_diff.py --param DPS=1 --param FOLD_STG=1

# Cross-width randomized soak (binary16, BF16, E4M3 by default; tens of
# millions of vectors against the bit-exact oracle at C++ speed).
soak:
	uv run python tests/soak.py

# Verilator line/toggle coverage from a soak run (medium-width vector volume)
# plus the exhaustive all-8-bit-format sweep (which covers every edge path,
# including the E8M0 datapaths and the degenerate exponent ranges), merged and
# annotated into coverage_annotate/.
# (old coverage.dat files are removed first: build directories this target
# does not rerun, e.g. *_iter, would otherwise merge stale line numbers.)
coverage:
	rm -f soak_build/*/coverage.dat exhaustive_build/*/coverage.dat
	uv run python tests/soak.py --vectors 1000000
	uv run python tests/soak.py --width 8 0 --vectors 1000000
	uv run python tests/exhaustive.py
	verilator_coverage -write coverage.dat soak_build/*/coverage.dat exhaustive_build/*/coverage.dat
	verilator_coverage -write-info coverage.info coverage.dat
	verilator_coverage --annotate coverage_annotate --rank coverage.dat

# Formal BMC property proofs of the M6 datapaths (comparisons, totalOrder,
# roundToIntegral) at binary16/E4M3/E7M0, plus the arithmetic-op laws
# (add/mul/fma/sqrt identities) at E4M3/E5M2 and the division laws at
# E4M3/E5M2/binary16. Needs the oss-cad-suite.
formal:
	@export PATH="$(OSS)/bin:$(PATH)"; for f in bmc_m6_b16.sby bmc_m6_e4m3.sby bmc_m6_e7m0.sby bmc_arith_e4m3.sby bmc_arith_e5m2.sby bmc_div_e4m3.sby bmc_div_e5m2.sby bmc_div_b16.sby; do \
	  echo "=== $$f ==="; sby -f $$f || exit 1; done

# Formal equivalence of the add/mul pipelines against the combinational
# jsm_fp_add / jsm_fp_mul (formal/fp_pipe_equiv.sv; plan P4.3): every operand pair
# and rounding mode, any in-flight history. E4M3, bfloat16 and binary16 add
# close in seconds; binary16 mul (two different 11x11 multiplier
# structures) takes ~13 min with bitwuzla.
formal-equiv:
	@export PATH="$(OSS)/bin:$(PATH)"; for f in bmc_equiv_add_e4m3.sby bmc_equiv_mul_e4m3.sby bmc_equiv_add_bf16.sby bmc_equiv_mul_bf16.sby bmc_equiv_add_b16.sby bmc_equiv_mul_b16.sby; do \
	  echo "=== $$f ==="; sby -f $$f || exit 1; done

# Area/timing proxies (Yosys synth + stat + ltp) and target runtimes; see
# tests/metrics.py. Collect a baseline before optimizing and compare after.
metrics-area:
	uv run python tests/metrics.py --area --out metrics/area-baseline.json

metrics-runtime:
	uv run python tests/metrics.py --runtime --out metrics/runtime-baseline.json

# Per-op latency probe (cycles from in_valid to out_valid, per format).
metrics-latency:
	uv run python tests/latency.py --json metrics/latency-after.json

# Deltas between two metrics JSON files, e.g.
#   make metrics-compare BEFORE=metrics/area-baseline.json AFTER=metrics/area-after.json
metrics-compare:
	uv run python tests/metrics.py --compare $(BEFORE) $(AFTER)

# RTL file lists: rtl/filelist.f (jsm_fp_unit + datapaths) and
# rtl/filelist_wrappers.f (jsm_fp_unit_axilite, jsm_fp32_to_bf16_round, jsm_fp_exp_seq,
# and the Verilog tops in rtl/top/); rtl/filelist_vhdl.f has the VHDL tops.
RTL  := $(shell grep -v '^\#' rtl/filelist.f)
WRAP := $(shell grep -v '^\#' rtl/filelist_wrappers.f)
VLINT := verilator --lint-only -Wall --timing

# Vivado OOC implementation (needs vivado on PATH; not run by default):
#   make vivado                      -> 5.600 ns, binary32, SRT div/sqrt
#   make vivado VIVADO_ARGS="4.000 8 23 2"   -> 250 MHz iterative build
VIVADO_ARGS ?= 5.600 8 23 1
vivado:
	@command -v vivado >/dev/null || { echo "vivado not on PATH; run: vivado -mode batch -source syn/vivado-impl.tcl -tclargs $(VIVADO_ARGS)"; exit 1; }
	vivado -mode batch -nojournal -nolog -source syn/vivado-impl.tcl -tclargs $(VIVADO_ARGS)

# Verilog/VHDL tops (rtl/top/, docs/fp_unit_core.md):
#   regress-tops      cocotb suites through the Verilog-2001 tops (Verilator)
#   xsim-tops         Verilog + VHDL tops side by side in Vivado xsim vs the oracle
#   vivado-bd-check   block-design module references of all four tops
#   vivado-top        OOC implementation with a top, e.g.
#                     make vivado-top TOP_ARGS="jsm_fp_unit_vhd 5.600 W_EXP=8 W_MANT=23"
TOP_ARGS ?= jsm_fp_unit_vhd 5.600 W_EXP=8 W_MANT=23
regress-tops:
	uv run python tests/run_regression.py --all --top jsm_fp_unit_top
	uv run python tests/run_regression.py --all --top jsm_fp_unit_axilite_top --tests test_fp_unit_axilite

xsim-tops:
	uv run python tests/vivado/run_xsim.py

vivado-bd-check:
	vivado -mode batch -nojournal -nolog -source syn/vivado-bd-check.tcl

vivado-top:
	vivado -mode batch -nojournal -nolog -source syn/vivado-top.tcl -tclargs $(TOP_ARGS)

# (jsm_fp_exp_seq line: Verilator 5.020 reports a false VARHIDDEN, its port `x`
# "hidden" by function arguments named x inside the pruned jsm_fp_unit
# pipelines, which are different modules.)
lint:
	$(VLINT) --top-module jsm_fp_unit $(RTL)
	$(VLINT) --top-module jsm_fp_unit -GDIVSQRT_IMPL=0 $(RTL)
	$(VLINT) --top-module jsm_fp_unit -GDIVSQRT_IMPL=2 $(RTL)
	$(VLINT) --top-module jsm_fp_unit -GDIVSQRT_IMPL=2 -GW_EXP=11 -GW_MANT=52 $(RTL)
	$(VLINT) --top-module jsm_fp_unit -GDIVSQRT_IMPL=3 $(RTL)
	$(VLINT) --top-module jsm_fp_unit -GDIVSQRT_IMPL=3 -GW_EXP=11 -GW_MANT=52 $(RTL)
	$(VLINT) --top-module jsm_fp_unit -GDIVSQRT_IMPL=3 -GW_EXP=4 -GW_MANT=3 $(RTL)
	$(VLINT) --top-module jsm_fp_unit -GW_EXP=11 -GW_MANT=52 $(RTL)
	$(VLINT) --top-module jsm_fp_unit -GW_EXP=8 -GW_MANT=0 $(RTL)
	$(VLINT) --top-module jsm_fp_unit_axilite $(RTL) rtl/jsm_fp_unit_axilite.sv
	$(VLINT) --top-module jsm_fp_unit_top $(RTL) $(WRAP)
	$(VLINT) --top-module jsm_fp_unit_top -GW_EXP=11 -GW_MANT=52 -GTAG_W=4 -GOPS_EN=39 -GDIVSQRT_IMPL=3 $(RTL) $(WRAP)
	$(VLINT) --top-module jsm_fp_unit_axilite_top $(RTL) $(WRAP)
	$(VLINT) -Wno-VARHIDDEN --top-module jsm_fp_exp_seq $(RTL) rtl/jsm_fp_exp_seq.sv
	$(VLINT) --top-module fp_unit_timing $(RTL) syn/fp_unit_timing.sv
	$(VLINT) rtl/jsm_fp32_to_bf16_round.sv
	$(VLINT) rtl/jsm_fp_pkg.sv rtl/jsm_fp_add_e8m0.sv
	$(VLINT) rtl/jsm_fp_pkg.sv rtl/jsm_fp_mul_e8m0.sv
	$(VLINT) rtl/jsm_fp_pkg.sv rtl/jsm_fp_div_e8m0.sv
	$(VLINT) rtl/jsm_fp_pkg.sv rtl/jsm_fp_sqrt_e8m0.sv
	$(VLINT) rtl/jsm_fp_pkg.sv rtl/jsm_fp_fma_e8m0.sv
	$(VLINT) rtl/jsm_fp_pkg.sv rtl/jsm_fp_roundint_e8m0.sv

clean:
	rm -rf sim_build
