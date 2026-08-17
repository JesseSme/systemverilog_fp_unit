# Convenience wrappers around the cocotb runner and the verification harnesses.

SIM ?= verilator

# oss-cad-suite provides SymbiYosys (sby) + Yosys for formal verification.
OSS ?= /home/jesse/Documents/oss-cad-suite-linux-x64-20260813/oss-cad-suite

.PHONY: regress regress-all smoke soak coverage formal lint clean

regress:
	uv run python tests/run_regression.py

# Full 8-width matrix (adds the odd sizes 6/16 and 10/40; ~1 s at FP_ITERS=100).
regress-all:
	uv run python tests/run_regression.py --all

# Quick smoke run: single small width, few iterations.
smoke:
	FP_ITERS=20 uv run python tests/run_regression.py --width 5 10

# Cross-width randomized soak (binary16, BF16, E4M3 by default; tens of
# millions of vectors against the bit-exact oracle at C++ speed).
soak:
	uv run python tests/soak.py

# Verilator line/toggle coverage from a soak run (medium-width vector volume),
# merged and annotated into coverage_annotate/ with a per-function summary.
coverage:
	uv run python tests/soak.py --vectors 1000000
	verilator_coverage -write coverage.dat soak_build/*/coverage.dat
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

clean:
	rm -rf sim_build
