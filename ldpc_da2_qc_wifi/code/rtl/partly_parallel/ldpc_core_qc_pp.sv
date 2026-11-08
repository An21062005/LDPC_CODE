// Partly-Parallel QC-LDPC core for the 802.11n codes, organised like the da2
// 36-PE decoder but driven by the base matrix instead of PI_1/PI_2/PI_3.
//
// Kept from da2 (PE_block.v / Decoder.v):
//   * one PE per group of VNs, holding a VN unit, a two-bank intrinsic RAM
//     (load one frame while decoding the other), a two-bank decision RAM and
//     one extrinsic-message RAM per edge slot (da2: 3 EXT_RAMs per PE);
//   * CN units shared by all PEs; each PE address generator starts at an offset
//     (da2: ADDRESS_GENERATOR COUNT_FROM_1/2/3) and counts one address per clock;
//   * flooding: a VN phase sweeps every address, then a CN phase does; ITER
//     iterations; c->v messages are zero in the first VN phase; decisions frozen
//     after the first zero-syndrome CN phase; always ITER iterations.
// Changed for the QC code:
//   * PE c = block column c (NB = 24 PEs of ZB = 27 VNs); one message RAM per
//     non-zero base-matrix block (88), the VN unit degree is the column weight;
//   * CN unit r = block row r (12 units, degree 7 or 8). The block shift is the
//     address-generator start value, so CN i of row r reads address (i+s) mod Z
//     of every block in that row: the routing is fixed wiring, no time-varying
//     permutation network (da2 PI_3) is needed;
//   * counters wrap at ZB (27, not a power of two); one clock, no clk_df.
// Transaction interface identical to ldpc_core_serial.sv / ldpc_core_fp.sv.
`default_nettype none

module ldpc_core import ldpc_code_pkg::*; #(
  parameter integer N = LDPC_N,
  parameter integer ITER = 18,
  parameter integer AW = $clog2(N)
)(
  input  wire          clk,
  input  wire          rst,
  input  wire          start,
  input  wire          swap,
  output wire          busy,
  input  wire          load_we,
  input  wire [AW-1:0] load_addr,
  input  wire [4:0]    load_data,
  input  wire [AW-1:0] dec_addr,
  output reg           dec_bit,
  output wire [5:0]    debug
);
  localparam integer ZW = $clog2(ZB);
  localparam [1:0] S_IDLE = 2'd0, S_VN = 2'd1, S_CN = 2'd2, S_EVAL = 2'd3;

  reg [1:0]  state;
  reg [6:0]  t;
  reg [4:0]  iter;
  reg        rs, frozen, syndrome;
  wire       first = (iter == 0);

  // ---- phase pipelines (shared by all PEs / blocks) ----
  wire       v_issue = (state == S_VN) && (t < ZB);
  wire       c_issue = (state == S_CN) && (t < ZB);
  reg  [2:0] v_valid;                // write of VN results 3 clocks after read
  reg  [1:0] c_valid;                // write of CN results 2 clocks after read
  reg  [ZW-1:0] v_a1, v_a2, v_a3;
  always @(posedge clk) begin
    v_valid <= {v_valid[1:0], v_issue};
    c_valid <= {c_valid[0], c_issue};
    v_a1 <= t[ZW-1:0]; v_a2 <= v_a1; v_a3 <= v_a2;
  end
  wire v_write = v_valid[2];
  wire c_write = c_valid[1];

  // ---- load / decision address split: n = c*ZB + j ----
  wire [AW-1:0] load_c = load_addr / ZB;
  wire [ZW-1:0] load_j = load_addr - load_c * ZB;
  wire [AW-1:0] rd_c   = dec_addr / ZB;
  wire [ZW-1:0] rd_j   = dec_addr - rd_c * ZB;

  wire [5:0]          rdq   [0:NBLK-1];          // message read per block
  wire [DVMAX*6-1:0]  vy    [0:NB-1];
  wire [NB-1:0]       vhd;
  wire [DCMAX*5-1:0]  cy    [0:MB-1];
  wire [MB-1:0]       cpar;
  wire [NB-1:0]       dec_rd;

  genvar b, c, r, k;
  generate
    // ---------------- message RAM per non-zero block ----------------
    for (b = 0; b < NBLK; b = b + 1) begin : g_blk
      localparam integer SH = BLK_SHIFT[b*8 +: 8];
      localparam integer BR = BLK_ROW[b*8 +: 8];
      localparam integer BC = BLK_COL[b*8 +: 8];
      localparam integer RS_ = BLK_RSLOT[b*8 +: 8];
      localparam integer CS_ = BLK_CSLOT[b*8 +: 8];
      reg [5:0] mem [0:ZB-1];
      reg [5:0] q;
      reg [ZW-1:0] ag, c_a1, c_a2;       // address generator, start = shift
      integer i;
      initial begin for (i = 0; i < ZB; i = i + 1) mem[i] = 6'd0; q = 6'd0; ag = SH; end
      always @(posedge clk) begin
        if (v_issue) q <= mem[t[ZW-1:0]];
        if (c_issue) q <= mem[ag];
        if (state != S_CN) ag <= SH;
        else if (c_issue) ag <= (ag == ZB-1) ? '0 : ag + 1'b1;
        c_a1 <= ag; c_a2 <= c_a1;
        if (v_write)      mem[v_a3] <= vy[BC][CS_*6 +: 6];
        else if (c_write) mem[c_a2] <= {1'b0, cy[BR][RS_*5 +: 5]};
      end
      assign rdq[b] = q;
    end

    // ---------------- PE: one VN unit per block column ----------------
    for (c = 0; c < NB; c = c + 1) begin : g_pe
      localparam integer P = COL_PTR[c*8 +: 8];
      localparam integer D = COL_PTR[(c+1)*8 +: 8] - P;
      reg [4:0] int_mem [0:(2<<ZW)-1];   // {bank, j}
      reg       dec_mem [0:(2<<ZW)-1];   // {bank, j}
      reg [4:0] zq;
      wire [D*5-1:0] x;
      wire [D*6-1:0] y;
      integer i;
      initial begin for (i = 0; i < (2<<ZW); i = i + 1) begin int_mem[i] = 5'd0; dec_mem[i] = 1'b0; end zq = 5'd0; end
      for (k = 0; k < D; k = k + 1) begin : g_in
        localparam integer BI = COL_BLK[(P+k)*8 +: 8];
        assign x[k*5 +: 5] = first ? 5'd0 : rdq[BI][4:0];
      end
      vn_unit #(.DV(D)) u (.clk(clk), .en(1'b1), .z(zq), .x(x), .y(y), .hd(vhd[c]));
      assign vy[c] = {{((DVMAX-D)*6){1'b0}}, y};
      always @(posedge clk) begin
        if (v_issue) zq <= int_mem[{rs, t[ZW-1:0]}];
        if (load_we && load_c == c) int_mem[{~rs, load_j}] <= load_data;
        if (v_write && !frozen) dec_mem[{rs, v_a3}] <= vhd[c];
      end
      assign dec_rd[c] = dec_mem[{~rs, rd_j}];
    end

    // ---------------- CN unit per block row ----------------
    for (r = 0; r < MB; r = r + 1) begin : g_cn
      localparam integer P = ROW_PTR[r*8 +: 8];
      localparam integer D = ROW_PTR[(r+1)*8 +: 8] - P;
      wire [D*6-1:0] x;
      wire [D*5-1:0] y;
      for (k = 0; k < D; k = k + 1) begin : g_in
        assign x[k*6 +: 6] = rdq[ROW_BLK[(P+k)*8 +: 8]];
      end
      cn_unit #(.DC(D)) u (.clk(clk), .en(1'b1), .x(x), .y(y), .parity(cpar[r]));
      assign cy[r] = {{((DCMAX-D)*5){1'b0}}, y};
    end
  endgenerate

  always @(posedge clk) dec_bit <= dec_rd[rd_c];

  // ---------------- control ----------------
  always @(posedge clk) begin
    if (rst) begin
      state <= S_IDLE; t <= '0; iter <= '0; rs <= 1'b0; frozen <= 1'b0; syndrome <= 1'b0;
    end else begin
      case (state)
        S_IDLE: begin
          if (swap) rs <= ~rs;
          if (start) begin iter <= '0; frozen <= 1'b0; t <= '0; state <= S_VN; end
        end
        S_VN: if (t == ZB + 2) begin t <= '0; syndrome <= 1'b0; state <= S_CN; end
              else t <= t + 1'b1;
        S_CN: begin
          if (c_write) syndrome <= syndrome | (|cpar);
          if (t == ZB + 1) begin t <= '0; state <= S_EVAL; end
          else t <= t + 1'b1;
        end
        S_EVAL: begin
          if (!syndrome) frozen <= 1'b1;
          if (iter == ITER-1) state <= S_IDLE;
          else begin iter <= iter + 1'b1; state <= S_VN; end
        end
      endcase
    end
  end

  assign busy = (state != S_IDLE);
  assign debug = {rs, frozen, iter[3:0]};
endmodule

`default_nettype wire
