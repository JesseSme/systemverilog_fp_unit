// Standalone Verilator C++ harness for the cross-width randomized soak.
//
// Replays a vector stream written by tests/soak.py (the bit-exact reference
// oracle) through an fp_unit instance and compares the result. Operands are
// stored alongside the expected (y, flags, cmp) so no PRNG needs to be shared
// between Python and C++.
//
// Expected file layout (little-endian, one record per vector, N = filesize /
// record_size): for each of N vectors:
//   a (opbytes), b (opbytes), y (opbytes), uint8 flags, uint8 cmp,
//   uint8 op, uint8 rm
// where opbytes = ceil(width / 8) bytes per field (width <= 64); y is the
// width-wide result.

#include "Vfp_unit.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>

static uint64_t read_le(const uint8_t* p, int n) {
    uint64_t v = 0;
    for (int i = 0; i < n; i++) v |= (uint64_t)p[i] << (8 * i);
    return v;
}

int main(int argc, char** argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <expected.bin> <width> <c>\n", argv[0]);
        return 2;
    }
    const char* path = argv[1];
    const int w = atoi(argv[2]);
    const int C = atoi(argv[3]);
    const int opbytes = (w + 7) / 8;
    if (opbytes > 8) {
        fprintf(stderr, "width %d too wide for the soak harness (max 64)\n", w);
        return 2;
    }
    const uint64_t rec = 3 * (uint64_t)opbytes + 4;

    Verilated::commandArgs(argc, argv);
    Vfp_unit* top = new Vfp_unit;
    top->clk = 0;
    top->rst_n = 1;  // synchronous active-low reset released before vectors

    FILE* f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "cannot open %s\n", path);
        return 2;
    }
    fseek(f, 0, SEEK_END);
    const long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (size <= 0 || (size % (long)rec) != 0) {
        fprintf(stderr, "expected file %s size %ld not a multiple of record %llu\n",
                path, size, (unsigned long long)rec);
        return 2;
    }
    const uint64_t N = (uint64_t)size / rec;

    uint8_t buf[8 + 8 + 8 + 4];
    uint64_t errors = 0;
    for (uint64_t i = 0; i < N; i++) {
        if (fread(buf, 1, rec, f) != rec) {
            fprintf(stderr, "truncated expected file\n");
            return 2;
        }
        const uint64_t a = read_le(buf, opbytes);
        const uint64_t b = read_le(buf + opbytes, opbytes);
        const uint64_t exp_y = read_le(buf + 2 * opbytes, opbytes);
        const uint8_t exp_flags = buf[3 * opbytes];
        const uint8_t exp_cmp = buf[3 * opbytes + 1];
        const uint8_t op = buf[3 * opbytes + 2];
        const uint8_t rm = buf[3 * opbytes + 3];
        top->mode = op;
        top->rm = rm;
        top->a = a;
        top->b = b;
        top->c = C;
        top->clk = 0;
        top->eval();  // combinational result settles (clk low)
        top->clk = 1;
        top->eval();  // posedge captures y/flags/cmp
        const uint64_t y = top->y;
        const uint8_t flags = top->flags;
        const uint8_t cmp = top->cmp;
        if (y != exp_y || flags != exp_flags || cmp != exp_cmp) {
            if (errors < 20)
                fprintf(stderr,
                        "MISMATCH vec=%llu a=%0*x b=%0*x: got y=%0*x flags=%02x cmp=%02x, "
                        "want y=%0*x flags=%02x cmp=%02x\n",
                        (unsigned long long)i, (w + 3) / 4, (unsigned)a,
                        (w + 3) / 4, (unsigned)b,
                        (w + 3) / 4, (unsigned)y, flags, cmp,
                        (w + 3) / 4, (unsigned)exp_y, exp_flags, exp_cmp);
            errors++;
        }
    }
    fclose(f);

    top->final();
    delete top;

    fprintf(stderr, "SOAK %llu vectors: %s (%llu mismatches)\n",
            (unsigned long long)N, errors ? "FAIL" : "PASS", (unsigned long long)errors);
    return errors ? 1 : 0;
}
