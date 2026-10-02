// Standalone Verilator C++ harness for the per-op latency probe.
//
// Drives a small set of representative vectors (normal, subnormal, zero, inf,
// NaN) through every op and measures the in_valid -> out_valid cycle count.
// All vectors of an op must show the same latency (fixed-latency contract).
// The probe is driven by tests/latency.py, which builds one fp_unit model per
// width and prints the per-op cycle table.
//
// Usage: fp_latency <W_EXP> <W_MANT>
//
// Output (stdout, one line per op plus a status line):
//   LATENCY op=<n> cycles=<c> vectors=<v> errors=<e>
//   LATENCY <PASS|FAIL>
//
// Exit status is 0 iff every op has a constant latency across all vectors.

#include "Vfp_unit.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <W_EXP> <W_MANT>\n", argv[0]);
        return 2;
    }
    const int wexp = atoi(argv[1]);
    const int wmant = atoi(argv[2]);
    const int w = 1 + wexp + wmant;
    const uint64_t amask = (w >= 64) ? ~0ull : ((1ull << w) - 1);
    const int bias = (1 << (wexp - 1)) - 1;
    const int emax_f = (1 << wexp) - 2;  // exponent field of the largest finite

    // Encoding helper: raw pattern from sign/exponent/mantissa fields.
    auto enc = [&](int sign, int exp, uint64_t mant) -> uint64_t {
        uint64_t e = (exp < 0) ? 0 : (exp > emax_f ? emax_f : exp);
        return ((uint64_t)sign << (w - 1)) |
               (e << wmant) | (mant & ((wmant > 0) ? ((1ull << wmant) - 1) : 0));
    };
    const uint64_t zero  = 0;
    const uint64_t one   = enc(0, bias, 0);          // 1.0 (bias is exact)
    const uint64_t two   = enc(0, bias + 1, 0);      // 2.0
    const uint64_t sub   = enc(0, 0, 1);             // smallest subnormal
    const uint64_t thinf = enc(0, emax_f + 1, 0);    // +inf (all-ones exponent, zero mant)
    const uint64_t qnan  = enc(0, emax_f + 1, (wmant > 0) ? (1ull << (wmant - 1)) : 1);

    // (a, b, c) vector list: normal, boundary and special operands.
    const uint64_t va[] = {zero, one, one, sub, qnan, thinf, one};
    const uint64_t vb[] = {zero, one, two, one, one, one, thinf};
    const uint64_t vc[] = {zero, one, zero, two, thinf, one, one};
    const int NV = (int)(sizeof(va) / sizeof(va[0]));

    Verilated::commandArgs(argc, argv);
    Vfp_unit* top = new Vfp_unit;
    top->clk = 0;
    top->rst_n = 0;
    top->in_valid = 0;
    top->mode = 0;
    top->rm = 0;
    top->a = 0;
    top->b = 0;
    top->c = 0;
    top->eval();
    for (int i = 0; i < 4; i++) {
        top->clk = 1; top->eval();
        top->clk = 0; top->eval();
    }
    top->rst_n = 1;
    top->eval();

    int total_errors = 0;
    int lat[11] = {0};
    for (int op = 0; op <= 10; op++) {
        int first = -1;
        int errors = 0;
        for (int v = 0; v < NV; v++) {
            top->mode = (uint8_t)op;
            top->rm = 0;
            top->a = va[v] & amask;
            top->b = vb[v] & amask;
            top->c = vc[v] & amask;
            top->in_valid = 1;
            top->clk = 0;
            top->eval();
            int cycles = 0;
            do {
                top->clk = 1; top->eval();   // posedge samples the start / advances
                top->clk = 0; top->eval();
                top->in_valid = 0;
                cycles++;
            } while (!top->out_valid && cycles < 4096);
            if (first < 0) {
                first = cycles;
            } else if (cycles != first) {
                errors++;
                fprintf(stderr, "LATENCY op=%d vector=%d: %d cycles (first seen %d)\n",
                        op, v, cycles, first);
            }
            if (cycles >= 4096) {
                fprintf(stderr, "LATENCY op=%d vector=%d: timeout\n", op, v);
                errors++;
            }
        }
        lat[op] = first;
        total_errors += errors;
        printf("LATENCY op=%d cycles=%d vectors=%d errors=%d\n", op, first, NV, errors);
    }
    top->final();
    delete top;
    printf("LATENCY %s\n", total_errors ? "FAIL" : "PASS");
    fprintf(stderr,
            "latency table (W_EXP=%d W_MANT=%d): "
            "add %d sub %d mul %d div %d sqrt %d fma %d min %d max %d cmp %d rndint %d totalorder %d\n",
            wexp, wmant, lat[0], lat[1], lat[2], lat[3], lat[4], lat[5], lat[6],
            lat[7], lat[8], lat[9], lat[10]);
    return total_errors ? 1 : 0;
}
