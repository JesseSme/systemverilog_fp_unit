// Copyright 2026 Jesse Smedberg
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// AXI4-Stream wrapper of jsm_fp_unit: full backpressure on both sides and
// results in request order.
//
// Request stream (slave, S_AXIS): one operation per beat.
//   s_axis_tdata  [OPB-1:0]          a            (OPB = W rounded up to bytes)
//                 [2*OPB-1:OPB]      b
//                 [3*OPB-1:2*OPB]    c            (FMA addend; ignored otherwise)
//                 [3*OPB+3:3*OPB]    opcode       (jsm_fp_pkg::op_t)
//                 [3*OPB+6:3*OPB+4]  rounding mode / variant (jsm_fp_pkg::rounding_t)
//                 [3*OPB+7]          reserved, 0
//   s_axis_tuser, s_axis_tlast       passed through unchanged with the result
//
// Result stream (master, M_AXIS): one beat per request, in request order.
//   m_axis_tdata  [OPB-1:0]          y (zero-extended above W)
//                 [OPB+4:OPB]        flags {invalid, divByZero, overflow, underflow, inexact}
//                 [OPB+6:OPB+5]      cmp
//                 [OPB+7]            0
//   m_axis_tuser, m_axis_tlast       the request's tuser / tlast
//
// Structure: a 2-register skid buffer on the request side keeps s_axis_tready
// a registered signal (jsm_fp_unit's in_ready depends on the opcode) and
// feeds the unit from a register; a
// reorder buffer of ROB_N entries holds every request from issue to output.
// The issue slot is the jsm_fp_unit tag, results are written into their
// slot when they complete (in any order) and leave from the head in issue
// order. A request is issued only while a slot is free, so a stalled
// m_axis_tready never loses a result. With the default depth (latency + 2,
// rounded up to a power of two) the wrapper sustains one operation per cycle
// whenever m_axis_tready is high; stalls then come only from jsm_fp_unit's
// result-port conflicts between operations of different latency.
//
// aresetn is synchronous and active low.

module jsm_fp_unit_axis #(
  parameter int W_EXP        = 8,
  parameter int W_MANT       = 23,
  parameter int DIVSQRT_IMPL = 1,
  parameter int OPS_EN       = 32'h0000FFFF,  // operation enable mask (see jsm_fp_unit)
  parameter int TUSER_W      = 1,             // s_axis_tuser / m_axis_tuser width (>= 1)
  parameter int DEPTH        = 0,             // reorder-buffer entries; 0 = automatic
  // derived (do not override)
  parameter int W            = 1 + W_EXP + W_MANT,
  parameter int OPB          = ((W + 7) / 8) * 8,
  parameter int S_TDATA_W    = 3 * OPB + 8,
  parameter int M_TDATA_W    = OPB + 8
) (
  input  logic                  aclk,
  input  logic                  aresetn,
  // requests
  input  logic                  s_axis_tvalid,
  output logic                  s_axis_tready,
  input  logic [S_TDATA_W-1:0]  s_axis_tdata,
  input  logic [TUSER_W-1:0]    s_axis_tuser,
  input  logic                  s_axis_tlast,
  // results
  output logic                  m_axis_tvalid,
  input  logic                  m_axis_tready,
  output logic [M_TDATA_W-1:0]  m_axis_tdata,
  output logic [TUSER_W-1:0]    m_axis_tuser,
  output logic                  m_axis_tlast
);

  localparam int MAXLAT = jsm_fp_pkg::max_latency(W_MANT, DIVSQRT_IMPL);
  localparam int ROB_R  = (DEPTH > 0) ? DEPTH : MAXLAT + 2;
  localparam int AW     = (ROB_R <= 2) ? 1 : $clog2(ROB_R);
  localparam int ROB_N  = 1 << AW;
  localparam int SB_W   = S_TDATA_W + TUSER_W + 1;      // skid entry
  localparam int RES_W  = W + 5 + 2;                    // y, flags, cmp

  if (TUSER_W < 1) begin : g_chk_tuser
    $error("jsm_fp_unit_axis: TUSER_W = %0d must be at least 1", TUSER_W);
  end
  if (DEPTH < 0) begin : g_chk_depth
    $error("jsm_fp_unit_axis: DEPTH = %0d must be >= 0", DEPTH);
  end

  // ---------------------------------------------------- request skid buffer
  // Two registers: `hd` feeds jsm_fp_unit directly (no read mux in front of
  // its first pipeline stages), `sp` catches the beat that arrives while hd
  // is full and not issuing. s_axis_tready = !sp_v is a register.
  logic [SB_W-1:0] hd_r, sp_r;
  logic            hd_v, sp_v;
  logic            sb_push, sb_pop;
  logic [SB_W-1:0] sb_head;
  logic [SB_W-1:0] s_beat;

  assign s_axis_tready = !sp_v;
  assign sb_push       = s_axis_tvalid && s_axis_tready;
  assign s_beat        = {s_axis_tlast, s_axis_tuser, s_axis_tdata};
  assign sb_head       = hd_r;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      hd_v <= 1'b0;
      sp_v <= 1'b0;
    end else if (sb_pop) begin
      // hd issues: refill it from sp, else from the incoming beat (sb_push
      // implies !sp_v), else it empties
      if (sp_v) begin
        hd_r <= sp_r;
        sp_v <= 1'b0;
      end else if (sb_push) begin
        hd_r <= s_beat;
      end else begin
        hd_v <= 1'b0;
      end
    end else if (sb_push) begin
      if (!hd_v) begin
        hd_r <= s_beat;
        hd_v <= 1'b1;
      end else begin
        sp_r <= s_beat;
        sp_v <= 1'b1;
      end
    end
  end

  // (the reserved bit and the padding of a/b/c above W are ignored)
  /* verilator lint_off UNUSEDSIGNAL */
  logic [S_TDATA_W-1:0] q_data;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [TUSER_W-1:0]   q_user;
  logic                 q_last;
  assign {q_last, q_user, q_data} = sb_head;

  // ---------------------------------------------------- reorder buffer state
  logic [AW-1:0]  rob_wp, rob_rp;
  logic [AW:0]    rob_cnt;
  logic [ROB_N-1:0] rob_vld;
  logic [RES_W-1:0] rob_res  [ROB_N];
  logic [TUSER_W:0] rob_side [ROB_N];   // {tlast, tuser}
  logic           issue, pop;

  // ---------------------------------------------------- jsm_fp_unit
  logic             fpu_in_ready, fpu_out_valid;
  logic [W-1:0]     fpu_y;
  logic [1:0]       fpu_cmp;
  logic [4:0]       fpu_flags;
  logic [AW-1:0]    fpu_out_tag;
  logic             fpu_in_valid;

  assign fpu_in_valid = hd_v && (rob_cnt != (AW+1)'(ROB_N));
  assign issue        = fpu_in_valid && fpu_in_ready;
  assign sb_pop       = issue;

  jsm_fp_unit #(
    .W_EXP(W_EXP), .W_MANT(W_MANT), .DIVSQRT_IMPL(DIVSQRT_IMPL),
    .TAG_W(AW), .OPS_EN(OPS_EN[15:0])
  ) u_fp_unit (
    .clk(aclk), .rst_n(aresetn),
    .in_valid(fpu_in_valid), .in_ready(fpu_in_ready),
    .mode(jsm_fp_pkg::op_t'(q_data[3*OPB +: 4])),
    .rm(jsm_fp_pkg::rounding_t'(q_data[3*OPB+4 +: 3])),
    .a(q_data[0 +: W]), .b(q_data[OPB +: W]), .c(q_data[2*OPB +: W]),
    .in_tag(rob_wp),
    .y(fpu_y), .cmp(fpu_cmp), .flags(fpu_flags),
    .out_valid(fpu_out_valid), .out_tag(fpu_out_tag)
  );

  // ---------------------------------------------------- reorder buffer
  // A slot is allocated at issue (wp), filled when its result arrives
  // (out_tag) and freed when it leaves from the head (rp). The slot being
  // filled is always in flight and the slot being freed is always valid, so
  // the set and the clear of rob_vld never hit the same entry.
  assign m_axis_tvalid = rob_vld[rob_rp];
  assign pop           = m_axis_tvalid && m_axis_tready;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      rob_wp  <= '0;
      rob_rp  <= '0;
      rob_cnt <= '0;
      rob_vld <= '0;
    end else begin
      if (issue) begin
        rob_side[rob_wp] <= {q_last, q_user};
        rob_wp           <= rob_wp + 1'b1;
      end
      if (fpu_out_valid) begin
        rob_res[fpu_out_tag] <= {fpu_cmp, fpu_flags, fpu_y};
        rob_vld[fpu_out_tag] <= 1'b1;
      end
      if (pop) begin
        rob_vld[rob_rp] <= 1'b0;
        rob_rp          <= rob_rp + 1'b1;
      end
      rob_cnt <= rob_cnt + (AW+1)'(issue) - (AW+1)'(pop);
    end
  end

  logic [RES_W-1:0] head_res;
  logic [TUSER_W:0] head_side;
  assign head_res  = rob_res[rob_rp];
  assign head_side = rob_side[rob_rp];

  assign m_axis_tdata = {1'b0, head_res[W+6 -: 2], head_res[W+4 -: 5],
                         (OPB)'(head_res[W-1:0])};
  assign {m_axis_tlast, m_axis_tuser} = head_side;

endmodule
