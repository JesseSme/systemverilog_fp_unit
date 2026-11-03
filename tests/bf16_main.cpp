// Standalone Verilator C++ harness for rtl/fp32_to_bf16_round.sv.
//
// Phase 1: replay oracle records written by tests/bf16.py (uint32 x,
//          uint16 y; the bit-exact Python reference f32_to_bf16_rne) and
//          compare the DUT and the C++ rule below against each of them.
// Phase 2: sweep ALL 2^32 inputs and compare the DUT against the C++ rule
//          (validated against the oracle in phase 1).
//
// Usage: fp_bf16 <oracle.bin> [stride]   (stride > 1 samples the sweep)

#include "Vfp32_to_bf16_round.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static uint16_t rule(uint32_t x) {
    const uint32_t e = (x >> 23) & 0xFF, m = x & 0x7FFFFF;
    const uint16_t hi = (uint16_t)(x >> 16);
    if (e == 0xFF) {
        if (m) return (uint16_t)(((x >> 31) << 15) | 0x7F80 | 0x40 | ((x >> 16) & 0x3F));
        return hi;
    }
    const bool g = (x >> 15) & 1, st = (x & 0x7FFF) != 0, l = (x >> 16) & 1;
    return (uint16_t)(hi + ((g && (st || l)) ? 1 : 0));
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <oracle.bin> [stride]\n", argv[0]); return 2; }
    const uint64_t stride = (argc > 2) ? strtoull(argv[2], nullptr, 0) : 1;
    Verilated::commandArgs(argc, argv);
    Vfp32_to_bf16_round* top = new Vfp32_to_bf16_round;
    uint64_t errors = 0, n_oracle = 0;

    FILE* f = fopen(argv[1], "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }
    uint8_t buf[6];
    while (fread(buf, 1, 6, f) == 6) {
        const uint32_t x = buf[0] | (buf[1] << 8) | (buf[2] << 16) | ((uint32_t)buf[3] << 24);
        const uint16_t want = (uint16_t)(buf[4] | (buf[5] << 8));
        top->x = x;
        top->eval();
        if (top->y != want || rule(x) != want) {
            if (errors < 20)
                fprintf(stderr, "ORACLE MISMATCH x=%08x: dut=%04x rule=%04x want=%04x\n",
                        x, top->y, rule(x), want);
            errors++;
        }
        n_oracle++;
    }
    fclose(f);

    uint64_t n_sweep = 0;
    for (uint64_t v = 0; v <= 0xFFFFFFFFull; v += stride) {
        const uint32_t x = (uint32_t)v;
        top->x = x;
        top->eval();
        if (top->y != rule(x)) {
            if (errors < 40)
                fprintf(stderr, "SWEEP MISMATCH x=%08x: dut=%04x rule=%04x\n", x, top->y, rule(x));
            errors++;
        }
        n_sweep++;
    }
    top->final();
    delete top;
    fprintf(stderr, "BF16 %llu oracle + %llu sweep vectors: %s (%llu mismatches)\n",
            (unsigned long long)n_oracle, (unsigned long long)n_sweep,
            errors ? "FAIL" : "PASS", (unsigned long long)errors);
    return errors ? 1 : 0;
}
