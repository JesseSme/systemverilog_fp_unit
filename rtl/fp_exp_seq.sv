// Sequential accurate fp32 exp: y = exp(x), x clamped to [-16, 16].
//
// Used by the SSM unit for A = -exp(A_log) and the per-step decay
// dA = exp(A * dtp). The shared `fp_exp` LUT units are only ~8-bit accurate
// (max relative error ~20% measured), which is not sufficient inside a
// recurrent state update, so this unit uses range reduction plus a degree-6
// polynomial and scaling by squaring:
//
//   exp(x) = exp(x/32)^32,   exp(r) ~= 1 + r*(1 + r*(1/2 + r*(1/6 +
//                                        r*(1/24 + r*(1/120 + r/720)))))
// with |x/32| <= 0.5, giving ~1e-6 relative error.
//
// The caller pulses `start` with `x`; `done` pulses one cycle with `y` valid
// (held until the next start). The sequencer issues one fp_unit operation at
// a time and waits for its out_valid, so it is compatible with the pipelined
// (multi-cycle) fp_unit.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */

module fp_exp_seq (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,
  input  logic [31:0] x,
  output logic [31:0] y,
  output logic        done
);

  localparam logic [31:0] C_SCALE = 32'h3D000000;  // 2^-5
  localparam logic [31:0] C_6     = 32'h3AB60B61;  // 1/720
  localparam logic [31:0] C_5     = 32'h3C088889;  // 1/120
  localparam logic [31:0] C_4     = 32'h3D2AAAAB;  // 1/24
  localparam logic [31:0] C_3     = 32'h3E2AAAAB;  // 1/6
  localparam logic [31:0] C_2     = 32'h3F000000;  // 1/2
  localparam logic [31:0] C_1     = 32'h3F800000;  // 1.0
  localparam logic [31:0] C_MAX   = 32'h41800000;  // 16.0

  logic [31:0] x_reg, r_reg, h_reg;
  logic [5:0]  step;
  logic        waiting;
  logic [31:0] clamped_mag;

  // Clamp |x| to 16.0, preserving the sign.
  assign clamped_mag = (x[30:0] > C_MAX[30:0]) ? {x[31], C_MAX[30:0]} : x;

  // ------------------------------------------------------- fp_unit instances
  fp_pkg::op_t       mul_mode;
  fp_pkg::rounding_t mul_rm;
  logic [31:0]       mul_a, mul_b, mul_y;
  logic              mul_in_valid, mul_valid;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [1:0]        mul_cmp;
  logic [4:0]        mul_flags;
  /* verilator lint_on UNUSEDSIGNAL */

  fp_unit #(.W_EXP(8), .W_MANT(23)) u_mul (
    .clk(clk), .rst_n(rst_n),
    .in_valid(mul_in_valid), .out_valid(mul_valid),
    .mode(mul_mode), .rm(mul_rm),
    .a(mul_a), .b(mul_b), .c('0),
    .y(mul_y), .cmp(mul_cmp), .flags(mul_flags)
  );

  fp_pkg::op_t       add_mode;
  fp_pkg::rounding_t add_rm;
  logic [31:0]       add_a, add_b, add_y;
  logic              add_in_valid, add_valid;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [1:0]        add_cmp;
  logic [4:0]        add_flags;
  /* verilator lint_on UNUSEDSIGNAL */

  fp_unit #(.W_EXP(8), .W_MANT(23)) u_add (
    .clk(clk), .rst_n(rst_n),
    .in_valid(add_in_valid), .out_valid(add_valid),
    .mode(add_mode), .rm(add_rm),
    .a(add_a), .b(add_b), .c('0),
    .y(add_y), .cmp(add_cmp), .flags(add_flags)
  );

  assign mul_mode = fp_pkg::OP_MUL;
  assign mul_rm   = fp_pkg::RM_RNE;
  assign add_mode = fp_pkg::OP_ADD;
  assign add_rm   = fp_pkg::RM_RNE;

  // ------------------------------------------------------- sequencer
  // Step schedule (one operation per op-step, waiting for out_valid):
  //   1  mul  x/32                 -> r       2  h = 1/720 (no op)
  //   3,5,7,9,11  mul h*r          -> t       even steps 4..12: add t+c -> h
  //   13 mul r*h                    -> t       14 add 1.0 + t -> h
  //   15..19 mul h*h (5 squarings)  -> h       20 done
  logic [31:0] last_y;
  logic        op_is_mul, op_is_add;

  always_comb begin
    mul_a = '0;
    mul_b = '0;
    add_a = '0;
    add_b = '0;
    op_is_mul = 1'b0;
    op_is_add = 1'b0;
    case (step)
      6'd1:  begin mul_a = x_reg;  mul_b = C_SCALE; op_is_mul = 1'b1; end
      6'd3,
      6'd5,
      6'd7,
      6'd9,
      6'd11: begin mul_a = h_reg;  mul_b = r_reg;   op_is_mul = 1'b1; end
      6'd4:  begin add_a = last_y; add_b = C_5;     op_is_add = 1'b1; end
      6'd6:  begin add_a = last_y; add_b = C_4;     op_is_add = 1'b1; end
      6'd8:  begin add_a = last_y; add_b = C_3;     op_is_add = 1'b1; end
      6'd10: begin add_a = last_y; add_b = C_2;     op_is_add = 1'b1; end
      6'd12: begin add_a = last_y; add_b = C_1;     op_is_add = 1'b1; end
      6'd13: begin mul_a = r_reg;  mul_b = h_reg;   op_is_mul = 1'b1; end
      6'd14: begin add_a = C_1;    add_b = last_y;  op_is_add = 1'b1; end
      6'd15,
      6'd16,
      6'd17,
      6'd18,
      6'd19: begin mul_a = h_reg;  mul_b = h_reg;   op_is_mul = 1'b1; end
      default: ;
    endcase
  end

  // One-cycle issue pulses (only in the cycle a step starts).
  assign mul_in_valid = !waiting && op_is_mul;
  assign add_in_valid = !waiting && op_is_add;
  logic any_valid;
  logic [31:0] op_y;
  assign any_valid = mul_valid || add_valid;
  assign op_y      = mul_valid ? mul_y : add_y;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      step    <= 6'd0;
      waiting <= 1'b0;
      x_reg   <= '0;
      r_reg   <= '0;
      h_reg   <= '0;
      last_y  <= '0;
      y       <= '0;
      done    <= 1'b0;
    end else begin
      done <= 1'b0;
      if (step == 6'd0) begin
        if (start) begin
          x_reg   <= clamped_mag;
          step    <= 6'd1;
          waiting <= 1'b0;
        end
      end else if (!waiting) begin
        if (op_is_mul || op_is_add) begin
          // The issue pulse is asserted combinationally this cycle; wait for
          // the result.
          waiting <= 1'b1;
        end else begin
          // No-op steps: 2 (load 1/720) and 20 (publish the result).
          case (step)
            6'd2:  begin h_reg <= C_6; step <= 6'd3; end
            6'd20: begin y <= h_reg; done <= 1'b1; step <= 6'd0; end
            default: step <= step + 6'd1;
          endcase
        end
      end else if (any_valid) begin
        // Operation finished: capture the result and advance.
        last_y <= op_y;
        case (step)
          6'd1:  r_reg <= op_y;
          6'd4,
          6'd6,
          6'd8,
          6'd10,
          6'd12,
          6'd13,
          6'd14,
          6'd15,
          6'd16,
          6'd17,
          6'd18,
          6'd19: h_reg <= op_y;
          default: ;
        endcase
        step    <= step + 6'd1;
        waiting <= 1'b0;
      end
    end
  end

endmodule
