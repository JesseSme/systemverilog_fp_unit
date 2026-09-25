// AXI-Lite register interface for the IEEE 754-2019 FPU (fp_unit).
//
// The AXI data path is fixed at 32 bits. The internal operand/result
// registers are sized to the next power of two that covers the FPU format
// width W = 1 + W_EXP + W_MANT (so a binary32 format uses 32-bit operand
// registers, a binary16 format 16-bit registers, a binary64 format 64-bit
// registers). Operands are written through 32-bit AXI data words and sliced
// down to W before being presented to fp_unit; a wide operand/result is
// accessed as consecutive 32-bit words, little-endian (low word first). The
// output (RESULT) register is the same power-of-two width as the operand
// registers, so the output width is derived from the operand widths. The
// opcode and status registers are fixed 32-bit vectors.
//
// Register map (offsets recomputed from the operand word count WORDS =
// ceil(REG_W / 32); single-word offsets shown for a REG_W <= 32 format):
//
//   +--------+---------+---------------------------------------------------+
//   | Offset | Name    | Fields                                            |
//   +--------+---------+---------------------------------------------------+
//   | 0x00   | CTRL    | [0] GO: rising edge starts a computation;         |
//   |        |         | [1] CLR: level, holds STATUS.VALID clear           |
//   | 0x04   | OPCODE  | [3:0] op (fp_pkg::op_t), [6:4] rm (rounding_t)    |
//   | 0x08   | DATA_A  | operand A (REG_W bits, sliced to W)                |
//   | 0x0C   | DATA_B  | operand B                                         |
//   | 0x10   | DATA_C  | operand C (FMA only)                              |
//   | 0x14   | STATUS  | [4:0] flags, [8] BUSY, [9] VALID,                |
//   |        |         | [31:16] format id {W_MANT, W_EXP}                  |
//   | 0x18   | RESULT  | y (REG_W bits, low W bits meaningful)             |
//   | 0x1C   | RES_CMP | [1:0] cmp (condition code / totalOrder bit)        |
//   +--------+---------+---------------------------------------------------+
//
// Operation flow: software writes DATA_A/B/C and OPCODE, then writes
// CTRL.GO = 1. The wrapper latches the operands/opcode into working
// registers, asserts STATUS.BUSY, and publishes the result in
// RESULT/RES_CMP and STATUS.flags with STATUS.VALID = 1 and STATUS.BUSY = 0
// when the FPU's out_valid pulses (the cycle after GO for single-cycle
// operations; after the iterative div/sqrt engine finishes when
// ITER_DIVSQRT = 1). Reads/writes outside the register map are answered with
// DECERR; writes to read-only registers are ignored (OKAY).

module fp_unit_axilite #(
  parameter int W_EXP       = 8,
  parameter int W_MANT      = 23,
  parameter int ADDR_WIDTH  = 6,
  // Passed through to fp_unit: 1 selects the iterative div/sqrt engine
  // (in_valid/out_valid/busy handshake), 0 the combinational datapaths.
  parameter int ITER_DIVSQRT = 0
) (
  input  logic                  s_axi_aclk,
  input  logic                  s_axi_aresetn,
  // Write address channel
  input  logic [ADDR_WIDTH-1:0] s_axi_awaddr,
  input  logic                  s_axi_awvalid,
  output logic                  s_axi_awready,
  // Write data channel
  input  logic [31:0]           s_axi_wdata,
  input  logic [3:0]            s_axi_wstrb,
  input  logic                  s_axi_wvalid,
  output logic                  s_axi_wready,
  // Write response channel
  output logic [1:0]            s_axi_bresp,
  output logic                  s_axi_bvalid,
  input  logic                  s_axi_bready,
  // Read address channel
  input  logic [ADDR_WIDTH-1:0] s_axi_araddr,
  input  logic                  s_axi_arvalid,
  output logic                  s_axi_arready,
  // Read data channel
  output logic [31:0]           s_axi_rdata,
  output logic [1:0]            s_axi_rresp,
  output logic                  s_axi_rvalid,
  input  logic                  s_axi_rready
);

  // ---- Format-derived widths -------------------------------------------------
  localparam int W       = 1 + W_EXP + W_MANT;          // FPU vector width
  localparam int REG_W   = 1 << $clog2(W);              // operand/result reg (pow2)
  localparam int WORDS   = (REG_W + 31) / 32;           // 32-bit words per operand
  localparam int ADDR_CTRL   = 32'h00;
  localparam int ADDR_OPCODE = 32'h04;
  localparam int ADDR_A      = 32'h08;
  localparam int ADDR_B      = ADDR_A + 4 * WORDS;
  localparam int ADDR_C      = ADDR_B + 4 * WORDS;
  localparam int ADDR_STATUS = ADDR_C + 4 * WORDS;
  localparam int ADDR_RESULT = ADDR_STATUS + 4;
  localparam int ADDR_CMP    = ADDR_RESULT + 4 * WORDS;
  localparam int TOTAL_BYTES = ADDR_CMP + 4;

  generate
    if (TOTAL_BYTES > (1 << ADDR_WIDTH)) begin : g_addr_check
      initial begin
        $display("fp_unit_axilite: ADDR_WIDTH=%0d too small for %0d-byte register map",
                 ADDR_WIDTH, TOTAL_BYTES);
        $fatal(1);
      end
    end
  endgenerate

  localparam logic [1:0] AXI_OKAY   = 2'b00;
  localparam logic [1:0] AXI_DECERR = 2'b11;

  // ---- Address decode ---------------------------------------------------------
  typedef enum logic [3:0] {
    DEC_NONE   = 4'd0,
    DEC_CTRL   = 4'd1,
    DEC_OPCODE = 4'd2,
    DEC_A      = 4'd3,
    DEC_B      = 4'd4,
    DEC_C      = 4'd5,
    DEC_STATUS = 4'd6,
    DEC_RESULT = 4'd7,
    DEC_CMP    = 4'd8
  } dec_sel_e;

  typedef struct packed {
    logic      valid;
    dec_sel_e  sel;
    logic [7:0] word;
  } dec_t;

  function automatic dec_t decode(input logic [ADDR_WIDTH-1:0] addr);
    dec_t d;
    int a;
  begin
    d  = '{valid: 1'b0, sel: DEC_NONE, word: 8'd0};
    a  = int'(addr);
    if (addr[1:0] != 2'b00) return d;
    if      (a == ADDR_CTRL)              d = '{valid: 1'b1, sel: DEC_CTRL,   word: 8'd0};
    else if (a == ADDR_OPCODE)            d = '{valid: 1'b1, sel: DEC_OPCODE, word: 8'd0};
    else if (a >= ADDR_A && a < ADDR_A + 4 * WORDS)
                                          d = '{valid: 1'b1, sel: DEC_A,      word: 8'((a - ADDR_A) >> 2)};
    else if (a >= ADDR_B && a < ADDR_B + 4 * WORDS)
                                          d = '{valid: 1'b1, sel: DEC_B,      word: 8'((a - ADDR_B) >> 2)};
    else if (a >= ADDR_C && a < ADDR_C + 4 * WORDS)
                                          d = '{valid: 1'b1, sel: DEC_C,      word: 8'((a - ADDR_C) >> 2)};
    else if (a == ADDR_STATUS)            d = '{valid: 1'b1, sel: DEC_STATUS, word: 8'd0};
    else if (a >= ADDR_RESULT && a < ADDR_RESULT + 4 * WORDS)
                                          d = '{valid: 1'b1, sel: DEC_RESULT, word: 8'((a - ADDR_RESULT) >> 2)};
    else if (a == ADDR_CMP)               d = '{valid: 1'b1, sel: DEC_CMP,    word: 8'd0};
    return d;
  end
  endfunction

  // ---- Byte / word write helpers ----------------------------------------------
  function automatic logic [31:0] wr_bytes(
    input logic [31:0] old, input logic [31:0] d, input logic [3:0] s);
    for (int i = 0; i < 4; i++)
      if (s[i]) old[i*8 +: 8] = d[i*8 +: 8];
    return old;
  endfunction

  function automatic logic [REG_W-1:0] wr_wide(
    input logic [REG_W-1:0] old, input logic [7:0] w,
    input logic [31:0] d, input logic [3:0] s);
    for (int i = 0; i < 4; i++)
      if (s[i] && (w*32 + i*8 + 8 <= REG_W))
        old[w*32 + i*8 +: 8] = d[i*8 +: 8];
    return old;
  endfunction

  // Word w (little-endian) of a REG_W-bit value, zero-padded above REG_W so the
  // variable-indexed part select never leaves the vector.
  function automatic logic [31:0] rd_wide(input logic [REG_W-1:0] v, input logic [7:0] w);
    logic [REG_W+31:0] padded;
    begin
      padded = {{32{1'b0}}, v};
      return padded[w*32 +: 32];
    end
  endfunction

  // ---- Register file ------------------------------------------------------------
  logic [31:0]      reg_ctrl;
  logic [31:0]      reg_opcode;
  logic [REG_W-1:0] reg_a;
  logic [REG_W-1:0] reg_b;
  logic [REG_W-1:0] reg_c;
  logic [REG_W-1:0] reg_result;
  logic [31:0]      reg_cmp;
  logic [4:0]       reg_flags;
  logic             busy;
  logic             valid;

  logic [31:0] status_vec;
  assign status_vec = { {W_MANT[7:0], W_EXP[7:0]}, 6'b0, valid, busy, 3'b0, reg_flags };

  // ---- Compute control (GO strobe -> BUSY -> 3 cycles -> VALID) ----------------
  logic [W-1:0]      a_w;
  logic [W-1:0]      b_w;
  logic [W-1:0]      c_w;
  fp_pkg::op_t       mode_w;
  fp_pkg::rounding_t rm_w;
  logic              go_d;
  logic              go_rise;
  assign go_rise = reg_ctrl[0] && !go_d;

  localparam logic [1:0] S_IDLE = 2'd0, S_WAIT = 2'd1, S_DONE = 2'd2;
  logic [1:0] cstate;

  logic [W-1:0] fpu_y;
  logic [1:0]   fpu_cmp;
  logic [4:0]   fpu_flags;
  logic         fpu_in_valid;
  logic         fpu_out_valid;
  logic         start_req;

  // One-cycle start pulse for the FPU, issued in the first S_WAIT cycle so the
  // operands latched on the S_IDLE -> S_WAIT edge are already stable. Single-
  // cycle ops pulse out_valid the next cycle; div/sqrt under
  // ITER_DIVSQRT = 1 when the iterative engine finishes.
  assign fpu_in_valid = (cstate == S_WAIT) && start_req;

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      cstate     <= S_IDLE;
      go_d       <= 1'b0;
      start_req  <= 1'b0;
      busy       <= 1'b0;
      valid      <= 1'b0;
      a_w        <= '0;
      b_w        <= '0;
      c_w        <= '0;
      mode_w     <= fp_pkg::OP_ADD;
      rm_w       <= fp_pkg::RM_RNE;
      reg_result <= '0;
      reg_flags  <= 5'd0;
      reg_cmp    <= 32'd0;
    end else begin
      go_d <= reg_ctrl[0];
      case (cstate)
        S_IDLE: begin
          if (go_rise) begin
            a_w    <= reg_a[W-1:0];
            b_w    <= reg_b[W-1:0];
            c_w    <= reg_c[W-1:0];
            mode_w <= fp_pkg::op_t'(reg_opcode[3:0]);
            rm_w   <= fp_pkg::rounding_t'(reg_opcode[6:4]);
            start_req <= 1'b1;
            busy   <= 1'b1;
            valid  <= 1'b0;
            cstate <= S_WAIT;
          end
        end
        S_WAIT: begin
          start_req <= 1'b0;
          if (fpu_out_valid) begin
            reg_result <= {{(REG_W-W){1'b0}}, fpu_y};
            reg_flags  <= fpu_flags;
            reg_cmp    <= {30'd0, fpu_cmp};
            valid      <= 1'b1;
            busy       <= 1'b0;
            cstate     <= S_DONE;
          end
        end
        S_DONE: cstate <= S_IDLE;
        default: cstate <= S_IDLE;
      endcase
      if (reg_ctrl[1]) valid <= 1'b0;
    end
  end

  // ---- AXI-Lite write path -----------------------------------------------------
  task automatic write_regs(input dec_sel_e sel, input logic [7:0] word,
                              input logic [31:0] data, input logic [3:0] strb);
    case (sel)
      DEC_CTRL:   reg_ctrl   <= wr_bytes(reg_ctrl, data, strb);
      DEC_OPCODE: reg_opcode <= wr_bytes(reg_opcode, data, strb);
      DEC_A:      reg_a      <= wr_wide(reg_a, word, data, strb);
      DEC_B:      reg_b      <= wr_wide(reg_b, word, data, strb);
      DEC_C:      reg_c      <= wr_wide(reg_c, word, data, strb);
      default: ; // read-only registers: write ignored, OKAY response
    endcase
  endtask

  localparam logic [1:0] W_IDLE = 2'b00, W_RESP = 2'b01;
  logic [1:0]            wstate;
  logic                  werr;
  logic                  bvalid;

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      wstate     <= W_IDLE;
      werr       <= 1'b0;
      bvalid     <= 1'b0;
      reg_ctrl   <= 32'd0;
      reg_opcode <= 32'd0;
      reg_a      <= '0;
      reg_b      <= '0;
      reg_c      <= '0;
    end else begin
      case (wstate)
        W_IDLE: begin
          bvalid <= 1'b0;
          if (s_axi_awvalid && s_axi_wvalid) begin
            dec_t d = decode(s_axi_awaddr);
            werr  <= ~d.valid;
            wstate <= W_RESP;
            write_regs(d.sel, d.word, s_axi_wdata, s_axi_wstrb);
          end
        end
        W_RESP: begin
          bvalid <= 1'b1;
          if (s_axi_bready) begin
            bvalid <= 1'b0;
            wstate <= W_IDLE;
          end
        end
        default: wstate <= W_IDLE;
      endcase
    end
  end

  assign s_axi_awready = (wstate == W_IDLE);
  assign s_axi_wready  = (wstate == W_IDLE);
  assign s_axi_bresp   = werr ? AXI_DECERR : AXI_OKAY;
  assign s_axi_bvalid  = bvalid;

  // ---- AXI-Lite read path -------------------------------------------------------
  logic [ADDR_WIDTH-1:0] araddr;
  logic                  rvalid;
  logic [1:0]            rstate;
  localparam logic [1:0] R_IDLE = 2'b00, R_DATA = 2'b01;

  dec_t rdec;
  assign rdec = decode(araddr);

  logic [31:0] rdata;
  always_comb begin
    case (rdec.sel)
      DEC_CTRL:   rdata = reg_ctrl;
      DEC_OPCODE: rdata = reg_opcode;
      DEC_A:      rdata = rd_wide(reg_a, rdec.word);
      DEC_B:      rdata = rd_wide(reg_b, rdec.word);
      DEC_C:      rdata = rd_wide(reg_c, rdec.word);
      DEC_STATUS: rdata = status_vec;
      DEC_RESULT: rdata = rd_wide(reg_result, rdec.word);
      DEC_CMP:    rdata = reg_cmp;
      default:    rdata = 32'd0;
    endcase
  end

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      rstate <= R_IDLE;
      araddr <= '0;
      rvalid <= 1'b0;
    end else begin
      case (rstate)
        R_IDLE: begin
          rvalid <= 1'b0;
          if (s_axi_arvalid) begin
            araddr <= s_axi_araddr;
            rstate <= R_DATA;
          end
        end
        R_DATA: begin
          rvalid <= 1'b1;
          if (s_axi_rready) begin
            rvalid <= 1'b0;
            rstate <= R_IDLE;
          end
        end
        default: rstate <= R_IDLE;
      endcase
    end
  end

  assign s_axi_arready = (rstate == R_IDLE);
  assign s_axi_rvalid  = rvalid;
  assign s_axi_rdata   = rdata;
  assign s_axi_rresp   = rdec.valid ? AXI_OKAY : AXI_DECERR;

  // ---- FPU core ---------------------------------------------------------------
  fp_unit #(.W_EXP(W_EXP), .W_MANT(W_MANT), .ITER_DIVSQRT(ITER_DIVSQRT)) u_fp_unit (
    .clk       (s_axi_aclk),
    .rst_n     (s_axi_aresetn),
    .in_valid  (fpu_in_valid),
    .mode      (mode_w),
    .rm        (rm_w),
    .a         (a_w),
    .b         (b_w),
    .c         (c_w),
    .y         (fpu_y),
    .cmp       (fpu_cmp),
    .flags     (fpu_flags),
    .out_valid (fpu_out_valid)
  );

endmodule
