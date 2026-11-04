# Design notes: operations not yet implemented (plan section 3.3)

These are proposals only; nothing here is implemented. Each note covers the
opcode or interface change, the latency and an area estimate. The area
figures are post-route Vivado 2026.1.1 LUT counts of existing `fp_unit`
blocks (binary32, xcvu9p-2L, `DIVSQRT_IMPL = 1`, 5.6 ns,
`syn/vivado-impl.tcl` hierarchical report, 2026-11-04), scaled by the
similarity of the new datapath:

| block (binary32)     | LUTs  | FFs  |
|----------------------|------:|-----:|
| fp_sqrt_srt          | 4,584 | 1,383 |
| fp_div_srt           | 3,031 |   900 |
| fp_fma_pipe          | 2,834 |   924 |
| fp_add_pipe          | 1,072 |   225 |
| fp_mul_pipe          |   954 |   441 |
| fp_roundint_pipe     |   442 |   121 |
| fp_misc_pipe         |   294 |    34 |
| fp_minmax_pipe       |   150 |    34 |
| fp_cmp_pipe          |   114 |     4 |
| fp_unit total        | 13,514 | 4,086 |

| note | operations (IEEE 754-2019 clause) | new opcodes |
|------|-----------------------------------|-------------|
| [01-signaling-compare.md](01-signaling-compare.md) | compareSignaling* (5.6.1) | 1 |
| [02-integer-conversions.md](02-integer-conversions.md) | convertFromInt, convertToInteger*, convertToIntegerExact* (5.4.1, 5.8) | 4 |
| [03-format-conversions.md](03-format-conversions.md) | convertFormat (5.4.2) | 2 |
| [04-scaleb-logb.md](04-scaleb-logb.md) | scaleB, logB (5.3.3) | 2 |
| [05-remainder.md](05-remainder.md) | remainder (5.3.1) | 1 |

## Shared decision: the opcode space is full

`fp_pkg::op_t` is 4 bits and all 16 codes are used (OP_SGNJ .. OP_RNDINTX
took the last five). Every note below needs new codes, so the first change,
common to all of them, is:

- Widen `op_t` (and the `mode` port) to 5 bits. Codes 0-15 keep their
  values, so existing callers that drive a 4-bit value zero-extended see no
  change. `OPS_EN` becomes `logic [31:0]` (default all ones); codes 16-31
  that have no datapath stay reserved (`y = 0`, invalid, as today).
- AXI-Lite OPCODE register: put `op[4]` in bit 7 (`[3:0] op[3:0]`, `[6:4]
  rm`, `[7] op[4]`). Bit 7 is unused today, so the register map stays
  binary-compatible with existing software.
- Python side: `tests/reference/formats.py` OP table and `NUM_OPS`, and the
  exhaustive/soak harnesses' `-DNUM_OPS` (the C++ harnesses loop over
  `NUM_OPS`, so the sweep grows to 32 x 2^16 x 5 vectors per 8-bit format,
  about 10.5 M; it runs in about twice the current time).
- Cost: `lat_sel`, `op_reserved` and the result mux grow by one select bit
  (a few LUTs); timing is unaffected (these are not on critical paths).

The non-rounding ops already take their variant from `rm` (OP_SGNJ,
OP_NEXT, OP_MINMAXNUM). That trick is not available for anything that
rounds, which is why most notes need real opcodes.

Recommended order: 01 (smallest, fixes a conformance gap), 04, 02, 03, 05.
