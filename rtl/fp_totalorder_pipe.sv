// Pipelined IEEE 754-2019 totalOrder predicate (2 stages).
//
// Same semantics as fp_totalorder.sv: cmp[0] = a precedes-or-equals b,
// cmp[1] = 0, y = 0, never signals. Fixed latency: 2 cycles.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
/* verilator lint_off UNUSEDSIGNAL */

module fp_totalorder_pipe #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23
) (
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
  input  logic                      clk,
  input  logic                      rst_n,
  input  logic                      start,
  output logic [1+W_EXP+W_MANT-1:0] y,
  output logic [1:0]                cmp,
  output logic [4:0]                flags,
  output logic                      out_valid
);

  localparam int W = 1 + W_EXP + W_MANT;
  localparam logic [W-1:0] SIGN = (W)'(1) << (W-1);

  logic signed [W-1:0] key_a, key_b;
  always_comb begin
    key_a = a[W-1] ? ((~a) | SIGN) : (W)'(a);
    key_b = b[W-1] ? ((~b) | SIGN) : (W)'(b);
  end

  logic [1:0] cmp_c;
  assign cmp_c = {1'b0, (key_a <= key_b)};

  logic [1:0] cmp_s1;
  logic       v1;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cmp_s1 <= 2'd0;
      v1     <= 1'b0;
    end else begin
      cmp_s1 <= cmp_c;
      v1     <= start;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      y         <= '0;
      cmp       <= 2'd0;
      flags     <= 5'd0;
      out_valid <= 1'b0;
    end else begin
      y         <= '0;
      cmp       <= cmp_s1;
      flags     <= 5'd0;
      out_valid <= v1;
    end
  end

endmodule
