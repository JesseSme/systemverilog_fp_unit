// Vivado xsim testbench for the Verilog and VHDL tops of jsm_fp_unit
// (rtl/top/jsm_fp_unit_top.v, rtl/top/jsm_fp_unit_vhd.vhd).
//
// Both tops get the same request stream (random gaps, requests held while
// in_ready is low) with the vector index as the tag. Every result is checked
// against the oracle vector of its out_tag, and the two tops must agree
// cycle by cycle (in_ready, out_valid, out_tag). Vectors come from
// tests/vivado/gen_vectors.py (+VEC=<file>); run via tests/vivado/run_xsim.py.

`timescale 1ns / 1ps

module tb_fp_unit_tops #(
  parameter int W_EXP        = 8,
  parameter int W_MANT       = 23,
  parameter int DIVSQRT_IMPL = 1,
  parameter int OPS_EN       = 65535,
  parameter int N            = 2000
);
  localparam int W     = 1 + W_EXP + W_MANT;
  localparam int TAG_W = 16;

  logic clk = 1'b0;
  always #2 clk = ~clk;
  logic rst_n = 1'b0;

  logic [3:0] v_op [N];
  logic [2:0] v_rm [N];
  logic [W-1:0] v_a [N], v_b [N], v_c [N], v_y [N];
  logic [4:0] v_f [N];
  logic [1:0] v_cmp [N];

  logic             in_valid;
  logic [3:0]       mode;
  logic [2:0]       rm;
  logic [W-1:0]     a, b, c;
  logic [TAG_W-1:0] in_tag;

  logic             rdy_v, rdy_h, ov_v, ov_h;
  logic [W-1:0]     y_v, y_h;
  logic [1:0]       cmp_v, cmp_h;
  logic [4:0]       f_v, f_h;
  logic [TAG_W-1:0] tag_v, tag_h;

  jsm_fp_unit_top #(.W_EXP(W_EXP), .W_MANT(W_MANT), .DIVSQRT_IMPL(DIVSQRT_IMPL),
                .TAG_W(TAG_W), .OPS_EN(OPS_EN)) u_verilog (
    .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_ready(rdy_v),
    .mode(mode), .rm(rm), .a(a), .b(b), .c(c), .in_tag(in_tag),
    .y(y_v), .cmp(cmp_v), .flags(f_v), .out_valid(ov_v), .out_tag(tag_v));

  jsm_fp_unit_vhd #(.W_EXP(W_EXP), .W_MANT(W_MANT), .DIVSQRT_IMPL(DIVSQRT_IMPL),
                .TAG_W(TAG_W), .OPS_EN(OPS_EN)) u_vhdl (
    .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .in_ready(rdy_h),
    .mode(mode), .rm(rm), .a(a), .b(b), .c(c), .in_tag(in_tag),
    .y(y_h), .cmp(cmp_h), .flags(f_h), .out_valid(ov_h), .out_tag(tag_h));

  int errors = 0;

  // watchdog: a handshake that never completes fails instead of hanging
  initial begin
    #(64'(N) * 4000 * 4 + 100000);
    $display("XSIM TOPS W_EXP=%0d W_MANT=%0d DIVSQRT_IMPL=%0d: FAIL (watchdog timeout)",
             W_EXP, W_MANT, DIVSQRT_IMPL);
    $finish;
  end
  int done_v = 0, done_h = 0;
  bit seen_v [N], seen_h [N];

  task automatic check(string who, logic [TAG_W-1:0] tag, logic [W-1:0] y,
                       logic [4:0] f, logic [1:0] cm, ref bit seen [N]);
    if (tag >= N) begin
      $display("ERROR %s: out_tag %0d out of range", who, tag);
      errors++;
    end else begin
      if (seen[tag]) begin
        $display("ERROR %s: tag %0d completed twice", who, tag);
        errors++;
      end
      seen[tag] = 1'b1;
      if (y !== v_y[tag] || f !== v_f[tag] || cm !== v_cmp[tag]) begin
        if (errors < 10)
          $display("ERROR %s: vec %0d op=%0d rm=%0d a=%h b=%h c=%h: got y=%h f=%b cmp=%0d, want y=%h f=%b cmp=%0d",
                   who, tag, v_op[tag], v_rm[tag], v_a[tag], v_b[tag], v_c[tag],
                   y, f, cm, v_y[tag], v_f[tag], v_cmp[tag]);
        errors++;
      end
    end
  endtask

  // results
  always @(posedge clk) begin
    if (rst_n) begin
      if (rdy_v !== rdy_h || ov_v !== ov_h || (ov_v && tag_v !== tag_h)) begin
        if (errors < 10)
          $display("ERROR: Verilog/VHDL tops differ at %0t (ready %b/%b valid %b/%b)",
                   $time, rdy_v, rdy_h, ov_v, ov_h);
        errors++;
      end
      if (ov_v) begin check("verilog", tag_v, y_v, f_v, cmp_v, seen_v); done_v++; end
      if (ov_h) begin check("vhdl",    tag_h, y_h, f_h, cmp_h, seen_h); done_h++; end
    end
  end

  initial begin
    string vec;
    int fd, k, cyc;
    bit acc;
    int unsigned op, rmv, f, cm;
    logic [127:0] av, bv, cv, yv;
    if (!$value$plusargs("VEC=%s", vec)) $fatal(1, "missing +VEC=<file>");
    fd = $fopen(vec, "r");
    if (fd == 0) $fatal(1, "cannot open %s", vec);
    for (k = 0; k < N; k++) begin
      if ($fscanf(fd, "%h %h %h %h %h %h %h %h\n", op, rmv, av, bv, cv, yv, f, cm) != 8)
        $fatal(1, "short vector file at line %0d", k + 1);
      v_op[k] = op; v_rm[k] = rmv; v_a[k] = av[W-1:0]; v_b[k] = bv[W-1:0];
      v_c[k] = cv[W-1:0]; v_y[k] = yv[W-1:0]; v_f[k] = f; v_cmp[k] = cm;
    end
    $fclose(fd);

    in_valid = 1'b0; mode = '0; rm = '0; a = '0; b = '0; c = '0; in_tag = '0;
    repeat (4) @(posedge clk);
    rst_n <= 1'b1;
    @(posedge clk);

    k = 0;
    while (k < N) begin
      // drive vector k (with a random idle gap first), hold until accepted
      if ($urandom_range(3) == 0) begin
        in_valid <= 1'b0;
        @(posedge clk);
      end
      in_valid <= 1'b1; mode <= v_op[k]; rm <= v_rm[k];
      a <= v_a[k]; b <= v_b[k]; c <= v_c[k]; in_tag <= TAG_W'(k);
      // accepted at the next rising edge iff in_ready is high in this cycle
      // (sampled at the falling edge, when mode and the reservation are stable)
      do begin
        @(negedge clk);
        acc = rdy_v;
        @(posedge clk);
      end while (!acc);
      k++;
    end
    in_valid <= 1'b0;

    cyc = 0;
    while ((done_v < N || done_h < N) && cyc < 1000) begin
      @(posedge clk);
      cyc++;
    end
    if (done_v != N || done_h != N) begin
      $display("ERROR: completed %0d (Verilog) / %0d (VHDL) of %0d", done_v, done_h, N);
      errors++;
    end
    if (errors == 0)
      $display("XSIM TOPS W_EXP=%0d W_MANT=%0d DIVSQRT_IMPL=%0d OPS_EN=%0h N=%0d: PASS",
               W_EXP, W_MANT, DIVSQRT_IMPL, OPS_EN, N);
    else
      $display("XSIM TOPS W_EXP=%0d W_MANT=%0d DIVSQRT_IMPL=%0d OPS_EN=%0h N=%0d: FAIL (%0d errors)",
               W_EXP, W_MANT, DIVSQRT_IMPL, OPS_EN, N, errors);
    $finish;
  end

endmodule
