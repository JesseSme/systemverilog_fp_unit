#!/usr/bin/env python3
"""Random jsm_fp_unit test vectors with oracle results, for the Vivado xsim
testbenches of the Verilog/VHDL tops (tests/vivado/run_xsim.py).

One vector per line, hex fields: op rm a b c y flags cmp
(op 0..15, rm 0..7 including the reserved modes, operands from the same
generators as the cocotb random tests, expected values from
reference.ops.dispatch with the build's OPS_EN mask).
"""

import argparse
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from reference import gen, ops  # noqa: E402
from reference.formats import NUM_OPS, BinFormat  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("w_exp", type=int)
    ap.add_argument("w_mant", type=int)
    ap.add_argument("n", type=int)
    ap.add_argument("out")
    ap.add_argument("--seed", type=lambda s: int(s, 0), default=0x7E57)
    ap.add_argument("--ops-en", type=lambda s: int(s, 0), default=0xFFFF)
    args = ap.parse_args()

    fmt = BinFormat(args.w_exp, args.w_mant)
    rng = random.Random(args.seed)
    with open(args.out, "w") as f:
        for _ in range(args.n):
            a, b = gen.pair_stream(rng, fmt, 1)[0]
            op = rng.randrange(NUM_OPS)
            rm = rng.randrange(8) if rng.random() < 0.1 else rng.randrange(5)
            c = gen.operand(rng, fmt)   # random for every op: non-FMA ops ignore it
            y, flags, cmp = ops.dispatch(op, a, b, c, rm, fmt, ops_en=args.ops_en)
            f.write(f"{op:x} {rm:x} {a:x} {b:x} {c:x} {y:x} {flags:x} {cmp:x}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
