# Convenience wrappers around the cocotb runner and the verification harnesses.

SIM ?= verilator

# oss-cad-suite provides SymbiYosys (sby) + Yosys for formal verification.
OSS ?= /home/jesse/Documents/oss-cad-suite-linux-x64-20260813/oss-cad-suite

.PHONY: regress regress-all regress-axilite smoke soak coverage formal lint clean

regress:
	uv run python tests/run_regression.py

# Full 8-width matrix (adds the odd sizes 6/16 and 10/40; ~1 s at FP_ITERS=100).
regress-all:
	uv run python tests/run_regression.py --all

# Quick smoke run: single small width, few iterations.
smoke:
	FP_ITERS=20 uv run python tests/run_regression.py --width 5 10

# AXI-Lite wrapper regression (fp_unit_axilite) across the width matrix.
regress-axilite:
	uv run python tests/run_regression.py --top fp_unit_axilite --tests test_fp_unit_axilite

# Cross-width randomized soak (binary16, BF16, E4M3 by default; tens of
# millions of vectors against the bit-exact oracle at C++ speed).
soak:
	uv run python tests/soak.py

# Verilator line/toggle coverage from a soak run (medium-width vector volume)
# plus the exhaustive all-8-bit-format sweep (which covers every edge path,
# including the E8M0 datapaths and the degenerate exponent ranges), merged and
# annotated into coverage_annotate/.
coverage:
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

lint:
	verilator --lint-only -Wall --timing rtl/fp_pkg.sv rtl/fp_add.sv rtl/fp_mul.sv rtl/fp_div.sv rtl/fp_sqrt.sv rtl/fp_fma.sv rtl/fp_minmax.sv rtl/fp_cmp.sv rtl/fp_totalorder.sv rtl/fp_roundint.sv rtl/fp_unit.sv
	verilator --lint-only -Wall --timing rtl/fp_pkg.sv rtl/fp_add_e8m0.sv
	verilator --lint-only -Wall --timing rtl/fp_pkg.sv rtl/fp_mul_e8m0.sv
	verilator --lint-only -Wall --timing rtl/fp_pkg.sv rtl/fp_div_e8m0.sv
	verilator --lint-only -Wall --timing rtl/fp_pkg.sv rtl/fp_sqrt_e8m0.sv
	verilator --lint-only -Wall --timing rtl/fp_pkg.sv rtl/fp_fma_e8m0.sv
	verilator --lint-only -Wall --timing rtl/fp_pkg.sv rtl/fp_roundint_e8m0.sv
	verilator --lint-only -Wall --timing rtl/fp_pkg.sv rtl/fp_add.sv rtl/fp_mul.sv rtl/fp_div.sv rtl/fp_sqrt.sv rtl/fp_fma.sv rtl/fp_minmax.sv rtl/fp_cmp.sv rtl/fp_totalorder.sv rtl/fp_roundint.sv rtl/fp_unit.sv rtl/fp_unit_axilite.sv

clean:
	rm -rf sim_build
