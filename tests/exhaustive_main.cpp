// Standalone Verilator C++ harness for exhaustive add/sub/mul/div/sqrt/fma/
// min/max/cmp/rndint/totalorder verification.
//
// Drives every (op, rm, a, b) combination of an fp_unit instance and compares
// the result against a precomputed expected file written by
// tests/exhaustive.py (the bit-exact reference oracle). This path avoids the
// cocotb VPI overhead, which would make an exhaustive 8-bit sweep
// (11*5*256*256 = 3,604,480 vectors per format) impractical. The `c` operand
// for the FMA op is fixed per format (passed on the command line); the other
// ops ignore it.
//
// Expected file layout (little-endian, one record per combination):
//   for op in {0..10}: for rm in {0..4}: for a in [0,2^w): for b in [0,2^w):
//     uint8 y, uint8 flags, uint8 cmp
// cmp is the 2-bit comparison condition code (OP_CMP) or the totalOrder
// boolean (OP_TOTALORDER, cmp[0]); every other op drives cmp = 0.

#include "Vfp_unit.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <expected.bin> <width> <c>\n", argv[0]);
        return 2;
    }
    const char* path = argv[1];
    const int w = atoi(argv[2]);
    const int C = atoi(argv[3]);
    const int A = 1 << w;  // values per operand

    Verilated::commandArgs(argc, argv);
    Vfp_unit* top = new Vfp_unit;
    top->clk = 0;
    top->rst_n = 1;  // synchronous active-low reset released before vectors

    FILE* f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "cannot open %s\n", path);
        return 2;
    }

    const uint64_t expected = 11 * 5ull * (uint64_t)A * (uint64_t)A;
    uint64_t errors = 0;
    uint64_t total = 0;
    uint8_t exp_y = 0, exp_flags = 0, exp_cmp = 0;
    for (int op = 0; op < 11; op++) {
        top->mode = op;
        for (int rm = 0; rm < 5; rm++) {
            top->rm = rm;
            for (int a = 0; a < A; a++) {
                top->a = a;
                for (int b = 0; b < A; b++) {
                    top->b = b;
                    top->c = C;
                    top->clk = 0;
                    top->eval();  // combinational result settles (clk low)
                    top->clk = 1;
                    top->eval();  // posedge captures y/flags/cmp
                    const uint8_t y = top->y;
                    const uint8_t flags = top->flags;
                    const uint8_t cmp = top->cmp;
                    if (fread(&exp_y, 1, 1, f) != 1 ||
                        fread(&exp_flags, 1, 1, f) != 1 ||
                        fread(&exp_cmp, 1, 1, f) != 1) {
                        fprintf(stderr, "truncated expected file\n");
                        return 2;
                    }
                    total++;
                    if (y != exp_y || flags != exp_flags || cmp != exp_cmp) {
                        if (errors < 50)
                            fprintf(stderr,
                                    "MISMATCH op=%d rm=%d a=%0*x b=%0*x: "
                                    "got y=%0*x flags=%02x cmp=%02x, "
                                    "want y=%0*x flags=%02x cmp=%02x\n",
                                    op, rm, (w + 3) / 4, a, (w + 3) / 4, b,
                                    (w + 3) / 4, y, flags, cmp,
                                    (w + 3) / 4, exp_y, exp_flags, exp_cmp);
                        errors++;
                    }
                }
            }
        }
    }
    fclose(f);

    if (total != expected)
        fprintf(stderr, "expected %llu vectors, got %llu\n",
                (unsigned long long)expected, (unsigned long long)total);

    top->final();
    delete top;

    fprintf(stderr, "EXHAUSTIVE %llu vectors: %s (%llu mismatches)\n",
            (unsigned long long)total,
            errors ? "FAIL" : "PASS", (unsigned long long)errors);
    return errors ? 1 : 0;
}
