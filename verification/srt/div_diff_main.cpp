// Copyright 2026 Jesse Smedberg
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Streaming differential: jsm_fp_div_srt vs combinational jsm_fp_div.
// One start per cycle; each pipelined result is compared against the
// combinational divider evaluated on the operands that started it (FIFO).
//
// Usage: div_srt_diff <W_EXP> <W_MANT> [N] [seed]

#include "Vdiv_srt_diff_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>

static uint64_t rng_state = 1;
static uint64_t rnd64() {
    uint64_t x = rng_state;
    x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
    rng_state = x;
    return x * 0x2545F4914F6CDD1DULL;
}
static uint32_t rnd32() { return (uint32_t)(rnd64() >> 32); }

struct Op { uint64_t a, b; uint32_t rm; };

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s W_EXP W_MANT [N] [seed]\n", argv[0]); return 2; }
    const int wexp = atoi(argv[1]);
    const int wmant = atoi(argv[2]);
    const uint64_t N = (argc > 3) ? strtoull(argv[3], nullptr, 0) : 1000000;
    rng_state = (argc > 4) ? strtoull(argv[4], nullptr, 0) : 0x123456789abcdefULL;
    const int w = 1 + wexp + wmant;
    const uint64_t mask = (w >= 64) ? ~0ull : ((1ull << w) - 1);
    const int emaxf = (1 << wexp) - 2;
    const uint64_t mmask = (wmant > 0) ? ((1ull << wmant) - 1) : 0;

    auto enc = [&](int sign, int exp, uint64_t mant) -> uint64_t {
        int e = exp < 0 ? 0 : (exp > emaxf ? emaxf : exp);
        return ((uint64_t)(sign & 1) << (w - 1)) | ((uint64_t)e << wmant) | (mant & mmask);
    };
    const int bias = (1 << (wexp - 1)) - 1;
    const int exp_all = (1 << wexp) - 1;
    auto rand_op = [&]() -> uint64_t {
        const uint32_t s = rnd32() & 1;
        const uint32_t pick = rnd32() % 100;
        int e;
        if (pick < 8) return enc(s, exp_all, (rnd32() % 3 == 0) ? 0 : 1);      // inf/NaN
        if (pick < 16) return enc(s, 0, rnd32() % 3 == 0 ? 0 : rnd64());       // zero/sub
        if (pick < 30) e = 0;
        else if (pick < 45) e = 1;
        else if (pick < 60) e = bias + (int)(rnd32() % 4) - 2;
        else if (pick < 80) e = (int)(rnd32() % (emaxf + 1));
        else e = emaxf - (int)(rnd32() % 4);
        return enc(s, e, rnd64());
    };

    Verilated::commandArgs(argc, argv);
    Vdiv_srt_diff_top* top = new Vdiv_srt_diff_top;
    top->clk = 0; top->rst_n = 0; top->start = 0; top->a = 0; top->b = 0; top->rm = 0;
    top->eval();
    for (int i = 0; i < 4; i++) { top->clk = 1; top->eval(); top->clk = 0; top->eval(); }
    top->rst_n = 1; top->eval();

    std::deque<Op> q;
    uint64_t mism = 0;
    const uint64_t total = N + 64;
    for (uint64_t i = 0; i < total; i++) {
        Op cur{0, 0, 0};
        if (i < N) {
            cur.a = rand_op() & mask;
            cur.b = rand_op() & mask;
            cur.rm = rnd32() % 5;
            q.push_back(cur);
            top->a = cur.a; top->b = cur.b; top->rm = cur.rm; top->start = 1;
        } else {
            top->start = 0;
        }
        top->clk = 1; top->eval();
        top->clk = 0; top->eval();

        if (top->pipe_valid) {
            if (!q.empty()) {
                const Op e = q.front(); q.pop_front();
                top->a = e.a; top->b = e.b; top->rm = e.rm; top->eval();
                const uint64_t yp = top->y_pipe & mask, yc = top->y_comb & mask;
                if (yp != yc || top->flags_pipe != top->flags_comb) {
                    if (mism < 10)
                        fprintf(stderr, "MISMATCH start=%llu a=%0*llx b=%0*llx rm=%u: "
                                "srt y=%0*llx f=%02x, comb y=%0*llx f=%02x\n",
                                (unsigned long long)i, (w+3)/4, (unsigned long long)e.a,
                                (w+3)/4, (unsigned long long)e.b, e.rm,
                                (w+3)/4, (unsigned long long)yp, top->flags_pipe,
                                (w+3)/4, (unsigned long long)yc, top->flags_comb);
                    mism++;
                }
                if (i < N) { top->a = cur.a; top->b = cur.b; top->rm = cur.rm; }
                top->eval();
            }
        }
    }
    top->final();
    delete top;
    fprintf(stderr, "DIV_SRT W_EXP=%d W_MANT=%d N=%llu: %s (%llu mismatches)\n",
            wexp, wmant, (unsigned long long)N, mism ? "FAIL" : "PASS",
            (unsigned long long)mism);
    return mism ? 1 : 0;
}
