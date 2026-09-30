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
#include "verilated_cov.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>

static uint64_t read_le(const uint8_t* p, int n) {
    uint64_t v = 0;
    for (int i = 0; i < n; i++) v |= (uint64_t)p[i] << (8 * i);
    return v;
}

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
    uint64_t lat_errors = 0;
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
        } while (iter && (op == 3 || op == 4) && !top->out_valid && cycles < 1024);
        if (iter && divsqrt_cycles > 0) {
            const int want = (op == 3 || op == 4) ? divsqrt_cycles : 1;
            if (cycles != want) {
                if (lat_errors < 5)
                    fprintf(stderr, "LATENCY op=%d: %d cycles, want %d\n",
                            op, cycles, want);
                lat_errors++;
            }
        }
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
    // Write Verilator line/toggle coverage next to the expected file (the
    // build dir for this width), so `make coverage` can merge per-width runs.
    {
        std::string p(argv[1]);
        size_t slash = p.find_last_of('/');
        std::string dir = (slash == std::string::npos) ? "." : p.substr(0, slash);
        VerilatedCov::write((dir + "/coverage.dat").c_str());
    }
    delete top;

    fprintf(stderr, "SOAK %llu vectors: %s (%llu mismatches, %llu latency errors)\n",
            (unsigned long long)N, (errors || lat_errors) ? "FAIL" : "PASS",
            (unsigned long long)errors, (unsigned long long)lat_errors);
    return (errors || lat_errors) ? 1 : 0;
}
