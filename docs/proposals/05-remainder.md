# 05: remainder (5.3.1)

## Operation

`remainder(x, y)` = x - n*y with n the integer nearest x/y (ties to even), for
finite x and non-zero finite y. The result is always exact: no rounding,
never inexact. Its magnitude is at most |y|/2, it is zero with the sign of x,
and it can be subnormal without signaling underflow (the standard says the
result is exact). Invalid for y = 0, x = inf, or an sNaN; remainder(x, inf)
= x for finite x.

## Why it is not a pipeline

n can have up to `EMAX - EMIN + W_MANT + 1` bits (x = max finite, y = min
subnormal): 277 bits for binary32 and 2,099 for binary64. The quotient
digits do not need to be kept (only the final remainder and the last two
quotient bits for the tie and the n-parity), but the digit recurrence still
needs one radix-r step per log2(r) bits of the exponent difference
`ea - eb`. The latency therefore depends on the data:
`ceil((ea - eb + 1) / log2 r)` steps, up to 140 cycles at radix 4 for
binary32.

That breaks the unit's assumption that every op has a fixed latency (the
result-port reservation vector in `jsm_fp_unit`). Options:

1. **Fixed-latency partial remainder** (x87 `FPREM1` style): `OP_REMSTEP`
   performs at most K exponent-difference bits (e.g. K = 2 * NSTG of the
   SRT divider), returns the partial remainder in `y` and a "done" bit in
   `cmp[0]`. Software loops until done (at most ceil(277 / K) iterations for
   binary32). It fits the existing result port, but software sees a
   non-standard primitive.
2. **Iterative engine with its own completion handshake**: like
   `DIVSQRT_IMPL = 2`, one remainder in flight. Because the latency is not
   known at issue time, the result port cannot be reserved when the op is
   accepted. Instead, when the engine finishes, `jsm_fp_unit` blocks new issues
   (`in_ready = 0`) for the cycles in which the result port would collide,
   or the engine waits in a done state until a free slot appears (it
   checks `resv[0]` each cycle and takes a free one). The second variant is
   simpler and keeps the other ops' latencies fixed.
3. **Separate unit** (`fp_rem`) outside `jsm_fp_unit` with its own
   valid/ready handshake.

Recommended: option 2. It gives one interface for software, and the "wait
for a free slot" logic is small (a 1-entry output register and one AND
gate on `resv[0]`). `out_tag` already lets callers match out-of-order
results.

## Datapath (option 2)

Restoring or SRT radix-4 recurrence on the aligned significands, reusing
the structure of `jsm_fp_divsqrt_iter` (carry-save residual, digit selection on
the top bits, no quotient register). After the last step, compare the
remainder with |y|/2 using the last quotient bit for the tie, subtract y
once if needed, then normalize the result (LZC + left shift) and pack it.
The exponent difference loads a down-counter (`W_EXP + 1` bits).

## Cost (binary32)

- About the size of `jsm_fp_divsqrt_iter` without the sqrt path (that engine is
  1,294 LUTs / 301 FFs in the binary32 `DIVSQRT_IMPL = 2` build), plus a
  26-bit LZC/normalizer and the exponent counter: about 1,100 LUTs and 250
  FFs (+8 %).
- Latency: 3 + ceil((ea - eb + 1) / 2) cycles, data dependent (3 to about 143
  for binary32); one remainder in flight.
- Tests: the oracle is exact with Python integers (`x - n*y` on
  `Fraction`s). The exhaustive 8-bit sweep covers every (x, y) pair. The
  harnesses must accept a data-dependent latency for this op (the soak and
  exhaustive harnesses match by `out_tag` instead of by fixed latency;
  `tests/stream.py` already does).
