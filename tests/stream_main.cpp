// Copyright 2026 Jesse Smedberg
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Standalone Verilator C++ harness: streaming / mixed-issue test of jsm_fp_unit.
//
// Replays the soak vector file (tests/soak.py record layout) through jsm_fp_unit
// with a new request offered EVERY cycle (in_valid held high; a request is
// accepted when in_ready is high at the clock edge). Each request carries
// its record index as the tag (jsm_fp_unit built with TAG_W = 32); every
// out_valid is matched to its request through out_tag and compared against
// the oracle record. At the end every accepted request must have completed
// exactly once (no lost, duplicated or unknown results).
//
// Modes:
//   mixed  records issued in file order (random op per record): exercises
//          the result-port reservation (in_ready) and out-of-order return.
//   same   records grouped by op; each group is issued back-to-back and the
//          pipeline is drained between groups: every pipeline must accept
//          one request per cycle (stall count 0) unless it is declared
//          non-streaming via the optional per-op "expected stall" list.
//
// Usage: fp_stream <expected.bin> <width> <c> <mixed|same> [nostall_mask]
//   nostall_mask: bit i set = op i must never stall in `same` mode
//   (default: all ops).
//
// Output: one "STREAM op=<i> issued=<n> stalls=<s> cycles=<c>" line per op
// (same mode) and a final status line; exit status 0 iff PASS.

#include "Vjsm_fp_unit.h"
#include "verilated.h"
#ifndef NUM_OPS
#error "NUM_OPS must be defined by the driver (-CFLAGS -DNUM_OPS=<n>)"
#endif
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

struct Rec {
    uint64_t a, b, y;
    uint8_t flags, cmp, op, rm;
};

static uint64_t read_le(const uint8_t* p, int n) {
    uint64_t v = 0;
    for (int i = 0; i < n; i++) v |= (uint64_t)p[i] << (8 * i);
    return v;
}

int main(int argc, char** argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: %s <expected.bin> <width> <c> <mixed|same> [nostall_mask]\n",
                argv[0]);
        return 2;
    }
    const char* path = argv[1];
    const int w = atoi(argv[2]);
    const uint64_t C = strtoull(argv[3], nullptr, 10);
    const bool same = strcmp(argv[4], "same") == 0;
    const uint64_t nostall = (argc > 5) ? strtoull(argv[5], nullptr, 0) : ~0ull;
    const int opbytes = (w + 7) / 8;
    const uint64_t rec_sz = 3 * (uint64_t)opbytes + 4;

    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return 2; }
    std::vector<Rec> recs;
    uint8_t buf[32];
    while (fread(buf, 1, rec_sz, f) == rec_sz) {
        Rec r;
        r.a = read_le(buf, opbytes);
        r.b = read_le(buf + opbytes, opbytes);
        r.y = read_le(buf + 2 * opbytes, opbytes);
        r.flags = buf[3 * opbytes];
        r.cmp = buf[3 * opbytes + 1];
        r.op = buf[3 * opbytes + 2];
        r.rm = buf[3 * opbytes + 3];
        recs.push_back(r);
    }
    fclose(f);
    const size_t N = recs.size();
    if (N == 0) { fprintf(stderr, "empty expected file\n"); return 2; }

    // Issue order (+ group boundaries for `same`).
    std::vector<uint32_t> order;
    std::vector<size_t> group_start;  // index into order where op group starts
    if (same) {
        for (int op = 0; op < NUM_OPS; op++) {
            group_start.push_back(order.size());
            for (size_t i = 0; i < N; i++)
                if (recs[i].op == op) order.push_back((uint32_t)i);
        }
    } else {
        for (size_t i = 0; i < N; i++) order.push_back((uint32_t)i);
    }
    group_start.push_back(order.size());

    Verilated::commandArgs(argc, argv);
    Vjsm_fp_unit* top = new Vjsm_fp_unit;
    auto tick = [&]() {
        top->clk = 1; top->eval();
        top->clk = 0; top->eval();
    };
    top->clk = 0; top->rst_n = 0; top->in_valid = 0; top->eval();
    for (int i = 0; i < 4; i++) tick();
    top->rst_n = 1; top->eval();

    std::vector<uint8_t> state(N, 0);  // 0 = not issued, 1 = in flight, 2 = done
    uint64_t errors = 0, issued = 0, completed = 0, cycles = 0, inflight = 0;
    uint64_t stalls[NUM_OPS] = {0}, n_op[NUM_OPS] = {0}, cyc_op[NUM_OPS] = {0};
    size_t pos = 0;
    int group = 0;
    const uint64_t max_cycles = 64ull * N + 100000;

    auto report = [&](const char* what, uint32_t tag) {
        if (errors < 50) fprintf(stderr, "%s tag=%u\n", what, tag);
        errors++;
    };

    while ((pos < order.size() || inflight) && cycles < max_cycles) {
        // In `same` mode a group may only start once the previous drained.
        bool offer = pos < order.size();
        if (same && offer) {
            while (group + 1 < (int)group_start.size() && pos >= group_start[group + 1]) group++;
            if (pos == group_start[group] && inflight) offer = false;  // drain first
        }
        const Rec* r = nullptr;
        uint32_t idx = 0;
        if (offer) {
            idx = order[pos];
            r = &recs[idx];
            top->mode = r->op;
            top->rm = r->rm;
            top->a = r->a;
            top->b = r->b;
            top->c = C;
            top->in_tag = idx;
            top->in_valid = 1;
        } else {
            top->in_valid = 0;
        }
        top->eval();  // combinational in_ready, current outputs

        // Result port (registered state of this cycle).
        if (top->out_valid) {
            const uint32_t tag = top->out_tag;
            if (tag >= N || state[tag] != 1) {
                report(tag >= N ? "UNKNOWN tag" : "UNEXPECTED (not in flight) tag", tag);
            } else {
                const Rec& e = recs[tag];
                const uint64_t ymask = (w >= 64) ? ~0ull : ((1ull << w) - 1);
                const uint64_t y = (uint64_t)top->y & ymask;
                if (y != e.y || top->flags != e.flags || top->cmp != e.cmp) {
                    if (errors < 50)
                        fprintf(stderr,
                                "MISMATCH tag=%u op=%d rm=%d a=%llx b=%llx: got y=%llx "
                                "flags=%02x cmp=%d, want y=%llx flags=%02x cmp=%d\n",
                                tag, e.op, e.rm, (unsigned long long)e.a,
                                (unsigned long long)e.b, (unsigned long long)y,
                                top->flags, top->cmp, (unsigned long long)e.y, e.flags,
                                e.cmp);
                    errors++;
                }
                state[tag] = 2;
                completed++;
                inflight--;
            }
        }

        const bool fired = offer && top->in_ready;
        if (offer) {
            if (fired) {
                state[idx] = 1;
                issued++;
                inflight++;
                n_op[r->op]++;
                pos++;
            } else {
                stalls[r->op]++;
            }
            cyc_op[r->op]++;
        }
        tick();
        cycles++;
    }
    top->final();
    delete top;

    for (size_t i = 0; i < N; i++)
        if (state[i] != 2) {
            report(state[i] == 0 ? "NEVER ISSUED" : "LOST (no out_valid)", (uint32_t)i);
        }

    bool stall_fail = false;
    uint64_t total_stalls = 0;
    for (int op = 0; op < NUM_OPS; op++) {
        total_stalls += stalls[op];
        if (same) {
            printf("STREAM op=%d issued=%llu stalls=%llu cycles=%llu\n", op,
                   (unsigned long long)n_op[op], (unsigned long long)stalls[op],
                   (unsigned long long)cyc_op[op]);
            if (((nostall >> op) & 1) && stalls[op]) {
                fprintf(stderr, "STALL op=%d: %llu stall cycles in back-to-back issue\n", op,
                        (unsigned long long)stalls[op]);
                stall_fail = true;
            }
        }
    }
    const bool ok = !errors && !stall_fail && completed == N && cycles < max_cycles;
    fprintf(stderr,
            "STREAM %s %zu vectors: %s (%llu errors, %llu completed, %llu cycles, "
            "%llu stall cycles, issue rate %.3f)\n",
            same ? "same-op" : "mixed", N, ok ? "PASS" : "FAIL",
            (unsigned long long)errors, (unsigned long long)completed,
            (unsigned long long)cycles, (unsigned long long)total_stalls,
            cycles ? (double)issued / (double)cycles : 0.0);
    return ok ? 0 : 1;
}
