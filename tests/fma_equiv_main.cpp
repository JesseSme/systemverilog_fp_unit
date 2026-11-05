// Copyright 2026 Jesse Smedberg
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Verilator harness: jsm_fp_fma_pipe == jsm_fp_fma (tests/fma_equiv_tb.sv).
//
//   fma_equiv <w_exp> <w_mant> <lat> <n>
//
// n = 0: every (rm, a, b, c) combination (formats up to 8 bits), one vector
// per cycle, back to back. n > 0: n random vectors, biased towards the
// hard cases: special exponents and significands, and c close to -a*b
// (massive cancellation), c far above / below a*b (alignment saturation and
// sticky), subnormal factors. Random gaps in `start` check the valid
// pipeline. The pipeline result must equal the reference result of the
// vector applied exactly lat cycles earlier, and out_valid must follow start
// with the same latency.

#include "Vfma_equiv_tb.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>

struct Exp {
    uint64_t y;
    uint32_t f;
    bool v;
    uint64_t a, b, c;
    uint32_t rm;
};

static uint64_t rng_state = 0x9e3779b97f4a7c15ull;
static uint64_t rnd() {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return rng_state;
}

int main(int argc, char** argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s <w_exp> <w_mant> <lat> <n>\n", argv[0]);
        return 2;
    }
    const int we = atoi(argv[1]);
    const int wm = atoi(argv[2]);
    const int lat = atoi(argv[3]);
    const uint64_t n = strtoull(argv[4], nullptr, 10);
    const int w = 1 + we + wm;
    const uint64_t wmask = (w == 64) ? ~0ull : ((1ull << w) - 1);
    const uint64_t emax_f = (1ull << we) - 1;
    const uint64_t mmask = (1ull << wm) - 1;
    const int64_t bias = (1ll << (we - 1)) - 1;

    Verilated::commandArgs(argc, argv);
    Vfma_equiv_tb* top = new Vfma_equiv_tb;
    top->clk = 0;
    top->rst_n = 0;
    top->start = 0;
    top->eval();
    for (int i = 0; i < 4; i++) {
        top->clk = 1; top->eval();
        top->clk = 0; top->eval();
    }
    top->rst_n = 1;
    top->eval();

    auto pack = [&](uint64_t s, uint64_t e, uint64_t m) {
        return ((s << (we + wm)) | (e << wm) | (m & mmask)) & wmask;
    };
    auto rnd_mant = [&]() -> uint64_t {
        switch (rnd() % 6) {
            case 0: return 0;
            case 1: return 1;
            case 2: return mmask;
            case 3: return mmask - (rnd() % 4);
            default: return rnd() & mmask;
        }
    };
    auto rnd_exp = [&]() -> uint64_t {
        switch (rnd() % 8) {
            case 0: return 0;
            case 1: return 1;
            case 2: return emax_f - 1;
            case 3: return emax_f;
            default: return 1 + rnd() % (emax_f - 1);
        }
    };
    auto clampe = [&](int64_t e) -> uint64_t {
        if (e < 0) return 0;
        if (e > (int64_t)emax_f) return emax_f;
        return (uint64_t)e;
    };

    std::deque<Exp> pipe;  // one entry per cycle, oldest first
    uint64_t errors = 0, checked = 0, cycles = 0;
    const uint64_t total = n ? n : (5ull << (3 * w));

    uint64_t pending = 0;  // valid entries in `pipe`
    for (uint64_t i = 0; i < total || pending; ) {
        Exp e{};
        if (i < total && (n == 0 || rnd() % 16 != 0)) {
            uint64_t a, b, c, rm;
            if (n == 0) {
                uint64_t x = i;
                c = x & wmask; x >>= w;
                b = x & wmask; x >>= w;
                a = x & wmask; x >>= w;
                rm = x;
            } else {
                rm = rnd() % 5;
                uint64_t ea = rnd_exp(), eb = rnd_exp();
                if (rnd() % 4 == 0) ea = rnd() % 3;  // subnormal factors
                a = pack(rnd() & 1, ea, rnd_mant());
                b = pack(rnd() & 1, eb, rnd_mant());
                int64_t ep = (int64_t)ea + (int64_t)eb - bias;
                switch (rnd() % 6) {
                    case 0:   // c close to -a*b or a*b: cancellation
                    case 1:
                        c = pack(rnd() & 1, clampe(ep + (int64_t)(rnd() % 5) - 2), rnd_mant());
                        break;
                    case 2:   // c far above or below the product
                        c = pack(rnd() & 1, clampe(ep + (int64_t)(rnd() % (4 * wm + 16))
                                                   - (2 * wm + 8)), rnd_mant());
                        break;
                    case 3:
                        c = pack(rnd() & 1, rnd_exp(), rnd_mant());
                        break;
                    default:
                        c = rnd() & wmask;
                        break;
                }
                if (rnd() % 8 == 0) {  // exact negated product for the narrow formats
                    c = pack(rnd() & 1, clampe(ep), rnd() & mmask);
                }
            }
            top->a = a; top->b = b; top->c = c; top->rm = rm;
            top->start = 1;
            top->eval();
            e = Exp{top->y_c, top->f_c, true, a, b, c, (uint32_t)rm};
            i++;
        } else {
            top->start = 0;
            top->eval();
        }
        pipe.push_back(e);
        if (e.v) pending++;

        top->clk = 1; top->eval();
        top->clk = 0; top->eval();
        cycles++;

        if ((int)pipe.size() == lat) {
            Exp x = pipe.front();
            pipe.pop_front();
            if (x.v) pending--;
            if (top->v_p != x.v) {
                if (errors < 20)
                    fprintf(stderr, "cycle %llu: out_valid %d, expected %d\n",
                            (unsigned long long)cycles, top->v_p, x.v);
                errors++;
            } else if (x.v) {
                checked++;
                if (top->y_p != x.y || top->f_p != x.f) {
                    if (errors < 20)
                        fprintf(stderr,
                                "MISMATCH rm=%u a=%llx b=%llx c=%llx: pipe y=%llx f=%02x, ref y=%llx f=%02x\n",
                                x.rm, (unsigned long long)x.a, (unsigned long long)x.b,
                                (unsigned long long)x.c, (unsigned long long)top->y_p, top->f_p,
                                (unsigned long long)x.y, x.f);
                    errors++;
                }
            }
        }
    }
    printf("FMA EQUIV (%d,%d) lat %d: %llu vectors, %llu errors\n", we, wm, lat,
           (unsigned long long)checked, (unsigned long long)errors);
    delete top;
    return errors ? 1 : 0;
}
