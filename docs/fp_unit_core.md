# fp_unit: IEEE 754-2019 floating-point core

User guide and reference for integrating the core. For the
microarchitecture, verification history and development notes see
[README.md](../README.md) and [HANDOFF.md](../HANDOFF.md).

## 1. Overview

`fp_unit` is a parameterized, fully synchronous floating-point unit:

- **Any binary format** `1 sign + W_EXP exponent + W_MANT fraction bits`,
  chosen at build time: binary16/32/64, bfloat16, the 8-bit formats E4M3 and
  E5M2, odd sizes, and a sign + exponent power-of-two format (`W_MANT = 0`).
- **16 operations**: add, sub, mul, div, sqrt, fused multiply-add,
  minimum/maximum, quiet comparison, roundToIntegral (also the Exact form),
  totalOrder, the sign operations (copy/negate/abs/copySign), class,
  nextUp/nextDown and the minimumNumber family.
- **All five rounding-direction attributes** and all five exception flags,
  bit-exact against a Python reference model of IEEE 754-2019.
- **Fully pipelined**: every operation has a fixed latency and accepts a new
  request every cycle (except with the iterative div/sqrt option). Requests
  carry a tag, because results can complete out of order.
- **No DSPs, no RAMs**: LUTs and flip-flops only.

Two interfaces are provided, each in SystemVerilog, Verilog-2001 and VHDL:

| interface | SystemVerilog core | Verilog-2001 top | VHDL top |
|-----------|--------------------|------------------|----------|
| streaming (valid/ready + tag) | `rtl/fp_unit.sv` | `rtl/top/fp_unit_top.v` | `rtl/top/fp_unit_vhd.vhd` |
| AXI4-Lite slave (registers) | `rtl/fp_unit_axilite.sv` | `rtl/top/fp_unit_axilite_top.v` | `rtl/top/fp_unit_axilite_vhd.vhd` |

The Verilog and VHDL tops add no logic. They exist because a Vivado
block-design module reference, or a VHDL design, needs a Verilog or VHDL top
with plain ports. `fp_unit`'s `mode`/`rm` ports are SystemVerilog enum types,
so `rtl/top/fp_unit_flat.sv` first maps them to plain vectors.

```
fp_unit_vhd (VHDL) -> fp_unit_top (Verilog-2001) -> fp_unit_flat (SV, casts) -> fp_unit (SV)
fp_unit_axilite_vhd (VHDL) -> fp_unit_axilite_top (Verilog-2001) -> fp_unit_axilite (SV) -> fp_unit
```

## 2. Parameters

All parameters are integers in the Verilog and VHDL tops.

| parameter | default | meaning |
|-----------|---------|---------|
| `W_EXP` | 8 | exponent field width |
| `W_MANT` | 23 | fraction field width (0: power-of-two format, see 6.4) |
| `DIVSQRT_IMPL` | 1 | div/sqrt implementation, see below |
| `TAG_W` | 1 | streaming top only: request tag width, >= 1 |
| `OPS_EN` | 65535 (0xFFFF) | streaming top only: operation enable mask, bit i = opcode i |
| `ADDR_WIDTH` | 6 | AXI top only: AXI address width, >= 6 |

`DIVSQRT_IMPL`:

| value | implementation | throughput | clock (VU9P-2L, binary32) |
|-------|----------------|------------|---------------------------|
| 1 | SRT pipelines, 2 division digits per stage | 1 div/sqrt per cycle | 5.6 ns (178.6 MHz) |
| 3 | SRT pipelines, 1 digit per stage, extra fold stage | 1 div/sqrt per cycle | 4.0 ns (250 MHz) |
| 2 | iterative radix-4 engine | 1 div/sqrt in flight | 4.0 ns (250 MHz) |
| 0 | combinational reference | 1 per cycle | very slow; reference only |

`OPS_EN` removes datapaths from the build. A disabled operation behaves like
an undefined opcode: it is accepted, and after 1 cycle returns `y = 0` with
the invalid flag. Shared datapaths are built if any of their opcodes is
enabled: ADD/SUB, MIN/MAX, RNDINT/RNDINTX, and SGNJ/CLASS/NEXT/MINMAXNUM. For
example, `OPS_EN = 0x0027` (ADD, SUB, MUL, FMA) cut binary16 from 33,637 to
12,214 Yosys cells.

Verified formats (`W_EXP`, `W_MANT`): every 8-bit format (1..7, 6..0), (4,3)
E4M3, (5,2) E5M2, (5,10) binary16, (8,7) bfloat16, (6,16), (8,23) binary32,
(10,40), (11,52) binary64, and (8,0). Other widths use the same
parameterized RTL but have not been simulated.

## 3. Streaming interface (`fp_unit_top` / `fp_unit_vhd`)

### 3.1 Ports

| port | dir | width | description |
|------|-----|-------|-------------|
| `clk` | in | 1 | clock; all logic on the rising edge |
| `rst_n` | in | 1 | **synchronous**, active-low reset |
| `in_valid` | in | 1 | request valid |
| `in_ready` | out | 1 | request accepted on a rising edge with `in_valid && in_ready` |
| `mode` | in | 4 | opcode (section 5) |
| `rm` | in | 3 | rounding mode (section 5.2), or the variant of a non-rounding op |
| `a`, `b` | in | W | operands (W = 1 + W_EXP + W_MANT) |
| `c` | in | W | addend of FMA (ignored by other ops) |
| `in_tag` | in | TAG_W | request tag, returned on `out_tag` |
| `y` | out | W | result (an integer class index for CLASS, 0 for CMP/TOTALORDER) |
| `cmp` | out | 2 | comparison result (CMP, TOTALORDER), else 0 |
| `flags` | out | 5 | `{invalid, divideByZero, overflow, underflow, inexact}` |
| `out_valid` | out | 1 | one-cycle pulse per accepted request |
| `out_tag` | out | TAG_W | `in_tag` of the completing request |

### 3.2 Handshake

- A request is accepted on the rising edge where `in_valid` and `in_ready`
  are both high. While `in_valid` is high and `in_ready` is low, hold
  `mode`, `rm`, `a`, `b`, `c` and `in_tag` stable.
- `in_ready` depends combinationally on `mode` (and on internal state), never
  on `in_valid`. It drops when the requested operation would complete in the
  same cycle as an operation already in flight: all pipelines share one
  result port. With `DIVSQRT_IMPL = 2` it also drops for div/sqrt while the
  iterative engine is busy.
- Every accepted request produces exactly one `out_valid` pulse, a fixed
  number of cycles later (section 4). `y`, `cmp`, `flags` and `out_tag` are
  valid in that cycle only. There is no output backpressure: the consumer
  must take a result in the cycle it appears.
- Results return in completion order, which can differ from request order
  (an ADD issued after a SQRT finishes first). Use `out_tag` to match them.
  A caller that issues one request and waits for `out_valid` always sees
  `in_ready = 1` and needs no tag (`TAG_W = 1`, `in_tag` tied to 0).

Example (binary32: MUL latency 4, ADD latency 3). The ADD requested in cycle
1 would complete in cycle 4 together with the MUL, so `in_ready` is low and
the request is held. It is accepted in cycle 2 and completes in cycle 5:

```
cycle       0     1     2     3     4     5
in_valid    1     1     1     0     0     0
mode        MUL   ADD   ADD   -     -     -
in_tag      0     1     1     -     -     -
in_ready    1     0     1     1     1     1
accepted    MUL   -     ADD   -     -     -
out_valid   0     0     0     0     1     1
out_tag     -     -     -     -     0     1
```

A latency of L means `out_valid` is high L cycles after the cycle in which
the request was accepted.

### 3.3 Instantiation

Verilog:

```verilog
fp_unit_top #(
  .W_EXP(8), .W_MANT(23),      // binary32
  .DIVSQRT_IMPL(1),
  .TAG_W(4),
  .OPS_EN(32'h0000FFFF)
) u_fpu (
  .clk(clk), .rst_n(rst_n),
  .in_valid(req_valid), .in_ready(req_ready),
  .mode(req_op), .rm(req_rm),
  .a(req_a), .b(req_b), .c(req_c), .in_tag(req_tag),
  .y(res_y), .cmp(res_cmp), .flags(res_flags),
  .out_valid(res_valid), .out_tag(res_tag)
);
```

VHDL:

```vhdl
u_fpu : entity work.fp_unit_vhd
  generic map (W_EXP => 8, W_MANT => 23, DIVSQRT_IMPL => 1, TAG_W => 4, OPS_EN => 65535)
  port map (
    clk => clk, rst_n => rst_n,
    in_valid => req_valid, in_ready => req_ready,
    mode => req_op, rm => req_rm,
    a => req_a, b => req_b, c => req_c, in_tag => req_tag,
    y => res_y, cmp => res_cmp, flags => res_flags,
    out_valid => res_valid, out_tag => res_tag);
```

## 4. Latency

Cycles from the accepting edge to `out_valid` (`make metrics-latency`).
They are independent of the operand values.

| format | add/sub | mul | fma | div | sqrt | rndint/rndintx | min, max, cmp, totalOrder, sgnj, class, next, minmaxnum |
|--------|--------:|----:|----:|----:|-----:|---------------:|--------:|
| E4M3 | 3 | 4 | 7 | 4 | 5 | 2 | 1 |
| E5M2 | 3 | 4 | 7 | 4 | 4 | 2 | 1 |
| bfloat16 | 3 | 4 | 7 | 5 | 7 | 2 | 1 |
| binary16 | 3 | 4 | 7 | 6 | 8 | 2 | 1 |
| binary32 | 3 | 4 | 7 | 9 | 15 | 2 | 1 |
| binary64 | 3 | 5 | 8 | 17 | 29 | 2 | 1 |
| `W_MANT = 0` | 1 | 1 | 1 | 1 | 1 | 1 | 1 |

div / sqrt with the other `DIVSQRT_IMPL` values:

| format | `= 3` div / sqrt | `= 2` div and sqrt |
|--------|-----------------:|-------------------:|
| E4M3 | 7 / 6 | 6 |
| E5M2 | 7 / 5 | 5 |
| bfloat16 | 9 / 8 | 8 |
| binary16 | 11 / 9 | 9 |
| binary32 | 17 / 16 | 16 |
| binary64 | 32 / 30 | 30 |

Disabled or undefined opcodes: 1 cycle.

## 5. Operations

### 5.1 Opcodes (`mode`)

| code | name | operation (IEEE 754-2019 clause) | result |
|-----:|------|----------------------------------|--------|
| 0 | ADD | a + b (5.4.1) | y |
| 1 | SUB | a - b (5.4.1) | y |
| 2 | MUL | a x b (5.4.1) | y |
| 3 | DIV | a / b (5.4.1) | y |
| 4 | SQRT | squareRoot(a) (5.4.1) | y |
| 5 | FMA | (a x b) + c, one rounding (5.4.1) | y |
| 6 | MIN | minimum(a, b) (9.6) | y |
| 7 | MAX | maximum(a, b) (9.6) | y |
| 8 | CMP | quiet comparison (5.11) | cmp: 0 a < b, 1 a = b, 2 a > b, 3 unordered |
| 9 | RNDINT | roundToIntegral, direction `rm` (5.9) | y |
| 10 | TOTALORDER | totalOrder(a, b) (5.10) | cmp[0] = 1 iff a precedes or equals b |
| 11 | SGNJ | `rm` 0 copy(a), 1 negate(a), 2 abs(a), 3 copySign(a, b) (5.5.1) | y |
| 12 | CLASS | class(a) (5.7.2) | y = 0 sNaN, 1 qNaN, 2 -inf, 3 -normal, 4 -subnormal, 5 -0, 6 +0, 7 +subnormal, 8 +normal, 9 +inf |
| 13 | NEXT | `rm` 1 nextDown(a), otherwise nextUp(a) (5.3.1) | y |
| 14 | MINMAXNUM | `rm` 0 minimumNumber, 1 maximumNumber, 2 minimumMagnitudeNumber, 3 maximumMagnitudeNumber (9.6) | y |
| 15 | RNDINTX | roundToIntegralExact (5.3.1): RNDINT plus inexact | y |

### 5.2 Rounding modes (`rm`)

| code | attribute (4.3) |
|-----:|-----------------|
| 0 | roundTiesToEven (RNE) |
| 1 | roundTiesToAway (RNA) |
| 2 | roundTowardZero (RZ) |
| 3 | roundTowardPositive (RP) |
| 4 | roundTowardNegative (RM) |
| 5-7 | reserved: behave as 0 (and as variant 0 for SGNJ, NEXT, MINMAXNUM) |

### 5.3 Exception flags (`flags`)

| bit | flag (clause 7) | raised when |
|----:|-----------------|-------------|
| 4 | invalid (7.2) | e.g. inf - inf, 0 x inf, 0/0, inf/inf, sqrt(negative), any signaling NaN operand of an arithmetic op, a disabled/undefined opcode |
| 3 | divideByZero (7.3) | finite non-zero / 0 |
| 2 | overflow (7.4) | the rounded result exceeds the largest finite value (inexact is set too) |
| 1 | underflow (7.5) | the result is tiny **after rounding** and inexact |
| 0 | inexact (7.6) | the rounded result differs from the exact result |

Flags are per operation (they are not sticky). Accumulate them in the
consumer if status-register semantics are needed (the AXI top latches the
flags of the last operation only).

### 5.4 Special values

- **NaN results** are quiet with sign 0 and the payload of the first NaN
  operand (a, then b, then c), quieted. Invalid operations without a NaN
  operand return the default quiet NaN (all-ones exponent, top fraction bit
  set).
- **Signed zero**: an exact zero sum of like-signed operands keeps their
  sign; otherwise it is +0, or -0 under roundTowardNegative (6.3). Products
  and quotients take the XOR of the signs; sqrt(-0) = -0.
- **minimum/maximum** (MIN/MAX) propagate NaN; minimum(-0, +0) = -0.
  MINMAXNUM returns the number when exactly one operand is a NaN.
- **Subnormals** are fully supported as inputs and outputs (no flush to
  zero).
- **SGNJ** changes only the sign bit: NaNs are not quieted, nothing is
  signaled.
- **CLASS**, **TOTALORDER** and **SGNJ** never signal. CMP, NEXT and
  MINMAXNUM signal invalid only for a signaling NaN.

## 6. Formats

### 6.1 Encoding

Any `(W_EXP, W_MANT)` follows the IEEE 754 encoding rules: bias
`2^(W_EXP-1) - 1`, exponent field 0 for zeros and subnormals, all-ones for
infinities and NaNs. A NaN with the top fraction bit set is quiet; with it
clear, it is signaling.

### 6.2 Common configurations

| name | W_EXP | W_MANT | W |
|------|------:|-------:|--:|
| binary64 | 11 | 52 | 64 |
| binary32 | 8 | 23 | 32 |
| binary16 | 5 | 10 | 16 |
| bfloat16 | 8 | 7 | 16 |
| E5M2 | 5 | 2 | 8 |
| E4M3 | 4 | 3 | 8 |

### 6.3 8-bit formats

E4M3 and E5M2 here are the **IEEE-style** encodings, with infinities and NaNs
at the all-ones exponent. They are not the OCP 8-bit formats, which differ:
OCP E4M3 (E4M3FN) has no infinities and a maximum of 448, and OCP E5M2 is
the same as the IEEE-style E5M2. With `W_EXP = 4, W_MANT = 3`, the largest
finite value is 240 and 0x78 is +infinity.

### 6.4 `W_MANT = 0` (sign + exponent, powers of two)

With no fraction bits, every finite value is a signed power of two. There
are no subnormals and no NaN encodings: exponent field 0 is zero and
all-ones is infinity. Invalid operations return +infinity with the invalid
flag. With `W_EXP = 8` this is a 9-bit format, **not** the OCP MX E8M0
scale format (8 bits, unsigned, 0xFF = NaN). Dedicated datapaths handle this
format with a latency of 1 for every operation.

## 7. AXI4-Lite interface (`fp_unit_axilite_top` / `fp_unit_axilite_vhd`)

A memory-mapped wrapper around one `fp_unit`. It processes one operation at
a time: write the operands, start, poll, read the result.

### 7.1 Ports

The ports are the standard AXI4-Lite slave signals with the `s_axi_` prefix:
`s_axi_aclk`, `s_axi_aresetn` (synchronous, active low), the AW, W, B, AR
and R channels, a 32-bit data bus, `WSTRB` and an `ADDR_WIDTH`-bit address.
There are no AWPROT/ARPROT ports (unused). Responses are OKAY, or DECERR for
addresses outside the map. Writes to read-only registers are ignored with
OKAY. The slave accepts READY before VALID on the B and R channels, and the
read data is held stable while RVALID waits.

### 7.2 Register map

Operand and result registers are `REG_W` bits, the next power of two of `W`,
accessed as `WORDS = REG_W / 32` (at least 1) 32-bit words, low word first.

| offset (W <= 32) | offset (33 <= W <= 64) | name | access | fields |
|---|---|---|---|---|
| 0x00 | 0x00 | CTRL | RW | [0] GO: a rising edge (0 then 1) starts an operation; [1] CLR: while 1, holds STATUS.VALID at 0 |
| 0x04 | 0x04 | OPCODE | RW | [3:0] opcode, [6:4] rounding mode |
| 0x08 | 0x08, 0x0C | DATA_A | RW | operand a |
| 0x0C | 0x10, 0x14 | DATA_B | RW | operand b |
| 0x10 | 0x18, 0x1C | DATA_C | RW | operand c (FMA addend) |
| 0x14 | 0x20 | STATUS | RO | [4:0] flags of the last operation, [8] BUSY, [9] VALID, [23:16] W_EXP, [31:24] W_MANT |
| 0x18 | 0x24, 0x28 | RESULT | RO | y of the last operation (zero-extended) |
| 0x1C | 0x2C | RES_CMP | RO | [1:0] cmp of the last operation |

GO latches DATA_A/B/C and OPCODE, so they can be rewritten for the next
operation while one is running. STATUS.BUSY is set from GO until the result
arrives, and then STATUS.VALID is set. VALID is cleared by the next GO or by
CLR.

### 7.3 Software sequence

```c
#include <stdint.h>

#define FPU_CTRL    0x00u
#define FPU_OPCODE  0x04u
#define FPU_A       0x08u
#define FPU_B       0x0Cu
#define FPU_C       0x10u
#define FPU_STATUS  0x14u
#define FPU_RESULT  0x18u
#define FPU_CMP     0x1Cu
#define FPU_VALID   (1u << 9)

static inline uint32_t reg_rd(uintptr_t base, uint32_t off)
{ return *(volatile uint32_t *)(base + off); }
static inline void reg_wr(uintptr_t base, uint32_t off, uint32_t v)
{ *(volatile uint32_t *)(base + off) = v; }

/* binary32 build (W <= 32): one operation, returns y, stores the flags */
uint32_t fpu_op(uintptr_t base, unsigned op, unsigned rm,
                uint32_t a, uint32_t b, uint32_t c, uint32_t *flags)
{
    reg_wr(base, FPU_A, a);
    reg_wr(base, FPU_B, b);
    reg_wr(base, FPU_C, c);
    reg_wr(base, FPU_OPCODE, (op & 0xFu) | ((rm & 0x7u) << 4));
    reg_wr(base, FPU_CTRL, 0);      /* GO low ...           */
    reg_wr(base, FPU_CTRL, 1);      /* ... then high: start */
    uint32_t st;
    do { st = reg_rd(base, FPU_STATUS); } while (!(st & FPU_VALID));
    *flags = st & 0x1Fu;
    return reg_rd(base, FPU_RESULT);
}
```

## 8. Using the core in Vivado

### 8.1 Files

| set | files | type |
|-----|-------|------|
| core | every file in `rtl/filelist.f`, in that order | SystemVerilog |
| AXI wrapper | `rtl/fp_unit_axilite.sv` (in `rtl/filelist_wrappers.f`) | SystemVerilog |
| Verilog tops | `rtl/top/fp_unit_flat.sv` (SystemVerilog), `rtl/top/fp_unit_top.v`, `rtl/top/fp_unit_axilite_top.v` | Verilog |
| VHDL tops | `rtl/top/fp_unit_vhd.vhd`, `rtl/top/fp_unit_axilite_vhd.vhd` (`rtl/filelist_vhdl.f`) | VHDL |

`rtl/fp_pkg.sv` must be compiled before the modules that use it (first in
`rtl/filelist.f`). The `.sv` files need the SystemVerilog file type: Vivado
sets it from the extension when you add them with `add_files`.

Non-project Tcl:

```tcl
cd /path/to/systemverilog_fp_unit
proc flist {f} {
  set fh [open $f]; set l {}
  foreach x [split [read $fh] "\n"] {
    set x [string trim [lindex [split $x "#"] 0]]
    if {$x ne ""} { lappend l $x }
  }
  close $fh; return $l
}
read_verilog -sv [concat [flist rtl/filelist.f] rtl/fp_unit_axilite.sv rtl/top/fp_unit_flat.sv]
read_verilog [list rtl/top/fp_unit_top.v rtl/top/fp_unit_axilite_top.v]
read_vhdl [flist rtl/filelist_vhdl.f]
synth_design -top fp_unit_vhd -part <part> -generic W_EXP=8 -generic W_MANT=23
```

`syn/vivado-top.tcl` is a complete script that does this and then places
and routes (`-tclargs <top> <period> W_EXP=.. W_MANT=..`).

### 8.2 Block design (IP integrator)

1. Add the files above to the project.
2. In the block design: right-click > Add Module, and pick
   `fp_unit_axilite_vhd` or `fp_unit_axilite_top` (AXI), or `fp_unit_vhd` or
   `fp_unit_top` (streaming). In Tcl:
   `create_bd_cell -type module -reference fp_unit_axilite_vhd fpu_0`.
3. Set the parameters on the cell (CONFIG.W_EXP, CONFIG.W_MANT,
   CONFIG.DIVSQRT_IMPL, ...).
4. The AXI tops show one AXI4-Lite slave interface `S_AXI`, with
   `s_axi_aclk` associated to it and `s_axi_aresetn` as an active-low reset.
   Connect them to an AXI SmartConnect or interconnect and assign an address
   segment: the map spans 32 bytes for W <= 32 and 48 bytes for W <= 64, so
   the minimum 4 KB segment is fine. The streaming tops show `clk` with an
   associated active-low `rst_n`, and plain data ports.

`syn/vivado-bd-check.tcl` performs these steps for all four tops and checks
the inferred interfaces.

### 8.3 Timing constraints

The core is a single clock domain. Constrain the clock with
`create_clock`, for example `create_clock -period 5.600 [get_ports clk]`.
No multicycle or false paths are needed. On the streaming interface,
`in_ready` is a combinational function of `mode` and internal registers. If
the producer is in another module, include that path in its timing; it is
short.

### 8.4 Resources and timing (Vivado 2026.1.1, xcvu9p-flga2104-2L-e, binary32)

`make vivado` (`syn/vivado-impl.tcl`, out of context, I/O registered):

| `DIVSQRT_IMPL` | clock | WNS | CLB LUTs | registers | DSP / BRAM |
|----------------|-------|-----|---------:|----------:|-----------|
| 1 | 5.600 ns | +0.131 ns | 12,656 | 4,089 | 0 / 0 |
| 3 | 4.000 ns | +0.001 ns | 13,368 | 5,143 | 0 / 0 |
| 2 | 4.000 ns | +0.066 ns | 7,368 | 2,255 | 0 / 0 |

`OPS_EN` reduces the area of builds that need only some operations.

With the Verilog/VHDL tops as the design top (`syn/vivado-top.tcl`, ports not
registered; same part, 2026-11-04), all of these meet timing:
`fp_unit_vhd` binary32 at 5.6 ns (+0.109 ns) and with `DIVSQRT_IMPL = 3` at
4.0 ns (+0.031 ns), `fp_unit_axilite_vhd` binary32 at 5.6 ns (+0.060 ns), and
`fp_unit_top` binary16 with `OPS_EN = 0x27` at 5.6 ns (+1.288 ns).

## 9. Verification

- Bit-exact Python reference model of IEEE 754-2019 (`tests/reference`),
  shared by all harnesses.
- **Exhaustive**: every operand pair x 5 rounding modes x 16 opcodes for
  each 8-bit format, about 5.2 million vectors per format and
  `DIVSQRT_IMPL`.
- **Randomized**: cocotb regression at 8 widths (binary16/32/64, bfloat16,
  E4M3, (6,16), (10,40), `W_MANT = 0`), and C++ soaks of millions of vectors
  at binary16, bfloat16, E4M3, binary64 and `W_MANT = 0`.
- **Streaming**: requests every cycle, backpressure and out-of-order
  completion (`make stream`).
- **Formal** (SymbiYosys): the add and mul pipelines are equivalent to
  their combinational references for all inputs at E4M3, bfloat16 and
  binary16, plus algebraic properties of the other operations.
- **Vivado tops**: the Verilog tops run the cocotb regression at every
  width. The Verilog and VHDL tops run side by side in xsim against the
  reference (`uv run python tests/vivado/run_xsim.py`). Vivado synthesis
  and implementation use each top as the design top
  (`syn/vivado-top.tcl`), and the block-design module-reference check is
  `syn/vivado-bd-check.tcl`.

## 10. Limitations

- One operation per cycle at most, and one result port. Operations that
  would complete together are serialized by `in_ready` at issue.
- No output backpressure on the streaming interface.
- Flags are per operation; there are no sticky status flags, no traps and
  no alternate exception handling.
- Not implemented: conversions (integer and between formats), remainder,
  scaleB/logB, signaling comparisons. Design notes are in `docs/proposals/`.
- The AXI4-Lite wrapper processes one operation at a time and has no
  interrupt; software polls STATUS.VALID.
