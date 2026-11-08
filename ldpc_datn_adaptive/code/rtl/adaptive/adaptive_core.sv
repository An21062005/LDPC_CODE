// Adaptive QC-LDPC decoder core: one shared cluster of VN/CN units and one
// shared message memory; code (Z, block shifts) and the number of ACTIVE VN
// units (P_act) and CN units (C_act) are loaded at run time.
//
// Derived from ldpc_da2_qc_wifi/code/rtl/partly_parallel/ldpc_core_qc_pp.sv
// (same arithmetic units, flooding schedule, 18 iterations, zero c->v
// messages in the first VN phase, decisions frozen after the first CN phase
// with zero syndrome, same read/write latencies). What is new:
//   * one message bank (64 x 6) per block position of the UNION of the codes
//     built into the hardware (adaptive_hw_pkg.sv); a run-time table marks the
//     positions used by the current code and holds their shifts;
//   * VN unit p serves, step after step, the block columns listed in its
//     schedule table; CN unit q likewise serves block rows. The routing is a
//     multiplexer over the unit's candidate columns/rows (fixed at synthesis);
//     the table entries are produced and checked by script/mapper.py;
//   * Z (27 or 54) and the number of VN/CN steps are run-time registers.
// Configuration writes are accepted only while the core is idle; a write while
// busy is ignored and sets cfg_err (sticky until reset).
//
// Configuration address map (cfg_addr[11:0], data in cfg_data[7:0]):
//   0x000 Z   0x001 VN steps   0x002 CN steps
//   0x100+pos       {valid, shift[5:0]} for bank pos
//   0x400+p*KV+k    {valid, sel} VN unit p, step k (sel = candidate index)
//   0x800+q*KC+k    {valid, sel} CN unit q, step k
// Transaction interface identical to the ldpc_core modules of ldpc_da2_*.
`default_nettype none

module adaptive_core import adaptive_hw_pkg::*; #(
  parameter integer ITER = 18
)(
  input  wire        clk,
  input  wire        rst,
  input  wire        start,
  input  wire        swap,
  output wire        busy,
  input  wire        load_we,
  input  wire [10:0] load_addr,
  input  wire [4:0]  load_data,
  input  wire [10:0] dec_addr,
  output reg         dec_bit,
  input  wire        cfg_we,
  input  wire [11:0] cfg_addr,
  input  wire [7:0]  cfg_data,
  output reg         cfg_err,
  output wire [10:0] n_bits,
  output wire [5:0]  debug
);
  localparam integer VSW = (VCMAX > 1) ? $clog2(VCMAX) : 1;
  localparam integer CSW = (CCMAX > 1) ? $clog2(CCMAX) : 1;
  localparam [1:0] S_IDLE = 2'd0, S_VN = 2'd1, S_CN = 2'd2, S_EVAL = 2'd3;

  // Elaboration-time helpers over the package tables (255 = not reachable).
  function automatic integer vidx(input integer unit, input integer col);
    vidx = 255;
    for (int mm = 0; mm < VCMAX; mm++)
      if (mm < VCAND_N[unit*8 +: 8] && VCAND[(unit*VCMAX + mm)*8 +: 8] == col) vidx = mm;
  endfunction
  function automatic integer cidx(input integer unit, input integer row);
    cidx = 255;
    for (int mm = 0; mm < CCMAX; mm++)
      if (mm < CCAND_N[unit*8 +: 8] && CCAND[(unit*CCMAX + mm)*8 +: 8] == row) cidx = mm;
  endfunction
  function automatic integer slot_of(input integer row, input integer pos);
    slot_of = 255;
    for (int t = 0; t < DCS; t++) if (ROW_SLOT_POS[(row*DCS + t)*8 +: 8] == pos) slot_of = t;
  endfunction

  // ---------------- run-time configuration ----------------
  reg [5:0]     z;
  reg [5:0]     vsteps;
  reg [4:0]     csteps;
  reg [5:0]     pos_shift [0:NPOS-1];
  reg [NPOS-1:0] pos_valid;
  reg [VSW-1:0] vsel_t [0:PV*KV-1];
  reg [PV*KV-1:0] vval_t;
  reg [CSW-1:0] csel_t [0:PC*KC-1];
  reg [PC*KC-1:0] cval_t;

  reg [1:0] state;
  reg [5:0] i;                       // address inside a block
  reg [5:0] kv;
  reg [4:0] kc;
  reg [1:0] drain;
  reg [4:0] iter;
  reg       rs, frozen, syndrome;
  wire      first = (iter == 0);

  integer x;
  initial begin
    z = 6'd27; vsteps = 6'd1; csteps = 5'd1; pos_valid = '0; vval_t = '0; cval_t = '0;
    for (x = 0; x < NPOS; x = x + 1) pos_shift[x] = '0;
    for (x = 0; x < PV*KV; x = x + 1) vsel_t[x] = '0;
    for (x = 0; x < PC*KC; x = x + 1) csel_t[x] = '0;
  end

  always @(posedge clk) begin
    if (rst) cfg_err <= 1'b0;
    else if (cfg_we) begin
      if (state != S_IDLE) cfg_err <= 1'b1;
      else if (cfg_addr == 12'h000) z <= cfg_data[5:0];
      else if (cfg_addr == 12'h001) vsteps <= cfg_data[5:0];
      else if (cfg_addr == 12'h002) csteps <= cfg_data[4:0];
      else if (cfg_addr[11:8] == 4'h1 && cfg_addr[7:0] < NPOS) begin
        pos_valid[cfg_addr[7:0]] <= cfg_data[6];
        pos_shift[cfg_addr[7:0]] <= cfg_data[5:0];
      end else if (cfg_addr[11:10] == 2'b01 && cfg_addr[9:0] < PV*KV) begin
        vval_t[cfg_addr[9:0]] <= cfg_data[7];
        vsel_t[cfg_addr[9:0]] <= cfg_data[VSW-1:0];
      end else if (cfg_addr[11:10] == 2'b10 && cfg_addr[9:0] < PC*KC) begin
        cval_t[cfg_addr[9:0]] <= cfg_data[7];
        csel_t[cfg_addr[9:0]] <= cfg_data[CSW-1:0];
      end
    end
  end

  // ---------------- phase pipelines ----------------
  wire v_issue = (state == S_VN) && (kv < vsteps);
  wire c_issue = (state == S_CN) && (kc < csteps);
  reg  [2:0] v_valid;
  reg  [1:0] c_valid;
  reg  [5:0] i_d1, i_d2, i_d3;
  always @(posedge clk) begin
    v_valid <= {v_valid[1:0], v_issue};
    c_valid <= {c_valid[0], c_issue};
    i_d1 <= i; i_d2 <= i_d1; i_d3 <= i_d2;
  end
  wire v_write = v_valid[2];
  wire c_write = c_valid[1];

  // ---------------- load / decision address split (Z = 27 or 54) ----------
  wire [10:0] lq27 = load_addr / 27;
  wire [10:0] lc   = (z == 6'd54) ? (lq27 >> 1) : lq27;
  wire [5:0]  lj   = load_addr - lc * z;
  wire [10:0] dq27 = dec_addr / 27;
  wire [10:0] dc_  = (z == 6'd54) ? (dq27 >> 1) : dq27;
  wire [5:0]  dj   = dec_addr - dc_ * z;

  // ---------------- per-unit schedule selection (pipelined) ----------------
  reg [VSW-1:0] vsel_d1 [0:PV-1], vsel_d2 [0:PV-1], vsel_d3 [0:PV-1];
  reg [PV-1:0]  vval_d1, vval_d2, vval_d3;
  reg [CSW-1:0] csel_d1 [0:PC-1], csel_d2 [0:PC-1];
  reg [PC-1:0]  cval_d1, cval_d2;
  integer u;
  always @(posedge clk) begin
    for (u = 0; u < PV; u = u + 1) begin
      vsel_d1[u] <= vsel_t[u*KV + kv]; vval_d1[u] <= v_issue && vval_t[u*KV + kv];
      vsel_d2[u] <= vsel_d1[u]; vval_d2[u] <= vval_d1[u];
      vsel_d3[u] <= vsel_d2[u]; vval_d3[u] <= vval_d2[u];
    end
    for (u = 0; u < PC; u = u + 1) begin
      csel_d1[u] <= csel_t[u*KC + kc]; cval_d1[u] <= c_issue && cval_t[u*KC + kc];
      csel_d2[u] <= csel_d1[u]; cval_d2[u] <= cval_d1[u];
    end
  end

  wire [5:0]      bq   [0:NPOS-1];       // registered bank read data
  wire [DVS*6-1:0] vy  [0:PV-1];
  wire [PV-1:0]   vhd;
  wire [DCS*5-1:0] cy  [0:PC-1];
  wire [PC-1:0]   cpar;
  wire [4:0]      zq   [0:NB-1];         // intrinsic read per block column
  wire [NB-1:0]   dec_rd;

  genvar b, p, q, m, k, t;
  generate
    // ---------------- shared message banks ----------------
    for (b = 0; b < NPOS; b = b + 1) begin : g_bank
      localparam integer BR = POS_ROW[b*8 +: 8];
      localparam integer BC = POS_COL[b*8 +: 8];
      localparam integer BS = slot_of(BR, b);          // CN unit input slot of this bank
      reg [5:0] mem [0:63];
      reg [5:0] rq;
      reg [5:0] ca1, ca2;
      wire [6:0] sum   = i + pos_shift[b];
      wire [5:0] caddr = (sum >= z) ? sum - z : sum[5:0];   // (i + shift) mod Z
      // writers: the VN units that can serve column BC, the CN units for row BR
      wire [PV-1:0] vh;  wire [5:0] vd [0:PV-1];
      wire [PC-1:0] ch;  wire [5:0] cd [0:PC-1];
      for (k = 0; k < PV; k = k + 1) begin : g_vw
        localparam integer MI = vidx(k, BC);
        if (MI != 255) begin : g_on
          assign vh[k] = vval_d3[k] && (vsel_d3[k] == MI);
          assign vd[k] = vy[k][BR*6 +: 6];
        end else begin : g_off
          assign vh[k] = 1'b0; assign vd[k] = 6'd0;
        end
      end
      for (k = 0; k < PC; k = k + 1) begin : g_cw
        localparam integer MI = cidx(k, BR);
        if (MI != 255) begin : g_on
          assign ch[k] = cval_d2[k] && (csel_d2[k] == MI);
          assign cd[k] = {1'b0, cy[k][BS*5 +: 5]};
        end else begin : g_off
          assign ch[k] = 1'b0; assign cd[k] = 6'd0;
        end
      end
      reg [5:0] vdat, cdat;
      integer w;
      always @* begin
        vdat = 6'd0; cdat = 6'd0;
        for (w = 0; w < PV; w = w + 1) if (vh[w]) vdat = vdat | vd[w];
        for (w = 0; w < PC; w = w + 1) if (ch[w]) cdat = cdat | cd[w];
      end
      initial begin for (w = 0; w < 64; w = w + 1) mem[w] = 6'd0; rq = 6'd0; end
      always @(posedge clk) begin
        if (v_issue) rq <= mem[i];
        else if (c_issue) rq <= mem[caddr];
        ca1 <= caddr; ca2 <= ca1;
        if (v_write && |vh) mem[i_d3] <= vdat;
        else if (c_write && |ch) mem[ca2] <= cdat;
      end
      assign bq[b] = pos_valid[b] ? rq : 6'd0;              // unused position = neutral
    end

    // ---------------- intrinsic / decision memories per block column ------
    for (b = 0; b < NB; b = b + 1) begin : g_col
      reg [4:0] im [0:127];              // {bank, j}
      reg       dm [0:127];
      reg [4:0] zr;
      wire [PV-1:0] wh;
      for (k = 0; k < PV; k = k + 1) begin : g_w
        localparam integer MI = vidx(k, b);
        if (MI != 255) begin : g_on
          assign wh[k] = vval_d3[k] && (vsel_d3[k] == MI);
        end else begin : g_off
          assign wh[k] = 1'b0;
        end
      end
      wire wbit = |(wh & vhd);
      integer w;
      initial begin for (w = 0; w < 128; w = w + 1) begin im[w] = 5'd0; dm[w] = 1'b0; end zr = 5'd0; end
      always @(posedge clk) begin
        if (v_issue) zr <= im[{rs, i}];
        if (load_we && lc == b) im[{~rs, lj}] <= load_data;
        if (v_write && |wh && !frozen) dm[{rs, i_d3}] <= wbit;
      end
      assign zq[b] = zr;
      assign dec_rd[b] = dm[{~rs, dj}];
    end

    // ---------------- VN units: input mux over candidate columns ----------
    for (p = 0; p < PV; p = p + 1) begin : g_vn
      localparam integer NC = VCAND_N[p*8 +: 8];
      wire [DVS*5-1:0] xt [0:VCMAX-1];
      wire [4:0]       zt [0:VCMAX-1];
      for (m = 0; m < VCMAX; m = m + 1) begin : g_m
        if (m < NC) begin : g_on
          localparam integer COL = VCAND[(p*VCMAX + m)*8 +: 8];
          assign zt[m] = zq[COL];
          for (t = 0; t < DVS; t = t + 1) begin : g_r
            localparam integer PS = POS_AT[(t*NB + COL)*8 +: 8];
            if (PS != 255) begin : g_b
              assign xt[m][t*5 +: 5] = bq[PS][4:0];
            end else begin : g_z
              assign xt[m][t*5 +: 5] = 5'd0;
            end
          end
        end else begin : g_off
          assign xt[m] = '0; assign zt[m] = 5'd0;
        end
      end
      reg [DVS*5-1:0] xin;
      reg [4:0]       zin;
      integer w;
      always @* begin
        xin = '0; zin = 5'd0;
        for (w = 0; w < VCMAX; w = w + 1)
          if (vsel_d1[p] == w) begin xin = first ? '0 : xt[w]; zin = zt[w]; end
      end
      vn_unit #(.DV(DVS)) u (.clk(clk), .en(1'b1), .z(zin), .x(xin), .y(vy[p]), .hd(vhd[p]));
    end

    // ---------------- CN units: input mux over candidate rows -------------
    for (q = 0; q < PC; q = q + 1) begin : g_cn
      localparam integer NR = CCAND_N[q*8 +: 8];
      wire [DCS*6-1:0] xt [0:CCMAX-1];
      for (m = 0; m < CCMAX; m = m + 1) begin : g_m
        if (m < NR) begin : g_on
          localparam integer ROW = CCAND[(q*CCMAX + m)*8 +: 8];
          for (t = 0; t < DCS; t = t + 1) begin : g_s
            localparam integer PS = ROW_SLOT_POS[(ROW*DCS + t)*8 +: 8];
            if (PS != 255) begin : g_b
              assign xt[m][t*6 +: 6] = bq[PS];
            end else begin : g_z
              assign xt[m][t*6 +: 6] = 6'd0;
            end
          end
        end else begin : g_off
          assign xt[m] = '0;
        end
      end
      reg [DCS*6-1:0] xin;
      integer w;
      always @* begin
        xin = '0;
        for (w = 0; w < CCMAX; w = w + 1) if (csel_d1[q] == w) xin = xt[w];
      end
      // NZ = 8: script/mapper.py rejects any code with a block-row degree above 8
      cn_unit #(.DC(DCS), .NZ(8)) u (.clk(clk), .en(1'b1), .x(xin), .y(cy[q]), .parity(cpar[q]));
    end
  endgenerate

  always @(posedge clk) dec_bit <= dec_rd[dc_];

  // ---------------- control ----------------
  always @(posedge clk) begin
    if (rst) begin
      state <= S_IDLE; i <= '0; kv <= '0; kc <= '0; drain <= '0; iter <= '0;
      rs <= 1'b0; frozen <= 1'b0; syndrome <= 1'b0;
    end else begin
      case (state)
        S_IDLE: begin
          if (swap) rs <= ~rs;
          if (start) begin
            iter <= '0; frozen <= 1'b0; i <= '0; kv <= '0; drain <= '0; state <= S_VN;
          end
        end
        S_VN: begin
          if (v_issue) begin
            if (i == z - 1) begin i <= '0; kv <= kv + 1'b1; end else i <= i + 1'b1;
          end else if (drain == 2'd2) begin
            drain <= '0; i <= '0; kc <= '0; syndrome <= 1'b0; state <= S_CN;
          end else drain <= drain + 1'b1;
        end
        S_CN: begin
          if (c_write) syndrome <= syndrome | (|(cpar & cval_d2));
          if (c_issue) begin
            if (i == z - 1) begin i <= '0; kc <= kc + 1'b1; end else i <= i + 1'b1;
          end else if (drain == 2'd1) begin
            drain <= '0; state <= S_EVAL;
          end else drain <= drain + 1'b1;
        end
        S_EVAL: begin
          if (!syndrome) frozen <= 1'b1;
          i <= '0; kv <= '0;
          if (iter == ITER-1) state <= S_IDLE;
          else begin iter <= iter + 1'b1; state <= S_VN; end
        end
      endcase
    end
  end

  assign busy   = (state != S_IDLE);
  assign n_bits = NB * z;
  assign debug  = {rs, frozen, iter[3:0]};
endmodule

`default_nettype wire
