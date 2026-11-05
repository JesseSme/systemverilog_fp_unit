# Copyright 2026 Jesse Smedberg
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

# Build, test and packaging entry points (see README.md and docs/).
#
# Tools: Verilator 5.020 + uv (Python 3.13, cocotb 1.9) for simulation;
# Vivado (on PATH, e.g. via settings64.sh) for the vivado-*/xsim/ip targets;
# the oss-cad-suite (sby, yosys) for formal: on PATH, or OSS=<suite root>.

OSS ?=
SBY_PATH := $(if $(OSS),$(OSS)/bin:,)

.PHONY: help lint regress regress-all smoke regress-axilite regress-axis regress-tops regress-exp \
        exhaustive fma-equiv soak stream bf16 srt-diff coverage check-all check-iter check-ds3 \
        formal formal-equiv xsim-tops vivado vivado-top vivado-bd-check ip ip-check \
        metrics-area metrics-runtime metrics-latency metrics-compare clean

help:
	@echo "Simulation (Verilator, uv):"
	@echo "  lint            Verilator -Wall over the core, wrappers and tops"
	@echo "  regress         cocotb regression, default format matrix (regress-all: 8 formats)"
	@echo "  regress-axilite / regress-axis / regress-tops   wrapper and Verilog-top suites"
	@echo "  exhaustive      every operand pair x rounding mode x opcode, all 8-bit formats"
	@echo "  fma-equiv       FMA pipeline vs combinational FMA: every (rm,a,b,c), 8-bit formats; random, wider"
	@echo "  soak | stream | bf16 | regress-exp | srt-diff | coverage"
	@echo "  check-all       lint + all of the above for the default build"
	@echo "  check-iter / check-ds3   the main suites for DIVSQRT_IMPL=2 / 3"
	@echo "Formal (SymbiYosys): formal, formal-equiv"
	@echo "Vivado: vivado, vivado-top, vivado-bd-check, xsim-tops, ip, ip-check"

# ------------------------------------------------------------------ lint
RTL   := $(shell grep -v '^\#' rtl/filelist.f)
WRAP  := $(shell grep -v '^\#' rtl/filelist_wrappers.f)
VLINT := verilator --lint-only -Wall --timing

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
	$(VLINT) --top-module jsm_fp_unit_axilite $(RTL) $(WRAP)
	$(VLINT) --top-module jsm_fp_unit_axis $(RTL) $(WRAP)
	$(VLINT) --top-module jsm_fp_unit_axis -GW_EXP=11 -GW_MANT=52 -GDIVSQRT_IMPL=3 -GTUSER_W=8 $(RTL) $(WRAP)
	$(VLINT) --top-module jsm_fp_unit_axis -GW_EXP=8 -GW_MANT=0 -GDEPTH=3 $(RTL) $(WRAP)
	$(VLINT) --top-module jsm_fp_unit_top $(RTL) $(WRAP)
	$(VLINT) --top-module jsm_fp_unit_top -GW_EXP=11 -GW_MANT=52 -GTAG_W=4 -GOPS_EN=39 -GDIVSQRT_IMPL=3 $(RTL) $(WRAP)
	$(VLINT) --top-module jsm_fp_unit_axilite_top $(RTL) $(WRAP)
	$(VLINT) --top-module jsm_fp_unit_axis_top $(RTL) $(WRAP)
	$(VLINT) -Wno-VARHIDDEN --top-module jsm_fp_exp_seq $(RTL) $(WRAP)
	$(VLINT) --top-module fp_unit_timing $(RTL) syn/fp_unit_timing.sv
	$(VLINT) rtl/jsm_fp32_to_bf16_round.sv
	$(VLINT) rtl/jsm_fp_pkg.sv rtl/jsm_fp_add_e8m0.sv
	$(VLINT) rtl/jsm_fp_pkg.sv rtl/jsm_fp_mul_e8m0.sv
	$(VLINT) rtl/jsm_fp_pkg.sv rtl/jsm_fp_div_e8m0.sv
	$(VLINT) rtl/jsm_fp_pkg.sv rtl/jsm_fp_sqrt_e8m0.sv
	$(VLINT) rtl/jsm_fp_pkg.sv rtl/jsm_fp_fma_e8m0.sv
	$(VLINT) rtl/jsm_fp_pkg.sv rtl/jsm_fp_roundint_e8m0.sv

# ------------------------------------------------------------------ simulation
# FP_DIVSQRT_IMPL=<0..3> selects the div/sqrt build for the cocotb targets.
regress:
	uv run python tests/run_regression.py

regress-all:
	uv run python tests/run_regression.py --all

smoke:
	FP_ITERS=20 uv run python tests/run_regression.py --width 5 10

regress-axilite:
	uv run python tests/run_regression.py --all --top jsm_fp_unit_axilite --tests test_fp_unit_axilite

regress-axis:
	uv run python tests/run_regression.py --all --top jsm_fp_unit_axis --tests test_fp_unit_axis

# the cocotb suites through the Verilog-2001 tops (same ports as the SV cores)
regress-tops:
	uv run python tests/run_regression.py --all --top jsm_fp_unit_top
	uv run python tests/run_regression.py --all --top jsm_fp_unit_axilite_top --tests test_fp_unit_axilite
	uv run python tests/run_regression.py --all --top jsm_fp_unit_axis_top --tests test_fp_unit_axis

regress-exp:
	uv run python tests/run_regression.py --top jsm_fp_exp_seq --tests test_fp_exp_seq --width 8 23 --timeout 600

exhaustive:
	uv run python tests/exhaustive.py

fma-equiv:
	uv run python tests/fma_equiv.py

soak:
	uv run python tests/soak.py

stream:
	uv run python tests/stream.py
	uv run python tests/stream.py --width 8 23 --width 8 0 --ops-en 0x8a24 --vectors 50000

bf16:
	uv run python tests/bf16.py

srt-diff:
	uv run python verification/srt/run_diff.py
	uv run python verification/srt/run_diff.py --param DPS=1 --param FOLD_STG=1

check-all: lint regress-all regress-axilite regress-axis regress-tops regress-exp exhaustive fma-equiv soak stream srt-diff

check-iter:
	FP_DIVSQRT_IMPL=2 uv run python tests/run_regression.py --all
	FP_DIVSQRT_IMPL=2 uv run python tests/run_regression.py --top jsm_fp_unit_axis --tests test_fp_unit_axis
	uv run python tests/exhaustive.py --divsqrt 2
	uv run python tests/soak.py --divsqrt 2
	uv run python tests/stream.py --param DIVSQRT_IMPL=2 --allow-stall div sqrt

check-ds3:
	FP_DIVSQRT_IMPL=3 uv run python tests/run_regression.py --all
	FP_DIVSQRT_IMPL=3 uv run python tests/run_regression.py --top jsm_fp_unit_axis --tests test_fp_unit_axis
	FP_DIVSQRT_IMPL=3 uv run python tests/run_regression.py --top jsm_fp_unit_axilite --tests test_fp_unit_axilite
	uv run python tests/exhaustive.py --divsqrt 3
	uv run python tests/soak.py --divsqrt 3
	uv run python tests/stream.py --param DIVSQRT_IMPL=3

# Line coverage from a soak and the exhaustive sweep (old coverage.dat files
# are removed first, so directories this target does not rerun cannot mix in
# stale line numbers).
coverage:
	rm -f soak_build/*/coverage.dat exhaustive_build/*/coverage.dat
	uv run python tests/soak.py --vectors 1000000
	uv run python tests/soak.py --width 8 0 --vectors 1000000
	uv run python tests/exhaustive.py
	verilator_coverage -write coverage.dat soak_build/*/coverage.dat exhaustive_build/*/coverage.dat
	verilator_coverage -write-info coverage.info coverage.dat
	verilator_coverage --annotate coverage_annotate --rank coverage.dat

# ------------------------------------------------------------------ formal
FORMAL_PROPS := bmc_m6_b16 bmc_m6_e4m3 bmc_m6_e7m0 bmc_arith_e4m3 bmc_arith_e5m2 \
                bmc_div_e4m3 bmc_div_e5m2 bmc_div_b16
FORMAL_EQUIV := bmc_equiv_add_e4m3 bmc_equiv_mul_e4m3 bmc_equiv_fma_e4m3 bmc_equiv_fma_e5m2 \
                bmc_equiv_fma_bf16 \
                bmc_equiv_add_bf16 bmc_equiv_mul_bf16 bmc_equiv_add_b16 bmc_equiv_mul_b16

# property proofs of the combinational datapaths (formal/*_props.sv)
formal:
	@export PATH="$(SBY_PATH)$$PATH"; for f in $(FORMAL_PROPS); do \
	  echo "=== $$f ==="; (cd formal && sby -f $$f.sby) || exit 1; done

# add/mul/fma pipelines == combinational references (formal/fp_pipe_equiv.sv);
# binary16 mul takes ~13 min
formal-equiv:
	@export PATH="$(SBY_PATH)$$PATH"; for f in $(FORMAL_EQUIV); do \
	  echo "=== $$f ==="; (cd formal && sby -f $$f.sby) || exit 1; done

# ------------------------------------------------------------------ Vivado
VIVADO_ARGS ?= 5.600 8 23 1
TOP_ARGS    ?= jsm_fp_unit_vhd 5.600 W_EXP=8 W_MANT=23
VIVADO      := vivado -mode batch -nojournal -nolog

# OOC implementation of jsm_fp_unit, I/O registered: period W_EXP W_MANT DIVSQRT_IMPL
vivado:
	$(VIVADO) -source syn/vivado-impl.tcl -tclargs $(VIVADO_ARGS)

# OOC implementation with a Verilog/VHDL top as the design top
vivado-top:
	$(VIVADO) -source syn/vivado-top.tcl -tclargs $(TOP_ARGS)

# block-design module references of the Verilog/VHDL tops
vivado-bd-check:
	$(VIVADO) -source syn/vivado-bd-check.tcl

# Verilog and VHDL tops side by side in xsim against the oracle
xsim-tops:
	uv run python tests/vivado/run_xsim.py

# package the IP cores into ip_repo/ (IP catalog), and check them
ip:
	$(VIVADO) -source syn/package_ip.tcl

ip-check:
	$(VIVADO) -source syn/ip_check.tcl

# ------------------------------------------------------------------ metrics
metrics-area:
	uv run python tests/metrics.py --area --out metrics/area.json

metrics-runtime:
	uv run python tests/metrics.py --runtime --out metrics/runtime.json

metrics-latency:
	uv run python tests/latency.py --json metrics/latency.json

# make metrics-compare BEFORE=metrics/a.json AFTER=metrics/b.json
metrics-compare:
	uv run python tests/metrics.py --compare $(BEFORE) $(AFTER)

clean:
	rm -rf sim_build exhaustive_build fma_equiv_build soak_build latency_build stream_build bf16_build \
	       srt_diff_build xsim_build ip_repo syn/out coverage.dat coverage.info coverage_annotate
