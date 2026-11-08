// Serial LDPC decoder core: ONE variable-node unit and ONE check-node unit.
//
// Same algorithm/schedule as the da2 core: flooding, ITER iterations, each a
// VN phase then a CN phase; check->variable messages are zero in the first VN
// phase; decisions are written in every VN phase until a CN phase finds a
// zero syndrome, after which they are frozen. The core always runs ITER
// iterations (no early exit), exactly like da2.
//
// Message memory: E entries x 6 bits in VN-major edge order, one read and one
// write per clock. A node is gathered one edge per clock, processed by the
// unit, and its results are scattered one edge per clock while the next node
// is gathered. Edge order, slot and last-edge flags come from serial_rom
// (generated from H by script/gen_rtl.py).
//
// Transaction interface (shared with the Fully-Parallel core):
//   start : decode the intrinsic bank selected by rs (frame loaded earlier)
//   load_*: write the other intrinsic bank (~rs) while decoding
//   dec_* : read decisions of the other decision bank (~rs), 1-cycle latency
//   swap  : toggle rs when the transaction is complete (core idle)
`default_nettype none

module ldpc_core import ldpc_code_pkg::*; #(
  parameter integer N = LDPC_N,
  parameter integer M = LDPC_M,
  parameter integer E = LDPC_E,
  parameter integer DV = LDPC_DVMAX,
  parameter integer DC = LDPC_DCMAX,
  parameter integer ITER = 18,
  parameter integer AW = $clog2(N),
  parameter integer EW = $clog2(E),
  parameter integer SW = 4            // slot index width
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
  localparam integer FD = 4;          // result FIFO depth (nodes)
  localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_NEXT = 2'd2;

  reg [1:0]  state;
  reg        rs;
  reg        phase;                   // 0: VN phase, 1: CN phase
  reg [4:0]  iter;
  reg        frozen;
  reg        syndrome;

  // ---------------- memories ----------------
  reg [5:0]  msg_mem [0:E-1];
  reg [4:0]  int_mem [0:(2<<AW)-1];   // {bank, vn}
  reg        dec_mem [0:(2<<AW)-1];   // {bank, vn}
  integer k;
  initial begin
    for (k = 0; k < E; k = k + 1)   msg_mem[k] = 6'd0;
    for (k = 0; k < (2<<AW); k = k + 1) begin int_mem[k] = 5'd0; dec_mem[k] = 1'b0; end
  end

  always @(posedge clk) if (load_we) int_mem[{~rs, load_addr}] <= load_data;
  always @(posedge clk) dec_bit <= dec_mem[{~rs, dec_addr}];

  // ---------------- read (gather) pipeline ----------------
  // R0: order index -> ROM ; R1: edge address -> memories ; R2: data
  wire        stall;
  wire        ren = !stall;
  reg  [EW:0] rptr;
  reg         r1_v, r2_v;
  wire [EW-1:0] r_addr, w_addr;
  wire [SW-1:0] r_slot, w_slot;
  wire          r_last, w_last;
  reg  [AW-1:0] r1_node, r2_node;
  reg  [EW:0]   r1_idx, r2_idx;     // order index carried with the edge
  reg  [SW-1:0] r2_slot;
  reg           r2_last;
  reg  [5:0]    r2_msg;
  reg  [4:0]    r2_int;
  wire          r0_issue = (state == S_RUN) && (rptr < E);

  reg  [EW:0] wptr;                   // scatter order index
  reg         w1_v;

  serial_rom rom (
    .clk(clk),
    .en_a(ren), .addr_a({phase, rptr[EW-1:0]}), .edge_a(r_addr), .slot_a(r_slot), .last_a(r_last),
    .en_b(1'b1), .addr_b({phase, wptr[EW-1:0]}), .edge_b(w_addr), .slot_b(w_slot), .last_b(w_last)
  );

  always @(posedge clk) begin
    if (ren) begin
      r2_msg <= msg_mem[r_addr];
      r2_int <= int_mem[{rs, r1_node}];
    end
  end

  always @(posedge clk) begin
    if (rst || state != S_RUN) begin
      rptr <= '0; r1_v <= 1'b0; r2_v <= 1'b0; r1_node <= '0; r2_node <= '0;
      r1_idx <= '0; r2_idx <= '0;
      r2_slot <= '0; r2_last <= 1'b0;
    end else if (ren) begin
      rptr    <= r0_issue ? rptr + 1'b1 : rptr;
      r1_v    <= r0_issue;
      r2_v    <= r1_v;
      r2_slot <= r_slot;
      r2_last <= r_last;
      r2_node <= r1_node;
      r1_idx  <= rptr;
      r2_idx  <= r1_idx;
      if (r1_v && r_last) r1_node <= r1_node + 1'b1;
    end
  end

  // ---------------- gather and fire ----------------
  reg  [DV*5-1:0] gv;                 // VN gather: check->variable messages
  reg  [DC*6-1:0] gc;                 // CN gather: variable->check messages
  wire [4:0]      c2v_in = (iter == 0) ? 5'd0 : r2_msg[4:0];
  wire            fire = r2_v && r2_last && ren;
  reg  [DV*5-1:0] vx_q;
  reg  [4:0]      vz_q;
  reg  [DC*6-1:0] cx_q;
  reg  [AW-1:0]   node_q;

  always @(posedge clk) begin
    if (rst || state != S_RUN) begin
      gv <= '0; gc <= '0;
    end else if (r2_v && ren) begin
      if (r2_last) begin
        gv <= '0; gc <= '0;            // unused slots stay neutral (zero)
      end else begin
        gv[r2_slot*5 +: 5] <= c2v_in;
        gc[r2_slot*6 +: 6] <= r2_msg;
      end
    end
  end

  always @(posedge clk) begin
    if (fire) begin
      vx_q <= gv; vx_q[r2_slot*5 +: 5] <= c2v_in;
      cx_q <= gc; cx_q[r2_slot*6 +: 6] <= r2_msg;
      vz_q <= r2_int;
      node_q <= r2_node;
    end
  end

  // Units run continuously; inputs are held between fires. VNU output is valid
  // two clocks after its inputs change, CNU output one clock after.
  wire [DV*6-1:0] vy;
  wire [DC*5-1:0] cy;
  wire            vhd, cpar;
  vn_unit #(.DV(DV)) vnu (.clk(clk), .en(1'b1), .z(vz_q), .x(vx_q), .y(vy), .hd(vhd));
  cn_unit #(.DC(DC)) cnu (.clk(clk), .en(1'b1), .x(cx_q), .y(cy), .parity(cpar));

  // fire edge e0 loads the unit inputs. CNU output is valid after e1 (push at
  // e2, fpipe[1]); VNU output is valid after e2 (push at e3, fpipe[2]).
  reg  [2:0]  fpipe;
  reg  [EW:0] end_pipe [0:2];
  reg  [AW-1:0] nid_pipe [0:2];
  always @(posedge clk) begin
    if (rst || state != S_RUN) fpipe <= '0;
    else fpipe <= {fpipe[1:0], fire};
    end_pipe[0] <= r2_idx + 1'b1;     // order index after this node's last edge
    end_pipe[1] <= end_pipe[0];
    end_pipe[2] <= end_pipe[1];
    nid_pipe[0] <= r2_node;
    nid_pipe[1] <= nid_pipe[0];
    nid_pipe[2] <= nid_pipe[1];
  end
  wire push = phase ? fpipe[1] : fpipe[2];
  wire [EW:0]   push_end = phase ? end_pipe[1] : end_pipe[2];
  wire [AW-1:0] push_nid = phase ? nid_pipe[1] : nid_pipe[2];

  // ---------------- result FIFO ----------------
  localparam integer RW = (DV*6 > DC*5) ? DV*6 : DC*5;
  reg [RW-1:0]  fifo_y   [0:FD-1];
  reg           fifo_b   [0:FD-1];    // hard decision (VN) or parity (CN)
  reg [AW-1:0]  fifo_nid [0:FD-1];
  reg [1:0]     fifo_wp, fifo_rp;
  reg [2:0]     fifo_cnt;
  reg [EW:0]    pushed_end;
  wire          pop;
  wire [2:0]    inflight = phase ? fpipe[0] + fpipe[1] : fpipe[0] + fpipe[1] + fpipe[2];
  assign stall = r2_v && r2_last && (fifo_cnt + inflight >= FD);

  always @(posedge clk) begin
    if (rst || state != S_RUN) begin
      fifo_wp <= '0; fifo_rp <= '0; fifo_cnt <= '0; pushed_end <= '0;
    end else begin
      if (push) begin
        fifo_y[fifo_wp]   <= phase ? {{(RW-DC*5){1'b0}}, cy} : {{(RW-DV*6){1'b0}}, vy};
        fifo_b[fifo_wp]   <= phase ? cpar : vhd;
        fifo_nid[fifo_wp] <= push_nid;
        fifo_wp <= fifo_wp + 1'b1;
        pushed_end <= push_end;
      end
      if (pop) fifo_rp <= fifo_rp + 1'b1;
      fifo_cnt <= fifo_cnt + push - pop;
    end
  end

  // ---------------- scatter (write) pipeline ----------------
  wire w0_issue = (state == S_RUN) && (wptr < pushed_end);
  assign pop = w1_v && w_last;
  wire [RW-1:0] head = fifo_y[fifo_rp];
  wire [5:0]    wdata = phase ? {1'b0, head[w_slot*5 +: 5]} : head[w_slot*6 +: 6];

  always @(posedge clk) begin
    if (rst || state != S_RUN) begin
      wptr <= '0; w1_v <= 1'b0;
    end else begin
      wptr <= w0_issue ? wptr + 1'b1 : wptr;
      w1_v <= w0_issue;
    end
  end
  always @(posedge clk) if (w1_v) msg_mem[w_addr] <= wdata;

  // Decisions: written when a VN result leaves the FIFO, unless frozen.
  always @(posedge clk) begin
    if (state == S_RUN && pop && !phase && !frozen)
      dec_mem[{rs, fifo_nid[fifo_rp]}] <= fifo_b[fifo_rp];
  end

  // ---------------- phase / iteration control ----------------
  wire phase_done = (rptr == E) && !r1_v && !r2_v && (fpipe == 3'd0) &&
                    (fifo_cnt == 0) && (wptr == E) && !w1_v;
  always @(posedge clk) begin
    if (rst) begin
      state <= S_IDLE; rs <= 1'b0; phase <= 1'b0; iter <= '0;
      frozen <= 1'b0; syndrome <= 1'b0;
    end else begin
      case (state)
        S_IDLE: begin
          if (swap) rs <= ~rs;
          if (start) begin
            phase <= 1'b0; iter <= '0; frozen <= 1'b0; syndrome <= 1'b0;
            state <= S_RUN;
          end
        end
        S_RUN: begin
          if (pop && phase) syndrome <= syndrome | fifo_b[fifo_rp];
          if (phase_done) state <= S_NEXT;
        end
        S_NEXT: begin
          if (!phase) begin
            phase <= 1'b1; syndrome <= 1'b0; state <= S_RUN;
          end else begin
            if (!syndrome) frozen <= 1'b1;
            phase <= 1'b0;
            if (iter == ITER-1) state <= S_IDLE;
            else begin iter <= iter + 1'b1; state <= S_RUN; end
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end

  assign busy = (state != S_IDLE);
  assign debug = {rs, frozen, iter[3:0]};
endmodule

`default_nettype wire
