# jsm_fp_unit: IEEE 754-2019 floating-point unit, user guide

Integration guide and reference. The design and verification
specification for maintainers is [architecture.md](architecture.md).

## 1. Overview

`jsm_fp_unit` is a parameterized, fully synchronous floating-point unit:

- **Any binary format** `1 sign + W_EXP exponent + W_MANT fraction bits`,
  chosen at build time: binary16/32/64, bfloat16, the 8-bit formats E4M3 and
  E5M2, odd sizes, and a sign + exponent power-of-two format (`W_MANT = 0`).
- **16 operations**: add, sub, mul, div, sqrt, fused multiply-add,
  minimum/maximum, quiet comparison, roundToIntegral (also the Exact form),
  totalOrder, the sign operations (copy/negate/abs/copySign), class,
  nextUp/nextDown and the minimumNumber family.
- **All five rounding-direction attributes** and all five exception flags,
  bit-exact against a Python reference model of IEEE 754-2019.
- **Fully pipelined**: every operation has a fixed latency, and a new
  request can start every cycle (except with the iterative div/sqrt option).
- **No DSPs, no RAMs**: LUTs and flip-flops only (the AXI4-Stream wrapper
  adds a small LUT-RAM buffer).

Three interfaces, each with a SystemVerilog core, a Verilog-2001 top and a
VHDL top, and the AXI ones also as packaged Vivado IP:

| interface | use | SystemVerilog | Verilog-2001 top | VHDL top | Vivado IP |
|-----------|-----|---------------|------------------|----------|-----------|
| AXI4-Stream | hardware datapaths, DMA; full backpressure, results in order | `rtl/jsm_fp_unit_axis.sv` | `rtl/top/jsm_fp_unit_axis_top.v` | `rtl/top/jsm_fp_unit_axis_vhd.vhd` | `jsm:fpu:jsm_fp_unit_axis:1.0` |
| AXI4-Lite | software access from a processor | `rtl/jsm_fp_unit_axilite.sv` | `rtl/top/jsm_fp_unit_axilite_top.v` | `rtl/top/jsm_fp_unit_axilite_vhd.vhd` | `jsm:fpu:jsm_fp_unit_axilite:1.0` |
| native | lowest latency; valid/ready in, tagged results out, no output backpressure | `rtl/jsm_fp_unit.sv` | `rtl/top/jsm_fp_unit_top.v` | `rtl/top/jsm_fp_unit_vhd.vhd` | `jsm:fpu:jsm_fp_unit:1.0` |

The Verilog and VHDL tops add no logic: a Vivado block-design module
reference, or a VHDL design, needs a top with plain ports and integer
parameters. The native core's `mode`/`rm` ports are SystemVerilog enum types,
so `rtl/top/jsm_fp_unit_flat.sv` maps them to plain vectors first:

```
jsm_fp_unit_vhd -> jsm_fp_unit_top (Verilog) -> jsm_fp_unit_flat (SV) -> jsm_fp_unit
jsm_fp_unit_axis_vhd -> jsm_fp_unit_axis_top (Verilog) -> jsm_fp_unit_axis (SV) -> jsm_fp_unit
jsm_fp_unit_axilite_vhd -> jsm_fp_unit_axilite_top (Verilog) -> jsm_fp_unit_axilite (SV) -> jsm_fp_unit
```

The core is licensed under the Solderpad Hardware License v2.1 (section 14):
products and designs that include it must credit it.

### Quick start

1. Pick an interface: AXI4-Stream for a hardware datapath, AXI4-Lite for
   software access, native for the lowest latency (the consumer must then
   take every result in the cycle it appears).
2. Vivado: `make ip` and add `ip_repo/` to the IP repositories (section
   9.1), or add the source files of section 9.2 to the project. Other tools:
   the files of section 9.2.
3. Set `W_EXP` / `W_MANT` for the format and `DIVSQRT_IMPL` for the clock
   target: 1 for 5.6 ns, 3 (pipelined) or 2 (smaller) for 4.0 ns, on
   VU9P-2L.
4. Constrain the single clock; the reset is synchronous and active low.

## 2. Parameters

All parameters are integers in the Verilog and VHDL tops and in the IP.

| parameter | default | applies to | meaning |
|-----------|---------|------------|---------|
| `W_EXP` | 8 | all | exponent field width |
| `W_MANT` | 23 | all | fraction field width (0: power-of-two format, see 8.4) |
| `DIVSQRT_IMPL` | 1 | all | div/sqrt implementation, see below |
| `OPS_EN` | 65535 (0xFFFF) | native, AXI4-Stream | operation enable mask, bit i = opcode i |
| `TAG_W` | 1 | native | request tag width, >= 1 |
| `TUSER_W` | 1 | AXI4-Stream | TUSER width, >= 1 |
| `DEPTH` | 0 | AXI4-Stream | reorder-buffer entries, 0 = automatic (full throughput) |
| `ADDR_WIDTH` | 6 | AXI4-Lite | address width; at least 5 for W <= 32, 6 for W <= 64 |

`DIVSQRT_IMPL`:

| value | implementation | throughput | clock (VU9P-2L, binary32) |
|-------|----------------|------------|---------------------------|
| 1 | SRT pipelines, 2 division digits per stage | 1 div/sqrt per cycle | 5.6 ns (178.6 MHz) alone, 5.6-5.8 ns in a larger design (9.5) |
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
(10,40), (11,52) binary64, and (8,0). Other widths up to binary64 use the
same parameterized RTL but have not been simulated. binary128 (15,112) is
not supported: Verilator cannot build the multiplier at that width, and it
has never been tested.

Invalid parameter values stop elaboration with an error message in Vivado,
Verilator and Yosys: `DIVSQRT_IMPL` other than 0-3, `TAG_W < 1`, `TUSER_W < 1`,
`W_EXP < 1`, `W_MANT < 0`, and an `ADDR_WIDTH` too small for the register
map.

## 3. Native interface (`jsm_fp_unit_top` / `jsm_fp_unit_vhd`)

### 3.1 Ports

| port | dir | width | description |
|------|-----|-------|-------------|
| `clk` | in | 1 | clock; all logic on the rising edge |
| `rst_n` | in | 1 | **synchronous**, active-low reset |
| `in_valid` | in | 1 | request valid |
| `in_ready` | out | 1 | request accepted on a rising edge with `in_valid && in_ready` |
| `mode` | in | 4 | opcode (section 7) |
| `rm` | in | 3 | rounding mode (section 7.2), or the variant of a non-rounding op |
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
  number of cycles later (section 5). `y`, `cmp`, `flags` and `out_tag` are
  valid in that cycle only. There is no output backpressure: the consumer
  must take a result in the cycle it appears (the AXI4-Stream wrapper,
  section 4, adds backpressure).
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
jsm_fp_unit_top #(
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
u_fpu : entity work.jsm_fp_unit_vhd
  generic map (W_EXP => 8, W_MANT => 23, DIVSQRT_IMPL => 1, TAG_W => 4, OPS_EN => 65535)
  port map (
    clk => clk, rst_n => rst_n,
    in_valid => req_valid, in_ready => req_ready,
    mode => req_op, rm => req_rm,
    a => req_a, b => req_b, c => req_c, in_tag => req_tag,
    y => res_y, cmp => res_cmp, flags => res_flags,
    out_valid => res_valid, out_tag => res_tag);
```

## 4. AXI4-Stream interface (`jsm_fp_unit_axis_top` / `jsm_fp_unit_axis_vhd`)

One operation per request beat, one result beat per request, **in request
order**, with full backpressure on both streams. The request's TUSER and
TLAST come back with its result, so packets and side information pass
through unchanged.

### 4.1 Ports

| port | dir | width | description |
|------|-----|-------|-------------|
| `aclk` | in | 1 | clock |
| `aresetn` | in | 1 | **synchronous**, active-low reset |
| `s_axis_tvalid`, `s_axis_tready` | in, out | 1 | request handshake |
| `s_axis_tdata` | in | 3*OPB + 8 | request (below) |
| `s_axis_tuser`, `s_axis_tlast` | in | TUSER_W, 1 | passed through to the result |
| `m_axis_tvalid`, `m_axis_tready` | out, in | 1 | result handshake |
| `m_axis_tdata` | out | OPB + 8 | result (below) |
| `m_axis_tuser`, `m_axis_tlast` | out | TUSER_W, 1 | the request's TUSER / TLAST |

OPB is the format width W = 1 + W_EXP + W_MANT rounded up to a multiple of
8 (binary32: 32, binary64: 64, binary16: 16, `W_MANT = 0` with `W_EXP = 8`: 16).

### 4.2 TDATA layout

Request (`s_axis_tdata`, LSB first; operands zero-padded to OPB bits):

| bits | field |
|------|-------|
| `[OPB-1:0]` | a |
| `[2*OPB-1:OPB]` | b |
| `[3*OPB-1:2*OPB]` | c (FMA addend; ignored by other operations) |
| `[3*OPB+3:3*OPB]` | opcode (section 7.1) |
| `[3*OPB+6:3*OPB+4]` | rounding mode or variant (section 7.2) |
| `[3*OPB+7]` | reserved, 0 |

Result (`m_axis_tdata`):

| bits | field |
|------|-------|
| `[OPB-1:0]` | y, zero-extended above W |
| `[OPB+4:OPB]` | flags `{invalid, divideByZero, overflow, underflow, inexact}` |
| `[OPB+6:OPB+5]` | cmp |
| `[OPB+7]` | 0 |

binary32: a request is 104 bits (a `[31:0]`, b `[63:32]`, c `[95:64]`,
opcode `[99:96]`, rm `[102:100]`), a result 40 bits (y `[31:0]`, flags
`[36:32]`, cmp `[38:37]`).

### 4.3 Behaviour

- Standard AXI4-Stream handshakes. `s_axis_tready` is a registered signal:
  it does not depend on `s_axis_tvalid` or `s_axis_tdata`. `m_axis_tvalid`
  and `m_axis_tdata` stay stable until the result is taken.
- A result appears on M_AXIS L + 2 cycles after its request's handshake,
  where L is the native latency of the operation (section 5): one cycle in
  the input skid buffer and one in the reorder buffer.
- Inside, a reorder buffer holds every request from issue until its result
  leaves. A request is only issued while a slot is free, so a stalled
  `m_axis_tready` stops `s_axis_tready` instead of losing results. With
  `DEPTH = 0` the buffer has (longest latency + 2) entries, rounded up to a
  power of two (32 entries for binary32, 16 for binary16), which sustains
  one operation per cycle
  while `m_axis_tready` is high.
- Mixed operations of different latency can still stall S_AXIS for a cycle
  when two of them would complete together inside the unit (its single
  result port); a stream of one operation type runs at one per cycle.
- Requests are issued in order. With `DIVSQRT_IMPL = 2` (one div/sqrt in
  flight) a second div/sqrt therefore waits at the head of the request
  stream until the engine is free, and the requests behind it wait too.

### 4.4 Instantiation

```verilog
jsm_fp_unit_axis_top #(
  .W_EXP(8), .W_MANT(23), .DIVSQRT_IMPL(1), .TUSER_W(8)
) u_fpu (
  .aclk(clk), .aresetn(rst_n),
  .s_axis_tvalid(req_tvalid), .s_axis_tready(req_tready),
  .s_axis_tdata({1'b0, req_rm, req_op, req_c, req_b, req_a}),   // 104 bits
  .s_axis_tuser(req_tuser), .s_axis_tlast(req_tlast),
  .m_axis_tvalid(res_tvalid), .m_axis_tready(res_tready),
  .m_axis_tdata(res_tdata),                                       // 40 bits
  .m_axis_tuser(res_tuser), .m_axis_tlast(res_tlast)
);
```

```vhdl
u_fpu : entity work.jsm_fp_unit_axis_vhd
  generic map (W_EXP => 8, W_MANT => 23, DIVSQRT_IMPL => 1, TUSER_W => 8)
  port map (
    aclk => clk, aresetn => rst_n,
    s_axis_tvalid => req_tvalid, s_axis_tready => req_tready,
    s_axis_tdata => req_tdata, s_axis_tuser => req_tuser, s_axis_tlast => req_tlast,
    m_axis_tvalid => res_tvalid, m_axis_tready => res_tready,
    m_axis_tdata => res_tdata, m_axis_tuser => res_tuser, m_axis_tlast => res_tlast);
```

## 5. Latency

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

AXI4-Stream wrapper: the latencies above + 2. AXI4-Lite wrapper: at least
eight bus transactions per operation (three operand writes, OPCODE, two CTRL
writes, STATUS polls and the RESULT read; section 6.3).

## 6. AXI4-Lite interface (`jsm_fp_unit_axilite_top` / `jsm_fp_unit_axilite_vhd`)

A memory-mapped wrapper around one `jsm_fp_unit`. It processes one operation at
a time: write the operands, start, poll, read the result.

### 6.1 Ports

The ports are the standard AXI4-Lite slave signals with the `s_axi_` prefix:
`s_axi_aclk`, `s_axi_aresetn` (synchronous, active low), the AW, W, B, AR
and R channels, a 32-bit data bus, `WSTRB` and an `ADDR_WIDTH`-bit address.
There are no AWPROT/ARPROT ports (unused). Responses are OKAY, or DECERR for
addresses outside the map. Writes to read-only registers are ignored with
OKAY. The slave accepts READY before VALID on the B and R channels, and the
read data is held stable while RVALID waits.

### 6.2 Register map

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

### 6.3 Software sequence

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

## 7. Operations

### 7.1 Opcodes (`mode`)

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

### 7.2 Rounding modes (`rm`)

| code | attribute (4.3) |
|-----:|-----------------|
| 0 | roundTiesToEven (RNE) |
| 1 | roundTiesToAway (RNA) |
| 2 | roundTowardZero (RZ) |
| 3 | roundTowardPositive (RP) |
| 4 | roundTowardNegative (RM) |
| 5-7 | reserved: behave as 0 (and as variant 0 for SGNJ, NEXT, MINMAXNUM) |

### 7.3 Exception flags (`flags`)

| bit | flag (clause 7) | raised when |
|----:|-----------------|-------------|
| 4 | invalid (7.2) | e.g. inf - inf, 0 x inf, 0/0, inf/inf, sqrt(negative), any signaling NaN operand of an arithmetic op, a disabled/undefined opcode |
| 3 | divideByZero (7.3) | finite non-zero / 0 |
| 2 | overflow (7.4) | the rounded result exceeds the largest finite value (inexact is set too) |
| 1 | underflow (7.5) | the result is tiny **after rounding** and inexact |
| 0 | inexact (7.6) | the rounded result differs from the exact result |

Flags are per operation (they are not sticky). Accumulate them in the
consumer if status-register semantics are needed (the AXI4-Lite top latches
the flags of the last operation only).

### 7.4 Special values

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

## 8. Formats

### 8.1 Encoding

Any `(W_EXP, W_MANT)` follows the IEEE 754 encoding rules: bias
`2^(W_EXP-1) - 1`, exponent field 0 for zeros and subnormals, all-ones for
infinities and NaNs. A NaN with the top fraction bit set is quiet; with it
clear, it is signaling.

### 8.2 Common configurations

| name | W_EXP | W_MANT | W |
|------|------:|-------:|--:|
| binary64 | 11 | 52 | 64 |
| binary32 | 8 | 23 | 32 |
| binary16 | 5 | 10 | 16 |
| bfloat16 | 8 | 7 | 16 |
| E5M2 | 5 | 2 | 8 |
| E4M3 | 4 | 3 | 8 |

### 8.3 8-bit formats

E4M3 and E5M2 here are the **IEEE-style** encodings, with infinities and NaNs
at the all-ones exponent. They are not the OCP 8-bit formats, which differ:
OCP E4M3 (E4M3FN) has no infinities and a maximum of 448, and OCP E5M2 is
the same as the IEEE-style E5M2. With `W_EXP = 4, W_MANT = 3`, the largest
finite value is 240 and 0x78 is +infinity.

### 8.4 `W_MANT = 0` (sign + exponent, powers of two)

With no fraction bits, every finite value is a signed power of two. There
are no subnormals and no NaN encodings: exponent field 0 is zero and
all-ones is infinity. Invalid operations return +infinity with the invalid
flag. With `W_EXP = 8` this is a 9-bit format, **not** the OCP MX E8M0
scale format (8 bits, unsigned, 0xFF = NaN). Dedicated datapaths handle this
format with a latency of 1 for every operation.

## 9. Using the core in Vivado

### 9.1 IP catalog (recommended)

```
make ip        # = vivado -mode batch -source syn/package_ip.tcl [-tclargs <dir>]
```

packages three IP cores into `ip_repo/` (sources copied in, so the
directory can be moved or shared on its own):

| VLNV | interface |
|------|-----------|
| `jsm:fpu:jsm_fp_unit_axis:1.0` | AXI4-Stream (`S_AXIS`, `M_AXIS`) |
| `jsm:fpu:jsm_fp_unit_axilite:1.0` | AXI4-Lite slave (`S_AXI`, 4 KB address block) |
| `jsm:fpu:jsm_fp_unit:1.0` | native ports |

Add the directory under Settings > IP > Repository (Tcl:
`set_property ip_repo_paths <dir> [current_project]; update_ip_catalog`),
then add the core from the IP catalog or with
`create_bd_cell -type ip -vlnv jsm:fpu:jsm_fp_unit_axis:1.0 fpu_0`. The
parameters (section 2) appear in the customization dialog with their valid
ranges. The cores declare support for every device family. `make ip-check`
(`syn/ip_check.tcl [-tclargs <ip_repo> <part>]`) instantiates all three in a
block design, validates, generates and synthesizes it; checked on Virtex
UltraScale+ (xcvu9p) and Artix-7 (xc7a100t).

### 9.2 Source files

| set | files | type |
|-----|-------|------|
| core | every file in `rtl/filelist.f`, in that order | SystemVerilog |
| AXI wrappers | `rtl/jsm_fp_unit_axis.sv`, `rtl/jsm_fp_unit_axilite.sv` | SystemVerilog |
| native-top shim | `rtl/top/jsm_fp_unit_flat.sv` | SystemVerilog |
| Verilog tops | `rtl/top/jsm_fp_unit_top.v`, `rtl/top/jsm_fp_unit_axis_top.v`, `rtl/top/jsm_fp_unit_axilite_top.v` | Verilog-2001 |
| VHDL tops | `rtl/top/jsm_fp_unit_vhd.vhd`, `rtl/top/jsm_fp_unit_axis_vhd.vhd`, `rtl/top/jsm_fp_unit_axilite_vhd.vhd` (`rtl/filelist_vhdl.f`) | VHDL-93 |

`rtl/jsm_fp_pkg.sv` must be compiled first (it is first in
`rtl/filelist.f`). `rtl/filelist_wrappers.f` lists the wrappers, the
Verilog tops and two helper modules (`jsm_fp32_to_bf16_round`,
`jsm_fp_exp_seq`). Vivado sets the SystemVerilog file type from the `.sv`
extension.

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
set srcs [concat [flist rtl/filelist.f] [flist rtl/filelist_wrappers.f]]
read_verilog -sv [lsearch -all -inline -not $srcs *.v]
read_verilog     [lsearch -all -inline $srcs *.v]
read_vhdl [flist rtl/filelist_vhdl.f]
synth_design -top jsm_fp_unit_axis_vhd -part <part> -generic W_EXP=8 -generic W_MANT=23
```

`syn/vivado-top.tcl` does this for any top and then places and routes
(`make vivado-top TOP_ARGS="<top> <period_ns> W_EXP=.. W_MANT=.."`).

### 9.3 Block design without the IP catalog

Add the files of 9.2 to the project, then right-click > Add Module and pick
a Verilog or VHDL top (Tcl: `create_bd_cell -type module -reference
jsm_fp_unit_axis_vhd fpu_0`), and set its CONFIG.* parameters. The
interface attributes in the tops make IP integrator show `S_AXIS`/`M_AXIS`
or `S_AXI` with the associated clock and active-low reset.
`make vivado-bd-check` (`syn/vivado-bd-check.tcl`) checks this for the
tops.

### 9.4 Timing constraints

One clock domain: `create_clock -period 5.600 [get_ports aclk]` (or `clk`,
`s_axi_aclk`). No multicycle or false paths. On the native interface
`in_ready` is a combinational function of `mode` and internal registers; the
AXI wrappers have registered ready signals.

### 9.5 Resources and timing (Vivado 2026.1.1, xcvu9p-flga2104-2L-e, binary32)

Native core, `make vivado` (`syn/vivado-impl.tcl`, out of context, I/O
registered):

| `DIVSQRT_IMPL` | clock | WNS | CLB LUTs | registers | DSP / BRAM |
|----------------|-------|-----|---------:|----------:|-----------|
| 1 | 5.600 ns | +0.131 ns | 12,656 | 4,089 | 0 / 0 |
| 3 | 4.000 ns | +0.001 ns | 13,368 | 5,143 | 0 / 0 |
| 2 | 4.000 ns | +0.066 ns | 7,368 | 2,255 | 0 / 0 |

AXI4-Stream wrapper (`syn/vivado-top.tcl`, ports not registered, binary32,
`TUSER_W = 1`):

| `DIVSQRT_IMPL` | clock | WNS | CLB LUTs | registers | LUT-RAM |
|----------------|-------|-----|---------:|----------:|--------:|
| 1 | 5.800 ns | +0.160 ns | 12,868 | 4,239 | 26 |
| 1 | 5.600 ns | -0.349 ns (default flow), -0.017 ns (`-directive Explore`) | | | |
| 3 | 4.000 ns | +0.018 ns | 13,609 | 5,283 | 26 |

The wrapper adds a few hundred LUTs and registers to the core. With
`DIVSQRT_IMPL = 1` the two-digit division stage sets the clock and has
about 0.1 ns of margin at 5.6 ns on its own, so a larger design around it
can land at 5.6-5.8 ns; `DIVSQRT_IMPL = 3` has one digit per stage and
closes 4.0 ns with the wrapper. For the fastest clock use
`DIVSQRT_IMPL = 3`.

`OPS_EN` removes unused datapaths (section 2).

## 10. Other tools

| tool | use | tested |
|------|-----|--------|
| Vivado 2026.1.1 | synthesis, implementation, xsim (SystemVerilog cores, Verilog and VHDL tops), IP packaging, block designs | yes |
| Verilator 5.020 | lint (-Wall clean), cocotb and C++ simulation | yes |
| Yosys 0.68 | reads and elaborates every SystemVerilog module and the Verilog tops; give it the files of one top only (with unused wrapper modules loaded too, 0.68 also elaborates those and can fail on them) | yes |
| GHDL | the VHDL tops analyze as VHDL-93 and VHDL-2008 with `-frelaxed` (the Vivado interface attributes sit in the architecture, where Vivado reads them, not in the entity as VHDL wants); simulating them needs a mixed-language simulator | analysis only |
| Questa, VCS, Xcelium, Quartus, Synplify | synthesizable SystemVerilog-2012 subset, no vendor primitives | not tested |

## 11. Verification

- A bit-exact Python reference model of IEEE 754-2019 (`tests/reference`)
  is shared by every test.
- **Exhaustive**: every operand pair x 5 rounding modes x 16 opcodes for
  each 8-bit format, about 5.2 million vectors per format, for each
  `DIVSQRT_IMPL`.
- **Randomized**: cocotb at 8 formats (binary16/32/64, bfloat16, E4M3,
  (6,16), (10,40), `W_MANT = 0`) for the native core, both AXI wrappers and
  every Verilog top; C++ soaks of millions of vectors.
- **Streaming**: requests every cycle with backpressure and out-of-order
  completion (native); random TVALID gaps and TREADY backpressure, output
  stalls, throughput and latency (AXI4-Stream).
- **Formal** (SymbiYosys): the add and mul pipelines equal their
  combinational references for all inputs at E4M3, bfloat16 and binary16;
  algebraic properties of the other operations.
- **Vivado**: the Verilog and VHDL tops of all three interfaces run side by
  side in xsim against the reference model (`make xsim-tops`); every top is
  implemented as the design top; the packaged IP is instantiated, validated
  and synthesized (`make ip-check`).

## 12. Helper modules

Two small modules in `rtl/` (listed in `rtl/filelist_wrappers.f`), not part
of the unit:

- `jsm_fp32_to_bf16_round`: binary32 to bfloat16, roundTiesToEven, no flags,
  combinational. Infinities pass through; a NaN becomes a quiet NaN keeping
  its sign and top 6 payload bits (never infinity). Verified over all 2^32
  inputs (`make bf16`).
- `jsm_fp_exp_seq`: binary32 exp(x) for x clamped to [-16, 16] (larger
  magnitudes, infinities and NaN clamp to +-16), by x/32, a degree-6
  polynomial and five squarings on two `jsm_fp_unit` instances; 87 cycles.
  Measured error against the correctly rounded result: up to about 45 ulp
  (5e-6 relative) for |x| <= 8 and about 1,300 ulp (1.5e-4) near |x| = 16
  (`make regress-exp`). An example of driving the unit, not a precise exp.

## 13. Limitations

- One operation per cycle, one result port: operations that would complete
  together inside the unit are serialized at issue (`in_ready` /
  `s_axis_tready`).
- The native interface has no output backpressure (use the AXI4-Stream
  wrapper if the consumer can stall).
- Flags are per operation: no sticky status flags, no traps, no alternate
  exception handling.
- Not implemented: conversions (integer and between formats), remainder,
  scaleB/logB, signaling comparisons (see architecture.md, "Future work").
- The AXI4-Lite wrapper processes one operation at a time and has no
  interrupt; software polls STATUS.VALID.
- binary128 and wider formats are not supported (section 2).

## 14. License and attribution

The core is licensed under the **Solderpad Hardware License v2.1**
(`LICENSE`; SPDX `Apache-2.0 WITH SHL-2.1`), the Apache License 2.0 adapted
to hardware: its Source and Object forms include netlists, FPGA bitstreams
and physical devices. Anyone who distributes the core or a design or product
derived from it must, among the other conditions of the license, give
recipients a copy of the license, keep the copyright and license notices in
the source files, and include the attribution in `NOTICE` in the
distribution, for example in its documentation (Apache License 2.0, section
4). Internal use without distribution has no such obligation. This is a
summary; the license text is authoritative.
