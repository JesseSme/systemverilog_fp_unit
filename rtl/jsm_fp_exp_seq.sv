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
// with |x/32| <= 0.5 (all operations RNE).
//
// Measured accuracy (tests/test_fp_exp_seq.py, vs math.exp rounded to
// binary32): <= ~45 ulp (~5e-6 relative) for |x| <= 8, rising to ~1.3k ulp
// (~1.5e-4 relative) as |x| approaches 16. The squarings multiply the
// relative error of exp(x/32) (polynomial truncation ~r^7/5040 plus the
// rounding of 13 operations) by 32. A higher polynomial degree or a smaller
// scaling exponent with an ln2 range reduction would be needed for
// single-digit-ulp accuracy.
//
// Inputs: |x| > 16 (including +-Inf) clamps to +-16. A NaN compares as a
// huge magnitude and also clamps to +-16 (sign of the NaN), i.e. a NaN input
// does NOT produce a NaN.
//
// The caller pulses `start` with `x`; `done` pulses one cycle with `y` valid
// (held until the next start). Latency: 87 cycles (binary32 jsm_fp_unit
// latencies: mul 4, add 3). The sequencer issues one jsm_fp_unit operation at a
// time (held until in_ready) and waits for its out_valid.

/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */

module jsm_fp_exp_seq (
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

  // ------------------------------------------------------- jsm_fp_unit instances
  logic [31:0]       mul_a, mul_b, mul_y;
  logic              mul_in_valid, mul_valid, mul_ready;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [1:0]        mul_cmp;
  logic [4:0]        mul_flags;
  logic              mul_tag;
  /* verilator lint_on UNUSEDSIGNAL */

  // Only the multiply datapath is built (OPS_EN), not the whole unit.
  jsm_fp_unit #(.W_EXP(8), .W_MANT(23),
            .OPS_EN(16'h0004)) u_mul (   // OPS_EN: OP_MUL (2) only
    .clk(clk), .rst_n(rst_n),
    .in_valid(mul_in_valid), .in_ready(mul_ready), .out_valid(mul_valid),
    .mode(jsm_fp_pkg::OP_MUL), .rm(jsm_fp_pkg::RM_RNE),
    .a(mul_a), .b(mul_b), .c('0), .in_tag(1'b0),
    .y(mul_y), .cmp(mul_cmp), .flags(mul_flags), .out_tag(mul_tag)
  );

  logic [31:0]       add_a, add_b, add_y;
  logic              add_in_valid, add_valid, add_ready;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [1:0]        add_cmp;
  logic [4:0]        add_flags;
  logic              add_tag;
  /* verilator lint_on UNUSEDSIGNAL */

  // Only the add/sub datapath is built (OPS_EN).
  jsm_fp_unit #(.W_EXP(8), .W_MANT(23),
            .OPS_EN(16'h0003)) u_add (   // OPS_EN: OP_ADD (0), OP_SUB (1)
    .clk(clk), .rst_n(rst_n),
    .in_valid(add_in_valid), .in_ready(add_ready), .out_valid(add_valid),
    .mode(jsm_fp_pkg::OP_ADD), .rm(jsm_fp_pkg::RM_RNE),
    .a(add_a), .b(add_b), .c('0), .in_tag(1'b0),
    .y(add_y), .cmp(add_cmp), .flags(add_flags), .out_tag(add_tag)
  );


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

  // Issue requests (held until accepted by in_ready).
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
          // The request is asserted combinationally this cycle; once the unit
          // accepts it (in_ready), wait for the result.
          if ((op_is_mul && mul_ready) || (op_is_add && add_ready))
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
