// Fully-Parallel LDPC decoder core: one variable-node unit per VN (N units) and
// one check-node unit per CN (M units), hard-wired by the H matrix. All edge
// messages are held in registers; no message memory, no permutation network.
//
// Same algorithm/schedule as the da2 core: flooding, ITER iterations; check->
// variable messages are zero in the first VN phase; decisions are written
// every iteration until a CN phase has zero syndrome, then frozen; the core
// always runs ITER iterations. One iteration takes 4 clocks:
//   VA: VN units register their inputs     VB: VN units produce messages
//   CN: CN units register VN messages, decisions written (unless frozen)
//   CP: check->variable registers capture CN outputs, syndrome evaluated
// Fully-parallel here means node-parallel: it does NOT decode in one clock.
//
// The transaction interface is identical to ldpc_core_serial.sv.
`default_nettype none

module ldpc_core import ldpc_code_pkg::*; #(
  parameter integer N = LDPC_N,
  parameter integer M = LDPC_M,
  parameter integer E = LDPC_E,
  parameter integer ITER = 18,
  parameter integer AW = $clog2(N),
  parameter integer EW = $clog2(E)
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

  localparam [2:0] S_IDLE = 3'd0, S_VA = 3'd1, S_VB = 3'd2, S_CN = 3'd3, S_CP = 3'd4;
  reg [2:0] state;
  reg [4:0] iter;
  reg       rs;
  reg       frozen;

  reg  [N*5-1:0] int0, int1;        // intrinsic banks
  reg  [N-1:0]   dec0, dec1;        // decision banks
  reg  [E*5-1:0] c2v_q;             // check->variable messages
  wire [E*6-1:0] v2c;               // variable->check messages (VN unit outputs)
  wire [E*5-1:0] c2v_d;             // CN unit outputs
  wire [N-1:0]   hd;
  wire [M-1:0]   parity;

  initial begin int0 = '0; int1 = '0; dec0 = '0; dec1 = '0; c2v_q = '0; end

  wire vn_en = (state == S_VA) || (state == S_VB);
  wire cn_en = (state == S_CN);

  genvar n, m, j;
  generate
    for (n = 0; n < N; n = n + 1) begin : g_vn
      localparam integer B = VN_PTR[n*EW_T +: EW_T];
      localparam integer D = VN_PTR[(n+1)*EW_T +: EW_T] - B;
      wire [4:0] z = rs ? int1[n*5 +: 5] : int0[n*5 +: 5];
      vn_unit #(.DV(D)) u (.clk(clk), .en(vn_en), .z(z), .x(c2v_q[B*5 +: D*5]),
                           .y(v2c[B*6 +: D*6]), .hd(hd[n]));
    end
    for (m = 0; m < M; m = m + 1) begin : g_cn
      localparam integer B = CN_PTR[m*EW_T +: EW_T];
      localparam integer D = CN_PTR[(m+1)*EW_T +: EW_T] - B;
      wire [D*6-1:0] x;
      wire [D*5-1:0] y;
      for (j = 0; j < D; j = j + 1) begin : g_edge
        localparam integer EI = CN_EDGE[(B+j)*EW_T +: EW_T];
        assign x[j*6 +: 6]     = v2c[EI*6 +: 6];
        assign c2v_d[EI*5 +: 5] = y[j*5 +: 5];
      end
      cn_unit #(.DC(D)) u (.clk(clk), .en(cn_en), .x(x), .y(y), .parity(parity[m]));
    end
  endgenerate

  always @(posedge clk) begin
    if (load_we) begin
      if (rs) int0[load_addr*5 +: 5] <= load_data;
      else    int1[load_addr*5 +: 5] <= load_data;
    end
    dec_bit <= rs ? dec0[dec_addr] : dec1[dec_addr];
  end

  always @(posedge clk) begin
    if (rst) begin
      state <= S_IDLE; iter <= '0; rs <= 1'b0; frozen <= 1'b0;
    end else begin
      case (state)
        S_IDLE: begin
          if (swap) rs <= ~rs;
          if (start) begin
            iter <= '0; frozen <= 1'b0; c2v_q <= '0; state <= S_VA;
          end
        end
        S_VA: state <= S_VB;
        S_VB: state <= S_CN;
        S_CN: begin
          if (!frozen) begin
            if (rs) dec1 <= hd; else dec0 <= hd;
          end
          state <= S_CP;
        end
        S_CP: begin
          c2v_q <= c2v_d;
          if (!(|parity)) frozen <= 1'b1;
          if (iter == ITER-1) state <= S_IDLE;
          else begin iter <= iter + 1'b1; state <= S_VA; end
        end
        default: state <= S_IDLE;
      endcase
    end
  end

  assign busy = (state != S_IDLE);
  assign debug = {rs, frozen, iter[3:0]};
endmodule

`default_nettype wire
