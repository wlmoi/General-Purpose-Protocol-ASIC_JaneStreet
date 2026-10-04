// SPDX-FileCopyrightText: (c) 2026 General-Purpose Protocol ASIC contributors
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

// =============================================================================
// csr.v — thread-visible control/status register file + event system.
// One writer per cycle (the granted thread; scheduler guarantees this).
// Read data is combinational (same-cycle as the granting decision).
// =============================================================================

`include "defines.vh"

module csr (
    input  wire                    clk,
    input  wire                    rst_n,

    // thread access (granted thread only)
    input  wire                    we,
    input  wire                    re,
    input  wire [5:0]              addr,
    input  wire [15:0]             wdata,
    output reg  [15:0]             rdata,

    // identity / context mux inputs (from top)
    input  wire [1:0]              sel_tid,        // granting thread id
    input  wire [`JP_TIME_W-1:0]   time_q,
    input  wire [`JP_TIME_W-1:0]   dl0, dl1, dl2, dl3,
    input  wire [15:0]             x0, x1, x2, x3,
    input  wire                    en_core,

    // bit engine status
    input  wire [4:0]              be_txcount,
    input  wire [4:0]              be_rxcount,
    input  wire [15:0]             be_shreg,
    input  wire                    crc_busy,

    // fifo status
    input  wire                    rx_full, rx_empty,
    input  wire                    tx_full, tx_empty,
    input  wire                    tr_full, tr_empty,
    input  wire [35:0]             tr_head,
    input  wire [7:0]              rx_rdata,

    // thread software trigger (EXT.TRG): OR-mask into ISR this cycle
    input  wire                    ext_trg_we,
    input  wire [3:0]              ext_trg_bits,

    // gpio views
    input  wire [`JP_GPIO_W-1:0]   gout_q, goe_q, sync_q,
    input  wire [`JP_GPIO_W-1:0]   own_in, own_oe,
    input  wire [`JP_GPIO_W-1:0]   edge_pulse,
    input  wire                    drv_err_pulse,
    input  wire [1:0]              drv_err_tid,

    // edge unit status
    input  wire [7:0]              edg_valid,
    input  wire                    edg_fired,

    // thread state vectors
    input  wire [3:0]              waiting_vec,
    input  wire [3:0]              running_vec,
    input  wire [3:0]              err_sticky_vec,
    input  wire [8:0]              pc0, pc1, pc2, pc3,
    input  wire [5:0]              sp0, sp1, sp2, sp3,

    // outputs to other blocks
    output reg                     clr_trace,
    output reg                     trace_en,
    output reg                     tr_pop,
    output reg                     owm_we,
    output reg  [1:0]              owm_tgt,
    output reg  [`JP_GPIO_W-1:0]   owm_data,
    output reg  [3:0]              err_clr,      // pulse bitmap (sticky err clear)

    // deadline control
    output reg                     dclr_we,
    output reg  [1:0]              dclr_sel,
    output reg  [`JP_TIME_W-1:0]   dclr_val,
    output reg                     start_pulse,
    output reg  [1:0]              start_tid,

    // thread ctrl via CSR_THCTRL ({sel in bits[?]}): decoded below
    input  wire [1:0]              host_thr_sel,  // from host PC-load path (unused here)

    // thread EXT.IDLE wake-mask store (per-thread)
    input  wire                    ext_idle_we,
    input  wire [1:0]              ext_idle_tid,
    input  wire [15:0]             ext_idle_mask,

    // bit engine control fan-out
    output reg                     be_cfg_we,
    output reg  [3:0]              be_cfg_addr,
    output reg  [15:0]             be_cfg_wdata,

    // idle wake mask per thread
    output reg  [15:0]             idle_mask0, idle_mask1, idle_mask2, idle_mask3,

    // global event level for WAIT EV / EXT.IDLE
    output wire [15:0]             isr_q,
    output wire [15:0]             evt_now
);

  // ------------------------------------------------------------------ state
  reg [15:0] isr;
  reg [15:0] trig_mask;
  reg [15:0] crc_pl, crc_ph, crc_ol, crc_oh;
  reg [4:0]  crc_ls;
  reg [15:0] crc_seed;
  reg        crc_seed_load;
  reg [7:0]  gpo_wr; reg gpo_we;
  reg [7:0]  goe_wr; reg goe_we;
  reg [5:0]  errcnt;
  reg        sel_dbg;
  reg [1:0]  ts_sel;

  assign isr_q  = isr;
  wire [15:0] live_hw;
  assign evt_now = {2'h0, trig_mask[13:0]} | live_hw;

  wire [15:0] dl_sel = ts_sel == 2'd0 ? dl0 : ts_sel == 2'd1 ? dl1 :
                       ts_sel == 2'd2 ? dl2 : dl3;
  wire [8:0]  pc_sel = ts_sel == 2'd0 ? pc0 : ts_sel == 2'd1 ? pc1 :
                       ts_sel == 2'd2 ? pc2 : pc3;
  wire [5:0]  sp_sel = ts_sel == 2'd0 ? sp0 : ts_sel == 2'd1 ? sp1 :
                       ts_sel == 2'd2 ? sp2 : sp3;
  wire [15:0] x_sel  = ts_sel == 2'd0 ? x0  : ts_sel == 2'd1 ? x1  :
                       ts_sel == 2'd2 ? x2  : x3;

  wire [23:0] sub_dt = dl_sel - time_q;      // D - T modular
  wire [15:0] tsub16 = sub_dt[15:0];

  // write-1-clear mask for ISR (from thread CSR write)
  wire [15:0] wclr = (we && (addr == `CSR_ISR)) ? wdata : 16'h0000;

  // ------------------------------------------------------------------ read
  always @(*) begin
    rdata = 16'h0000;
    case (addr)
      `CSR_OSRL:  rdata = {8'h00, goe_q};
      `CSR_OSRH:  rdata = {8'h00, gout_q};
      `CSR_TMR:   rdata = time_q[15:0];
      `CSR_TMRH:  rdata = {8'h00, time_q[23:16]};
      `CSR_ISR:   rdata = isr;
      `CSR_IOM:   rdata = {8'h00, own_in};
      `CSR_OWM:   rdata = {8'h00, own_oe};
      `CSR_FSTAT: rdata = {tr_full, tr_empty, rx_full, rx_empty,
                           tx_full, tx_empty, crc_busy, 1'b0,
                           8'h00};
      `CSR_FDATA: rdata = {8'h00, rx_rdata};
      `CSR_EDV:   rdata = {12'h0, edg_valid};
      `CSR_TSUB:  rdata = (dl_sel > time_q) ? tsub16 : 16'h0;
      `CSR_DEADL: rdata = dl_sel[15:0];
      `CSR_DEADH: rdata = {8'h00, dl_sel[23:16]};
      `CSR_FLAGS: rdata = {8'h00, waiting_vec[ts_sel], running_vec[ts_sel],
                           1'b0, 1'b0, 1'b0, 1'b0, sel_dbg};
      `CSR_STACK: rdata = {10'h0, sp_sel};
      `CSR_STAT:  rdata = {8'h00, err_sticky_vec, running_vec};
      `CSR_PC0:   rdata = {7'h0, pc_sel};
      `CSR_ERRCNT:rdata = {10'h0, errcnt};
      `CSR_TRCHI: rdata = {12'h0, tr_head[35:24]};
      `CSR_TRCLO: rdata = tr_head[15:0];
      default:    rdata = 16'h0000;
    endcase
  end

  // ------------------------------------------------------------------ write
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      isr <= 16'h0; trig_mask <= 16'h0;
      crc_pl <= 16'h0; crc_ph <= 16'h0; crc_ol <= 16'h0; crc_oh <= 16'h0;
      crc_ls <= 5'd16; crc_seed <= 16'h0; crc_seed_load <= 1'b0;
      gpo_we <= 1'b0; gpo_wr <= 8'h0; goe_we <= 1'b0; goe_wr <= 8'h0;
      errcnt <= 6'd0; ts_sel <= 2'd0; sel_dbg <= 1'b0;
      clr_trace <= 1'b0; trace_en <= 1'b0; tr_pop <= 1'b0;
      owm_we <= 1'b0; owm_tgt <= 2'd0; owm_data <= 8'h0;
      err_clr <= 4'h0;
      dclr_we <= 1'b0; dclr_sel <= 2'd0; dclr_val <= {`JP_TIME_W{1'b0}};
      start_pulse <= 1'b0; start_tid <= 2'd0;
      be_cfg_we <= 1'b0; be_cfg_addr <= 4'h0; be_cfg_wdata <= 16'h0;
      idle_mask0 <= 16'h0; idle_mask1 <= 16'h0;
      idle_mask2 <= 16'h0; idle_mask3 <= 16'h0;
    end else begin
      // defaults: single-cycle pulses self-clear
      clr_trace <= 1'b0; tr_pop <= 1'b0; owm_we <= 1'b0; err_clr <= 4'h0;
      dclr_we <= 1'b0; start_pulse <= 1'b0;
      be_cfg_we <= 1'b0;
      crc_seed_load <= 1'b0; gpo_we <= 1'b0; goe_we <= 1'b0;

      // hardware event accumulation (sticky until w1c) + SW trigger
      isr <= (isr | live_hw | (ext_trg_we ? {12'h000, ext_trg_bits} : 16'h0)) & ~wclr;
      if (ext_idle_we) begin
        case (ext_idle_tid)
          2'd0: idle_mask0 <= ext_idle_mask;
          2'd1: idle_mask1 <= ext_idle_mask;
          2'd2: idle_mask2 <= ext_idle_mask;
          default: idle_mask3 <= ext_idle_mask;
        endcase
      end

      if (we) begin
        case (addr)
          `CSR_ISR: ;  // handled via wclr below
          `CSR_IOM:  begin owm_we <= 1'b1; owm_tgt <= 2'd0;
                           owm_data <= wdata[7:0]; end
          `CSR_OWM:  begin owm_we <= 1'b1; owm_tgt <= 2'd1;
                           owm_data <= wdata[7:0]; end
          `CSR_TMASK: trig_mask <= wdata;
          `CSR_CRCPL: crc_pl <= wdata;
          `CSR_CRCPH: crc_ph <= wdata;
          `CSR_CRCOX: crc_ol <= wdata;
          `CSR_CRCOXH: crc_oh <= wdata;
          `CSR_CRCLS: crc_ls <= wdata[4:0];
          `CSR_CRCSEEDL: begin crc_seed[7:0]  <= wdata[7:0];
                               crc_seed_load <= 1'b1; end
          `CSR_CRCSEEDH: begin crc_seed[15:8] <= wdata[7:0];
                               crc_seed_load <= 1'b1; end
          `CSR_GPOUT: begin gpo_we <= 1'b1; gpo_wr <= wdata[7:0]; end
          `CSR_GPOEN: begin goe_we <= 1'b1; goe_wr <= wdata[7:0]; end
          `CSR_BITCFG: begin be_cfg_we <= 1'b1; be_cfg_addr <= 4'd0;
                             be_cfg_wdata <= wdata; end
          `CSR_BITDIV: begin be_cfg_we <= 1'b1;
                             be_cfg_addr <= wdata[8] ? 4'd2 : 4'd1;
                             be_cfg_wdata <= wdata; end
          `CSR_BITGO:  begin be_cfg_we <= 1'b1; be_cfg_addr <= 4'd7;
                             be_cfg_wdata <= wdata; end
          `CSR_TSSEL:  ts_sel <= wdata[1:0];
          `CSR_THCTRL: begin
            // wdata: [1:0]=tid, [2]=start, [3]=halt(set run off), [4]=clr_deadline,
            //        [5]=reset deadline to time_q
            dclr_sel <= wdata[1:0];
            if (wdata[4]) begin dclr_we <= 1'b1; dclr_val <= {`JP_TIME_W{1'b0}}; end
            if (wdata[5]) begin dclr_we <= 1'b1; dclr_val <= time_q; end
            if (wdata[2]) begin start_pulse <= 1'b1; start_tid <= wdata[1:0]; end
          end
          `CSR_TRCTRL: begin
            trace_en <= wdata[0];
            if (wdata[1]) clr_trace <= 1'b1;
            if (wdata[2]) tr_pop   <= 1'b1;
          end
          `CSR_ERRCNT: errcnt <= 6'd0;           // reset error counter
          default: ;
        endcase
      end
    end
  end

  // hardware-only live events
  assign live_hw = {11'h0000,
                    edg_fired,          // [5] edge unit fired
                    ~tr_empty,          // [4] trace data available
                    ~tx_full,           // [3] tx fifo has space
                    ~rx_empty,          // [2] rx fifo has data
                    drv_err_pulse};     // [1] drive violation

endmodule
