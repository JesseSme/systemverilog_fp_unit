// Differential wrapper: pipelined fp_div_srt (streaming) vs combinational
// fp_div on the same operands.

module div_srt_diff_top #(
  parameter int W_EXP  = 8,
  parameter int W_MANT = 23,
  parameter int DPS    = 2,
  parameter int FOLD_STG = 0,
  parameter int STAGE_FOLD = (DPS >= 2) ? 1 : 0
) (
  input  logic clk,
  input  logic rst_n,
  input  logic start,
  input  logic [1+W_EXP+W_MANT-1:0] a,
  input  logic [1+W_EXP+W_MANT-1:0] b,
  input  logic [2:0] rm,
  output logic [1+W_EXP+W_MANT-1:0] y_pipe,
  output logic [4:0] flags_pipe,
  output logic pipe_valid,
  output logic [1+W_EXP+W_MANT-1:0] y_comb,
  output logic [4:0] flags_comb
);

  fp_div_srt #(.W_EXP(W_EXP), .W_MANT(W_MANT), .DPS(DPS), .FOLD_STG(FOLD_STG), .STAGE_FOLD(STAGE_FOLD)) u_div (
    .a(a), .b(b), .rm(fp_pkg::rounding_t'(rm)),
    .start(start), .y(y_pipe), .flags(flags_pipe),
    .clk(clk), .rst_n(rst_n), .out_valid(pipe_valid)
  );

  fp_div #(.W_EXP(W_EXP), .W_MANT(W_MANT)) u_comb (
    .a(a), .b(b), .rm(fp_pkg::rounding_t'(rm)),
    .y(y_comb), .flags(flags_comb)
  );

endmodule
