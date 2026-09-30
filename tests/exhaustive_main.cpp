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
#include "verilated_cov.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>

int main(int argc, char** argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <expected.bin> <width> <c> [iter] [divsqrt_cycles]\n", argv[0]);
        return 2;
    }
    const char* path = argv[1];
    const int w = atoi(argv[2]);
    const int C = atoi(argv[3]);
    // iter=1: fp_unit was built with ITER_DIVSQRT=1; div (op 3) and sqrt
    // (op 4) use the in_valid/busy/out_valid handshake.
    const int iter = (argc > 4) ? atoi(argv[4]) : 0;
    // Expected constant div/sqrt latency (0 = do not check): K+1 with
    // K = ceil((W_MANT+3)/2), supplied by the Python driver.
    const int divsqrt_cycles = (argc > 5) ? atoi(argv[5]) : 0;
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
    uint64_t lat_errors = 0;
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
                    top->in_valid = 1;
                    top->clk = 0;
                    top->eval();  // combinational result settles (clk low)
                    int cycles = 0;
                    do {
                        top->clk = 1;
                        top->eval();  // posedge captures y/flags/cmp / iterates
                        top->clk = 0;
                        top->eval();
                        top->in_valid = 0;
                        cycles++;
                    } while (iter && (op == 3 || op == 4)
                             && !top->out_valid && cycles < 1024);
                    if (iter && divsqrt_cycles > 0) {
                        const int want = (op == 3 || op == 4) ? divsqrt_cycles : 1;
                        if (cycles != want) {
                            if (lat_errors < 5)
                                fprintf(stderr, "LATENCY op=%d: %d cycles, want %d\n",
                                        op, cycles, want);
                            lat_errors++;
                        }
                    }
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
    // Write Verilator line/toggle coverage next to the expected file (the
    // build dir for this width), so `make coverage` can merge the per-width
    // exhaustive runs with the soak runs.
    {
        std::string p(argv[1]);
        size_t slash = p.find_last_of('/');
        std::string dir = (slash == std::string::npos) ? "." : p.substr(0, slash);
        VerilatedCov::write((dir + "/coverage.dat").c_str());
    }
    delete top;

    fprintf(stderr, "EXHAUSTIVE %llu vectors: %s (%llu mismatches, %llu latency errors)\n",
            (unsigned long long)total, (errors || lat_errors) ? "FAIL" : "PASS",
            (unsigned long long)errors, (unsigned long long)lat_errors);
    return (errors || lat_errors) ? 1 : 0;
}
