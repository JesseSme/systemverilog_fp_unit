// Copyright 2026 Jesse Smedberg
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Vivado xsim testbench for the AXI4-Lite tops (rtl/top/jsm_fp_unit_axilite_top.v
// and rtl/top/jsm_fp_unit_axilite_vhd.vhd), formats up to 64 bits wide.
//
// A simple AXI4-Lite master drives the same transaction sequence into both
// tops: write DATA_A/B/C (all words) and OPCODE, pulse CTRL.GO, poll
// STATUS.VALID, read RESULT/RES_CMP/STATUS, and compare with the oracle
// vector (tests/vivado/gen_vectors.py, +VEC=<file>). The two tops must return
// identical read data. Also checks the STATUS format-id field and a DECERR
// read outside the register map.

`timescale 1ns / 1ps

module tb_fp_unit_axilite_tops #(
  parameter int W_EXP        = 8,
  parameter int W_MANT       = 23,
  parameter int DIVSQRT_IMPL = 1,
  parameter int N            = 300
);
  localparam int W          = 1 + W_EXP + W_MANT;
  localparam int REG_W      = 1 << $clog2(W);
  localparam int WORDS      = (REG_W + 31) / 32;
  localparam int AW         = 6;
  localparam int A_CTRL     = 'h00;
  localparam int A_OPCODE   = 'h04;
  localparam int A_A        = 'h08;
  localparam int A_B        = A_A + 4 * WORDS;
  localparam int A_C        = A_B + 4 * WORDS;
  localparam int A_STATUS   = A_C + 4 * WORDS;
  localparam int A_RESULT   = A_STATUS + 4;
  localparam int A_CMP      = A_RESULT + 4 * WORDS;

  logic clk = 1'b0;
  always #2 clk = ~clk;
  logic aresetn = 1'b0;

  // one master, two slaves in lockstep
  logic [AW-1:0] awaddr, araddr;
  logic          awvalid, wvalid, bready, arvalid, rready;
  logic [31:0]   wdata;
  logic [3:0]    wstrb;
  logic          awready [2], wready [2], bvalid [2], arready [2], rvalid [2];
  logic [1:0]    bresp [2], rresp [2];
  logic [31:0]   rdata [2];

  jsm_fp_unit_axilite_top #(.W_EXP(W_EXP), .W_MANT(W_MANT), .ADDR_WIDTH(AW),
                        .DIVSQRT_IMPL(DIVSQRT_IMPL)) u_verilog (
    .s_axi_aclk(clk), .s_axi_aresetn(aresetn),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready[0]),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready[0]),
    .s_axi_bresp(bresp[0]), .s_axi_bvalid(bvalid[0]), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready[0]),
    .s_axi_rdata(rdata[0]), .s_axi_rresp(rresp[0]), .s_axi_rvalid(rvalid[0]), .s_axi_rready(rready));

  jsm_fp_unit_axilite_vhd #(.W_EXP(W_EXP), .W_MANT(W_MANT), .ADDR_WIDTH(AW),
                        .DIVSQRT_IMPL(DIVSQRT_IMPL)) u_vhdl (
    .s_axi_aclk(clk), .s_axi_aresetn(aresetn),
    .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready[1]),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready[1]),
    .s_axi_bresp(bresp[1]), .s_axi_bvalid(bvalid[1]), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready[1]),
    .s_axi_rdata(rdata[1]), .s_axi_rresp(rresp[1]), .s_axi_rvalid(rvalid[1]), .s_axi_rready(rready));

  int errors = 0;

  // watchdog: a handshake that never completes fails instead of hanging
  initial begin
    #(64'(N) * 4000 * 4 + 100000);
    $display("XSIM AXI TOPS W_EXP=%0d W_MANT=%0d DIVSQRT_IMPL=%0d: FAIL (watchdog timeout)",
             W_EXP, W_MANT, DIVSQRT_IMPL);
    $finish;
  end

  // Each channel handshake waits for both slaves, so they stay in lockstep.
  task automatic axi_write(input int addr, input logic [31:0] data);
    bit aw_done [2], w_done [2], b_done [2];
    aw_done = '{0, 0}; w_done = '{0, 0}; b_done = '{0, 0};
    awaddr <= AW'(addr); awvalid <= 1'b1;
    wdata <= data; wstrb <= 4'hF; wvalid <= 1'b1;
    bready <= 1'b1;
    do begin
      @(posedge clk);
      for (int s = 0; s < 2; s++) begin
        if (awready[s]) aw_done[s] = 1;
        if (wready[s])  w_done[s]  = 1;
        if (bvalid[s]) begin
          b_done[s] = 1;
          if (bresp[s] !== 2'b00) begin
            $display("ERROR: write %h -> bresp %b (slave %0d)", addr, bresp[s], s);
            errors++;
          end
        end
      end
      if (aw_done[0] && aw_done[1]) awvalid <= 1'b0;
      if (w_done[0] && w_done[1])   wvalid  <= 1'b0;
    end while (!(b_done[0] && b_done[1]));
    bready <= 1'b0;
    awvalid <= 1'b0; wvalid <= 1'b0;
    @(posedge clk);
  endtask

  task automatic axi_read(input int addr, output logic [31:0] data, output logic [1:0] resp);
    bit ar_done [2], r_done [2];
    logic [31:0] d [2];
    logic [1:0]  rr [2];
    ar_done = '{0, 0}; r_done = '{0, 0};
    araddr <= AW'(addr); arvalid <= 1'b1; rready <= 1'b1;
    do begin
      @(posedge clk);
      for (int s = 0; s < 2; s++) begin
        if (arready[s]) ar_done[s] = 1;
        if (rvalid[s] && !r_done[s]) begin r_done[s] = 1; d[s] = rdata[s]; rr[s] = rresp[s]; end
      end
      if (ar_done[0] && ar_done[1]) arvalid <= 1'b0;
    end while (!(r_done[0] && r_done[1]));
    rready <= 1'b0; arvalid <= 1'b0;
    if (d[0] !== d[1] || rr[0] !== rr[1]) begin
      $display("ERROR: read %h differs: Verilog %h/%b, VHDL %h/%b", addr, d[0], rr[0], d[1], rr[1]);
      errors++;
    end
    data = d[1];
    resp = rr[1];
    @(posedge clk);
  endtask

  initial begin
    string vec;
    int fd, k, polls;
    int unsigned op, rmv, f, cm;
    logic [127:0] av, bv, cv, yv;
    logic [31:0]  d, st;
    logic [1:0]   resp;
    logic [127:0] res;
    if (!$value$plusargs("VEC=%s", vec)) $fatal(1, "missing +VEC=<file>");
    fd = $fopen(vec, "r");
    if (fd == 0) $fatal(1, "cannot open %s", vec);

    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    awaddr = '0; araddr = '0; wdata = '0; wstrb = '0;
    repeat (4) @(posedge clk);
    aresetn <= 1'b1;
    repeat (2) @(posedge clk);

    axi_read(A_STATUS, st, resp);
    if (st[31:16] !== {8'(W_MANT), 8'(W_EXP)}) begin
      $display("ERROR: STATUS format id %h, want %h", st[31:16], {8'(W_MANT), 8'(W_EXP)});
      errors++;
    end
    axi_read(A_CMP + 4, d, resp);   // first address past the map
    if (resp !== 2'b11) begin
      $display("ERROR: read past the map: rresp %b, want DECERR", resp);
      errors++;
    end

    for (k = 0; k < N; k++) begin
      if ($fscanf(fd, "%h %h %h %h %h %h %h %h\n", op, rmv, av, bv, cv, yv, f, cm) != 8)
        $fatal(1, "short vector file at line %0d", k + 1);
      for (int w = 0; w < WORDS; w++) begin
        axi_write(A_A + 4 * w, av[32*w +: 32]);
        axi_write(A_B + 4 * w, bv[32*w +: 32]);
        axi_write(A_C + 4 * w, cv[32*w +: 32]);
      end
      axi_write(A_OPCODE, {25'd0, rmv[2:0], op[3:0]});
      axi_write(A_CTRL, 32'd0);
      axi_write(A_CTRL, 32'd1);           // GO rising edge
      polls = 0;
      do begin
        axi_read(A_STATUS, st, resp);
        polls++;
      end while (!st[9] && polls < 200);
      res = '0;
      for (int w = 0; w < WORDS; w++) begin
        axi_read(A_RESULT + 4 * w, d, resp);
        res[32*w +: 32] = d;
      end
      axi_read(A_CMP, d, resp);
      if (!st[9] || res[W-1:0] !== yv[W-1:0] || st[4:0] !== 5'(f) || d[1:0] !== 2'(cm)) begin
        if (errors < 10)
          $display("ERROR: vec %0d op=%0d rm=%0d a=%h b=%h: got valid=%b y=%h f=%b cmp=%0d, want y=%h f=%b cmp=%0d",
                   k, op, rmv, av[W-1:0], bv[W-1:0], st[9], res[W-1:0], st[4:0], d[1:0],
                   yv[W-1:0], 5'(f), 2'(cm));
        errors++;
      end
    end
    $fclose(fd);
    if (errors == 0)
      $display("XSIM AXI TOPS W_EXP=%0d W_MANT=%0d DIVSQRT_IMPL=%0d N=%0d: PASS",
               W_EXP, W_MANT, DIVSQRT_IMPL, N);
    else
      $display("XSIM AXI TOPS W_EXP=%0d W_MANT=%0d DIVSQRT_IMPL=%0d N=%0d: FAIL (%0d errors)",
               W_EXP, W_MANT, DIVSQRT_IMPL, N, errors);
    $finish;
  end

endmodule
