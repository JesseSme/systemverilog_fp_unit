# jsm_fp_unit: IEEE 754-2019 floating-point unit

A parameterized, fully pipelined floating-point unit in synthesizable
SystemVerilog, with Verilog-2001 and VHDL tops, AXI4-Stream and AXI4-Lite
interfaces, and packaged Vivado IP.

- Any binary format `1 + W_EXP + W_MANT` bits: binary16/32/64, bfloat16,
  8-bit E4M3/E5M2, odd sizes, and a sign + exponent power-of-two format.
- 16 operations: add, sub, mul, div, sqrt, fused multiply-add, min/max,
  quiet comparison, roundToIntegral (and Exact), totalOrder,
  copy/negate/abs/copySign, class, nextUp/nextDown, the minimumNumber
  family.
- All five rounding modes and exception flags, subnormals in and out;
  bit-exact against a Python reference model of IEEE 754-2019.
- One operation per cycle with fixed latencies (binary32: add 3, mul 4,
  fma 4, div 9, sqrt 15 cycles) at 5.6-5.8 ns, or at 4.0 ns (250 MHz) with
  `DIVSQRT_IMPL = 3` (div 17, sqrt 16), on a Virtex UltraScale+ -2L; no DSPs,
  no block RAM.

| interface | for | top-level files |
|-----------|-----|-----------------|
| AXI4-Stream | hardware datapaths, DMA (backpressure, results in order) | `rtl/jsm_fp_unit_axis.sv`, `rtl/top/jsm_fp_unit_axis_top.v`, `rtl/top/jsm_fp_unit_axis_vhd.vhd` |
| AXI4-Lite | software access from a processor | `rtl/jsm_fp_unit_axilite.sv`, `rtl/top/jsm_fp_unit_axilite_top.v`, `rtl/top/jsm_fp_unit_axilite_vhd.vhd` |
| native | lowest latency, tagged results | `rtl/jsm_fp_unit.sv`, `rtl/top/jsm_fp_unit_top.v`, `rtl/top/jsm_fp_unit_vhd.vhd` |

## Documentation

- [docs/user_guide.md](docs/user_guide.md): integration guide and
  reference: parameters, ports and timing, latencies, operations and
  special values, formats, register map, Vivado IP and file lists,
  resources, tool support.
- [docs/architecture.md](docs/architecture.md): design and verification
  specification for maintainers: microarchitecture, test harnesses, coding
  rules for tool compatibility, how to add an operation, future work.

## Quick start (Vivado)

```
make ip                 # packages jsm:fpu:jsm_fp_unit_axis / _axilite / jsm_fp_unit into ip_repo/
```

Add `ip_repo/` to the project's IP repositories and add the core from the
IP catalog, or add the source files listed in the user guide (section 9.2)
and instantiate a Verilog or VHDL top.

## Repository layout

    rtl/                SystemVerilog core (jsm_fp_unit.sv and datapaths), AXI wrappers,
                        file lists (filelist.f, filelist_wrappers.f, filelist_vhdl.f)
    rtl/top/            Verilog-2001 and VHDL tops
    docs/               user guide, architecture specification
    tests/              cocotb suites, C++ Verilator harnesses, reference model
                        (tests/reference/), Vivado xsim testbenches (tests/vivado/)
    verification/srt/   SRT div/sqrt models and module differential
    formal/             SymbiYosys proofs
    syn/                Vivado scripts: implementation, tops, block design, IP packaging
    metrics/            reference Vivado reports

## Running the tests

Requirements: Verilator 5.020, [uv](https://docs.astral.sh/uv/) (installs
Python 3.13 and cocotb 1.9), GNU make; optionally Vivado and the
oss-cad-suite.

    uv sync
    make help               # all targets
    make lint               # Verilator -Wall
    make regress-all        # cocotb regression, 8 formats
    make exhaustive         # every operand pair, rounding mode and opcode, 8-bit formats
    make check-all          # lint + all simulation suites (default build)
    make formal             # SymbiYosys proofs (oss-cad-suite)
    make xsim-tops ip-check # Vivado: Verilog/VHDL tops in xsim, packaged IP

## License

Copyright 2026 Jesse Smedberg. Licensed under the Solderpad Hardware
License v2.1 ([LICENSE](LICENSE); SPDX `Apache-2.0 WITH SHL-2.1`).
Distributions of the core or of designs and products derived from it must
include the attribution in [NOTICE](NOTICE); see the user guide, section 14.
