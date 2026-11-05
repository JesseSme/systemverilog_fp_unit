// Copyright 2026 Jesse Smedberg
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Vivado xsim testbench for the AXI4-Stream tops
// (rtl/top/jsm_fp_unit_axis_top.v, rtl/top/jsm_fp_unit_axis_vhd.vhd).
//
// Both tops get the same request stream (random TVALID gaps) and the same
// random M_AXIS TREADY; they must agree cycle by cycle, and every result
// must match the oracle vector of its request, in request order, with the
// request's TUSER/TLAST. Vectors: tests/vivado/gen_vectors.py (+VEC=<file>).

`timescale 1ns / 1ps

module tb_fp_unit_axis_tops #(
  parameter int W_EXP        = 8,
  parameter int W_MANT       = 23,
  parameter int DIVSQRT_IMPL = 1,
  parameter int OPS_EN       = 65535,
  parameter int N            = 2000
);
  localparam int W   = 1 + W_EXP + W_MANT;
  localparam int OPB = ((W + 7) / 8) * 8;
  localparam int SW  = 3 * OPB + 8;
  localparam int MW  = OPB + 8;
  localparam int UW  = 8;

  logic clk = 1'b0;
  always #2 clk = ~clk;
  logic aresetn = 1'b0;

  logic [3:0] v_op [N];
  logic [2:0] v_rm [N];
  logic [W-1:0] v_a [N], v_b [N], v_c [N], v_y [N];
  logic [4:0] v_f [N];
  logic [1:0] v_cmp [N];
  logic [UW-1:0] v_user [N];
  logic v_last [N];

  logic          s_valid, m_ready;
  logic [SW-1:0] s_data;
  logic [UW-1:0] s_user;
  logic          s_last;
  logic          s_ready [2], m_valid [2], m_last [2];
  logic [MW-1:0] m_data [2];
  logic [UW-1:0] m_user [2];

  jsm_fp_unit_axis_top #(.W_EXP(W_EXP), .W_MANT(W_MANT), .DIVSQRT_IMPL(DIVSQRT_IMPL),
                         .OPS_EN(OPS_EN), .TUSER_W(UW)) u_verilog (
    .aclk(clk), .aresetn(aresetn),
    .s_axis_tvalid(s_valid), .s_axis_tready(s_ready[0]), .s_axis_tdata(s_data),
    .s_axis_tuser(s_user), .s_axis_tlast(s_last),
    .m_axis_tvalid(m_valid[0]), .m_axis_tready(m_ready), .m_axis_tdata(m_data[0]),
    .m_axis_tuser(m_user[0]), .m_axis_tlast(m_last[0]));

  jsm_fp_unit_axis_vhd #(.W_EXP(W_EXP), .W_MANT(W_MANT), .DIVSQRT_IMPL(DIVSQRT_IMPL),
                         .OPS_EN(OPS_EN), .TUSER_W(UW)) u_vhdl (
    .aclk(clk), .aresetn(aresetn),
    .s_axis_tvalid(s_valid), .s_axis_tready(s_ready[1]), .s_axis_tdata(s_data),
    .s_axis_tuser(s_user), .s_axis_tlast(s_last),
    .m_axis_tvalid(m_valid[1]), .m_axis_tready(m_ready), .m_axis_tdata(m_data[1]),
    .m_axis_tuser(m_user[1]), .m_axis_tlast(m_last[1]));

  int errors = 0;
  int got = 0;

  initial begin
    #(64'(N) * 4000 * 4 + 100000);
    $display("XSIM AXIS TOPS W_EXP=%0d W_MANT=%0d DIVSQRT_IMPL=%0d: FAIL (watchdog timeout)",
             W_EXP, W_MANT, DIVSQRT_IMPL);
    $finish;
  end

  // lockstep + result check, sampled at the falling edge (stable values)
  always @(negedge clk) begin
    if (aresetn) begin
      if (s_ready[0] !== s_ready[1] || m_valid[0] !== m_valid[1]
          || (m_valid[0] && (m_data[0] !== m_data[1] || m_user[0] !== m_user[1]
                             || m_last[0] !== m_last[1]))) begin
        if (errors < 10) $display("ERROR: Verilog/VHDL tops differ at %0t", $time);
        errors++;
      end
      if (m_valid[0] && m_ready) begin
        if (got >= N) begin
          $display("ERROR: extra result");
          errors++;
        end else if (m_data[0][OPB-1:0] !== OPB'(v_y[got]) || m_data[0][OPB+4 -: 5] !== v_f[got]
                     || m_data[0][OPB+6 -: 2] !== v_cmp[got] || m_data[0][OPB+7] !== 1'b0
                     || m_user[0] !== v_user[got] || m_last[0] !== v_last[got]) begin
          if (errors < 10)
            $display("ERROR: result %0d op=%0d rm=%0d a=%h b=%h: got y=%h f=%b cmp=%0d user=%h last=%b, want y=%h f=%b cmp=%0d user=%h last=%b",
                     got, v_op[got], v_rm[got], v_a[got], v_b[got],
                     m_data[0][OPB-1:0], m_data[0][OPB+4 -: 5], m_data[0][OPB+6 -: 2], m_user[0], m_last[0],
                     v_y[got], v_f[got], v_cmp[got], v_user[got], v_last[got]);
          errors++;
        end
        got++;
      end
    end
  end

  // random M_AXIS TREADY (changed at the rising edge, sampled at the falling)
  always @(posedge clk) m_ready <= ($urandom_range(3) != 0);

  initial begin
    string vec;
    int fd, k, cyc;
    int unsigned op, rmv, f, cm;
    logic [127:0] av, bv, cv, yv;
    bit sent;
    if (!$value$plusargs("VEC=%s", vec)) $fatal(1, "missing +VEC=<file>");
    fd = $fopen(vec, "r");
    if (fd == 0) $fatal(1, "cannot open %s", vec);
    for (k = 0; k < N; k++) begin
      if ($fscanf(fd, "%h %h %h %h %h %h %h %h\n", op, rmv, av, bv, cv, yv, f, cm) != 8)
        $fatal(1, "short vector file at line %0d", k + 1);
      v_op[k] = op; v_rm[k] = rmv; v_a[k] = av[W-1:0]; v_b[k] = bv[W-1:0];
      v_c[k] = cv[W-1:0]; v_y[k] = yv[W-1:0]; v_f[k] = f; v_cmp[k] = cm;
      v_user[k] = UW'($urandom); v_last[k] = $urandom_range(1);
    end
    $fclose(fd);

    s_valid = 1'b0; s_data = '0; s_user = '0; s_last = 1'b0; m_ready = 1'b0;
    repeat (4) @(posedge clk);
    aresetn <= 1'b1;
    @(posedge clk);

    for (k = 0; k < N; k++) begin
      if ($urandom_range(4) == 0) begin
        s_valid <= 1'b0;
        @(posedge clk);
      end
      s_valid <= 1'b1;
      s_data  <= {1'b0, v_rm[k], v_op[k], OPB'(v_c[k]), OPB'(v_b[k]), OPB'(v_a[k])};
      s_user  <= v_user[k];
      s_last  <= v_last[k];
      do begin
        @(negedge clk);
        sent = s_ready[0];
        @(posedge clk);
      end while (!sent);
    end
    s_valid <= 1'b0;

    cyc = 0;
    while (got < N && cyc < 2000) begin
      @(posedge clk);
      cyc++;
    end
    if (got != N) begin
      $display("ERROR: %0d of %0d results", got, N);
      errors++;
    end
    if (errors == 0)
      $display("XSIM AXIS TOPS W_EXP=%0d W_MANT=%0d DIVSQRT_IMPL=%0d OPS_EN=%0h N=%0d: PASS",
               W_EXP, W_MANT, DIVSQRT_IMPL, OPS_EN, N);
    else
      $display("XSIM AXIS TOPS W_EXP=%0d W_MANT=%0d DIVSQRT_IMPL=%0d OPS_EN=%0h N=%0d: FAIL (%0d errors)",
               W_EXP, W_MANT, DIVSQRT_IMPL, OPS_EN, N, errors);
    $finish;
  end

endmodule
