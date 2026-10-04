// SPDX-FileCopyrightText: (c) 2026 General-Purpose Protocol ASIC contributors
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

// =============================================================================
// host_if.v — Tiny Tapeout host bridge (SPI slave, mode 0, async-tolerant).
//
// Pin plan (uio = the 18-bit internal bidirectional set; see docs/GPIO.md):
//   uio[7]  = H_CS_n    (input, async)
//   uio[6]  = H_SCLK    (input, async)
//   uio[5]  = H_MOSI    (input, async)
//   uio[4]  = H_MISO    (output, driven only while CS active; released else)
//   uio[3:0]= general protocol pins shared with GPIO fabric
//   uio[15:8] = additional protocol pins (GPIO fabric width is 8 on the low
//               nibble + 4 upper used for extended protocols when present)
// For the verified 6x4 build the GPIO fabric is 8 wide (uio[3:0], uio[2:0]...
// see top-level mapping); host occupies uio[7:4].
//
// Frame: first byte after CS fall = {RW, A[5:0], W/R?} -> bit15 style:
//        byte0 = {RW(1), A(5), 0(2)}   RW=1 write, RW=0 read
//        byte1 = data (write: host->ASIC; read: ASIC->host)
//        Multi-byte burst: repeated byte1 transfers auto-increment ADDR.
// Register map (A):
//   0x01 CTRL   W: b0=en_core b1=soft_rst b2=clr_trace b3=rst_time
//                R: {4'h0, rst_time_l, clr_trace_l, soft_rst_l, en_core}
//   0x02 STAT   R: {trfull,tr_empty,rx_empty,tx_full,err_any,run_any,2'b0}
//   0x03 ADDR_L W/R: xfer address [7:0]
//   0x04 ADDR_H W/R: {dm_sel[1:0], xfer addr [8], trace_mode, 4'b0? } exact:
//                bits[1:0]=dm window select, bit2 = xfer addr bit8, bit3=trace pop
//   0x05 DATA   burst R/W program memory at xfer_addr
//   0x06 DM     burst R/W data-memory window selected by dm_sel
//                (00=T0 rf,01=T1,10=T2/3 mux,11=shared window)
//   0x07 THRCTL W: {pc_load_en(bit4), tid[1:0]} sets run bitmap pulse apply
//                R: {4'h0, thread_run[3:0]}
//   0x08 PC_L   W: pc load value low 8 bits (for tid in THRCTL)
//   0x09 PC_H   W: pc load value high bit + err clear bits [6:4]
//   0x0A MBX    burst: W pushes host->engine fifo; R pops engine->host fifo
//   0x0B TRC    burst R: pops trace entries (byte stream, evt nibble interleaved)
//   0x0C ID     R: 8'hJ5
//
// CDC: all host inputs pass a 2-flop synchronizer; SPI logic runs in core
// domain. Max reliable SCLK ~= clk/8 (verified: 50MHz core => 6MHz host SPI).
// =============================================================================

`include "defines.vh"

module host_if (
    input  wire                    clk,
    input  wire                    rst_n,

    // pad side (async)
    input  wire                    h_cs_n_raw,
    input  wire                    h_sclk_raw,
    input  wire                    h_mosi_raw,
    output reg                     h_miso,
    output reg                     h_miso_oe,

    // core control
    output reg                     en_core,
    output reg                     soft_rst_pulse,
    output reg                     clr_trace_pulse,
    output reg                     rst_time_pulse,
    output reg  [3:0]              thread_run,      // level start/stop bitmap
    output reg                     pc_load_we,      // pulse
    output reg  [1:0]              pc_load_tid,
    output reg  [`JP_PROG_AW-1:0]  pc_load_val,
    output reg  [3:0]              err_clr,         // pulse bitmap

    // progmem port (byte-wide writes merge two bytes per word via addr LSB)
    output reg                     pm_we,
    output reg  [`JP_PROG_AW-1:0]  pm_addr,
    output reg  [15:0]             pm_wdata,
    output reg                     pm_be,           // 1=high byte,0=low byte
    input  wire [`JP_INST_W-1:0]   pm_rdata,

    // dm port (8-bit address space, byte enables)
    output reg                     dm_we,
    output reg  [7:0]              dm_addr,
    output reg  [15:0]             dm_wdata,
    output reg                     dm_be,
    input  wire [15:0]             dm_rdata,

    // mailbox fifos
    output reg                     mb_h2e_wr,
    output reg  [7:0]              mb_h2e_wdata,
    input  wire [7:0]              mb_e2h_rdata,
    output reg                     mb_e2h_rd,

    // trace stream
    input  wire [35:0]             tr_head,         // peek current entry
    output reg                     tr_pop,
    input  wire                    trace_full,
    input  wire                    trace_empty,

    // status
    input  wire [3:0]              rx_fifo_state,   // {empty,full} packed etc.
    input  wire [3:0]              err_bitmap,
    input  wire [3:0]              running_bitmap
);

  // ---------------- synchronizers ----------------
  reg [2:0] cs_s, sclk_s, mosi_s;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cs_s <= 3'b111; sclk_s <= 3'b001; mosi_s <= 3'b001;
    end else begin
      cs_s   <= {cs_s[1:0], h_cs_n_raw};
      sclk_s <= {sclk_s[1:0], h_sclk_raw};
      mosi_s <= {mosi_s[1:0], h_mosi_raw};
    end
  end

  wire cs_active  = ~cs_s[1];
  wire sclk_rise  = (sclk_s[2:0] == 3'b001);
  wire sclk_fall  = (sclk_s[2:0] == 3'b110);
  wire cs_fall    = (cs_s[2:0] == 3'b110);

  // ---------------- shift registers ----------------
  reg [2:0] bitcnt;
  reg [7:0] rx_sh, tx_sh;
  reg       rwbit;
  reg [5:0] reg_addr;
  reg       cmd_done;

  // register-map state
  reg [8:0] xfer_addr;
  reg [1:0] dm_sel;
  reg       tr_phase;          // alternates through trace entry bytes
  reg [7:0] ctrl_l;            // latched ctrl bits for readback

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bitcnt <= 3'd0; rx_sh <= 8'h0; tx_sh <= 8'h0; rwbit <= 1'b0;
      reg_addr <= 6'h0; cmd_done <= 1'b0;
      xfer_addr <= 9'h0; dm_sel <= 2'd0; tr_phase <= 1'b0; ctrl_l <= 8'h0;
      en_core <= 1'b0; soft_rst_pulse <= 1'b0; clr_trace_pulse <= 1'b0;
      rst_time_pulse <= 1'b0; thread_run <= 4'h0; pc_load_we <= 1'b0;
      pc_load_tid <= 2'd0; pc_load_val <= 9'h0; err_clr <= 4'h0;
      pm_we <= 1'b0; pm_addr <= 9'h0; pm_wdata <= 16'h0; pm_be <= 1'b0;
      dm_we <= 1'b0; dm_addr <= 8'h0; dm_wdata <= 16'h0; dm_be <= 1'b0;
      mb_h2e_wr <= 1'b0; mb_h2e_wdata <= 8'h0; mb_e2h_rd <= 1'b0; tr_pop <= 1'b0;
      h_miso <= 1'b0; h_miso_oe <= 1'b0;
    end else begin
      // default: pulses one cycle
      soft_rst_pulse <= 1'b0; clr_trace_pulse <= 1'b0; rst_time_pulse <= 1'b0;
      pc_load_we <= 1'b0; err_clr <= 4'h0;
      pm_we <= 1'b0; dm_we <= 1'b0; mb_h2e_wr <= 1'b0; mb_e2h_rd <= 1'b0;
      tr_pop <= 1'b0;

      if (cs_fall) begin
        cmd_done <= 1'b0; bitcnt <= 3'd0; tr_phase <= 1'b0;
        h_miso_oe <= 1'b0;
      end

      if (cs_active) begin
        if (sclk_rise) begin
          rx_sh <= {rx_sh[6:0], mosi_s[1]};
          if (bitcnt == 3'd7) begin
            bitcnt <= 3'd0;
            if (!cmd_done) begin
              rwbit    <= rx_sh[7];
              reg_addr <= rx_sh[6:1];
              cmd_done <= 1'b1;
              // preload first read byte
              tx_sh    <= read_byte(rx_sh[7]);
            end
          end else begin
            bitcnt <= bitcnt + 3'd1;
          end
        end
        if (sclk_fall) begin
          h_miso    <= tx_sh[7];
          h_miso_oe <= 1'b1;
          if (bitcnt == 3'd7) begin
            // byte boundary: act on writes, prepare next read byte
            handle_write({rx_sh[6:0], mosi_s[1]});
            tx_sh <= read_byte(rwbit);
            if (!rwbit && reg_addr == 6'h0B && tr_cnt == 3'd4) tr_pop <= 1'b1;
          end else begin
            tx_sh <= {tx_sh[6:0], 1'b0};
          end
        end
      end else begin
        h_miso_oe <= 1'b0;
      end
    end
  end

  // ---------------- write handling ----------------
  task automatic handle_write(input [7:0] d);
    begin
      case (reg_addr)
        6'h01: begin
          en_core        <= d[0];
          if (d[1]) soft_rst_pulse    <= 1'b1;
          if (d[2]) clr_trace_pulse   <= 1'b1;
          if (d[3]) rst_time_pulse    <= 1'b1;
          ctrl_l <= d;
        end
        6'h03: xfer_addr[7:0] <= d;
        6'h04: begin xfer_addr[8] <= d[2]; dm_sel <= d[1:0]; end
        6'h05: begin // progmem burst, byte-wise: even addr = low byte
          pm_we    <= 1'b1;
          pm_addr  <= xfer_addr[`JP_PROG_AW-1:0];
          pm_be    <= xfer_addr[0];
          pm_wdata <= {d, d};
          xfer_addr<= xfer_addr + 9'd1;
        end
        6'h06: begin // dm burst (word granularity)
          dm_we    <= 1'b1;
          dm_addr  <= {dm_sel, xfer_addr[5:0]};
          dm_be    <= xfer_addr[0];
          dm_wdata <= {d, d};
          xfer_addr<= xfer_addr + 9'd1;
        end
        6'h07: begin
          thread_run <= d[3:0];
          pc_load_tid<= d[1:0];
          if (d[4]) pc_load_we <= 1'b1;
        end
        6'h08: pc_load_val[7:0] <= d;
        6'h09: begin
          pc_load_val[8] <= d[0];
          err_clr        <= {1'b0, d[6:4]};
        end
        6'h0A: begin mb_h2e_wr <= 1'b1; mb_h2e_wdata <= d; end
        6'h0B: tr_pop <= 1'b1;   // each read advances; handled in read path too
        default: ;
      endcase
    end
  endtask

  // ---------------- read mux ----------------
  function automatic [7:0] read_byte(input rw);
    reg [7:0] v;
    begin
      v = 8'h00;
      if (!rw) begin
        case (reg_addr)
          6'h01: v = ctrl_l;
          6'h02: v = {trace_full, trace_empty, rx_fifo_state[0], rx_fifo_state[1],
                      |err_bitmap, |running_bitmap, 2'b00};
          6'h03: v = xfer_addr[7:0];
          6'h04: v = {5'h0, xfer_addr[8], dm_sel};
          6'h05: v = xfer_addr[0] ? pm_rdata[15:8] : pm_rdata[7:0];
          6'h06: v = xfer_addr[0] ? dm_rdata[15:8] : dm_rdata[7:0];
          6'h07: v = {4'h0, thread_run};
          6'h08: v = pc_load_val[7:0];
          6'h09: v = {1'b0, err_bitmap, 2'b00, pc_load_val[8]};
          6'h0A: v = mb_e2h_rdata;
          6'h0B: v = sel_trb();
          6'h0C: v = 8'h35; // ID byte: '5' = v0.5
          default: v = 8'h00;
        endcase
      end
      read_byte = v;
    end
  endfunction

  // trace byte stream selector: cycles through entry bytes on successive reads
  reg [2:0] tr_cnt;
  initial tr_cnt = 3'd0;
  always @(posedge clk) begin
    if (!rst_n || !cs_active) tr_cnt <= 3'd0;
    else if (sclk_fall && bitcnt == 3'd7 && !rwbit && reg_addr == 6'h0B)
      tr_cnt <= (tr_cnt == 3'd4) ? 3'd0 : tr_cnt + 3'd1;
  end
  function automatic [7:0] sel_trb;
    begin
      case (tr_cnt)
        3'd0: sel_trb = tr_head[7:0];
        3'd1: sel_trb = tr_head[15:8];
        3'd2: sel_trb = tr_head[23:16];
        3'd3: sel_trb = tr_head[31:24];
        default: sel_trb = {4'h0, tr_head[35:32]};
      endcase
    end
  endfunction

endmodule
