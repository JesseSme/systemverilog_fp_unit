# Convenience wrappers around the cocotb runner and the verification harnesses.

SIM ?= verilator

# oss-cad-suite provides SymbiYosys (sby) + Yosys for formal verification.
OSS ?= /home/jesse/Documents/oss-cad-suite-linux-x64-20260813/oss-cad-suite

.PHONY: regress regress-all smoke soak formal lint clean

regress:
	uv run python tests/run_regression.py

# Full 6-width matrix (slow: ~1.5-2 h on this toolchain).
regress-all:
	uv run python tests/run_regression.py --all

# Quick smoke run: single small width, few iterations.
smoke:
	FP_ITERS=20 uv run python tests/run_regression.py --width 5 10

# Cross-width randomized soak (binary16, BF16, E4M3 by default; tens of
# millions of vectors against the bit-exact oracle at C++ speed).
soak:
	uv run python tests/soak.py

# Formal BMC property proofs of the M6 datapaths (comparisons, totalOrder,
# roundToIntegral) at binary16, E4M3 and E7M0. Needs the oss-cad-suite.
formal:
	@export PATH="$(OSS)/bin:$(PATH)"; for f in bmc_m6_b16.sby bmc_m6_e4m3.sby bmc_m6_e7m0.sby; do \
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
