// Pipelined unsigned W x W multiplier, LUT-only (no DSP inference).
//
// Partial products (one row per multiplier bit) are reduced by a pairwise
// adder tree, two reduction levels per pipeline register, so the core has a
// fixed latency of 3 cycles for any W <= 64:
//
//   level 0   pp[i] = a & {W{b[i]}} << i          (W rows)
//   stage A   levels 1+2 register                (ceil(W/4) rows)
//   stage B   levels 3+4 register
//   stage C   levels 5+6 register -> product
//
// Rows beyond the live count are held at zero, which keeps the tree uniform
// for any W (no generate-time shape changes beyond the loop bounds). The
// arithmetic is explicit (AND rows + additions), so no synthesis tool maps it
// to a DSP block.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */

module fp_mul_core #(
  parameter int W = 24
) (
  input  logic            clk,
  input  logic            rst_n,
  input  logic            start,
  input  logic [W-1:0]    a,
  input  logic [W-1:0]    b,
  output logic [2*W-1:0]  p,
  output logic            out_valid
);

  localparam int PW = 2 * W;  // every level's row is a partial sum <= the product

  // Live row count after k reduction levels: rcnt(0)=W, rcnt(k+1)=ceil(rcnt(k)/2).
  function automatic int rcnt(input int k);
    int n;
    n = W;
    for (int i = 0; i < k; i++) n = (n + 1) / 2;
    rcnt = n;
  endfunction

  // ------------------------------------------------- partial products
  logic [PW-1:0] pp [0:W-1];
  always_comb
    for (int i = 0; i < W; i++)
      pp[i] = ((PW)'(a) & {(PW){b[i]}}) << i;

  // ------------------------------------------------- stage A: levels 1+2
  // Two separate loops per stage: l2 may only read l1 elements written in the
  // first loop (reading them in the same pass would use stale values).
  logic [PW-1:0] l1 [0:W-1];
  logic [PW-1:0] l2 [0:W-1];
  always_comb begin
    for (int j = 0; j < W; j++) begin
      if (2*j + 1 < rcnt(0)) l1[j] = pp[2*j] + pp[2*j+1];
      else if (2*j < rcnt(0)) l1[j] = pp[2*j];
      else l1[j] = '0;
    end
    for (int j = 0; j < W; j++) begin
      if (2*j + 1 < rcnt(1)) l2[j] = l1[2*j] + l1[2*j+1];
      else if (2*j < rcnt(1)) l2[j] = l1[2*j];
      else l2[j] = '0;
    end
  end

  logic [PW-1:0] a_reg [0:W-1];
  logic          va;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int j = 0; j < W; j++) a_reg[j] <= '0;
      va <= 1'b0;
    end else begin
      for (int j = 0; j < W; j++) a_reg[j] <= l2[j];
      va <= start;
    end
  end

  // ------------------------------------------------- stage B: levels 3+4
  logic [PW-1:0] l3 [0:W-1];
  logic [PW-1:0] l4 [0:W-1];
  always_comb begin
    for (int j = 0; j < W; j++) begin
      if (2*j + 1 < rcnt(2)) l3[j] = a_reg[2*j] + a_reg[2*j+1];
      else if (2*j < rcnt(2)) l3[j] = a_reg[2*j];
      else l3[j] = '0;
    end
    for (int j = 0; j < W; j++) begin
      if (2*j + 1 < rcnt(3)) l4[j] = l3[2*j] + l3[2*j+1];
      else if (2*j < rcnt(3)) l4[j] = l3[2*j];
      else l4[j] = '0;
    end
  end

  logic [PW-1:0] b_reg [0:W-1];
  logic          vb;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int j = 0; j < W; j++) b_reg[j] <= '0;
      vb <= 1'b0;
    end else begin
      for (int j = 0; j < W; j++) b_reg[j] <= l4[j];
      vb <= va;
    end
  end

  // ------------------------------------------------- stage C: levels 5+6
  logic [PW-1:0] l5 [0:W-1];
  logic [PW-1:0] l6 [0:W-1];
  always_comb begin
    for (int j = 0; j < W; j++) begin
      if (2*j + 1 < rcnt(4)) l5[j] = b_reg[2*j] + b_reg[2*j+1];
      else if (2*j < rcnt(4)) l5[j] = b_reg[2*j];
      else l5[j] = '0;
    end
    for (int j = 0; j < W; j++) begin
      if (2*j + 1 < rcnt(5)) l6[j] = l5[2*j] + l5[2*j+1];
      else if (2*j < rcnt(5)) l6[j] = l5[2*j];
      else l6[j] = '0;
    end
  end

  logic [PW-1:0] p_reg;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      p_reg     <= '0;
      out_valid <= 1'b0;
    end else begin
      p_reg     <= l6[0];
      out_valid <= vb;
    end
  end

  assign p = p_reg[2*W-1:0];

endmodule
