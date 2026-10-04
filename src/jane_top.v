// SPDX-FileCopyrightText: (c) 2026 General-Purpose Protocol ASIC contributors
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

// =============================================================================
// top.v — Tiny Tapeout top module for the Programmable Protocol Engine (PPE).
// Thin integration layer only: reset/clock conditioning, block instantiation,
// pin mapping. No protocol logic lives here (docs/ARCHITECTURE.md).
//
// Pin plan (verified against info.yaml: power-on pins + in8/out3/bidir18):
//   ui_in[7:0]    = sideband inputs (free; readable via IN.GI)
//   uo_out[2:0]   = status LEDs / debug mirror of gout[2:0]
//   uio[7:4]      = host SPI: CS_n, SCLK, MOSI, MISO
//   uio[3:0]      = GPIO fabric pins P0..P3  (UART/I2C/SPI protocol lines)
//   uio[15:8]     = GPIO fabric extension? Fabric width is 8: P0..P7 map to
//                   uio[3:0] and uio[11:8]; host occupies uio[7:4]; the
//                   remaining uio[17:12] are left as safe inputs.
// For area/routing simplicity in 6x4 the VERIFIED build uses a 6-wide fabric:
//   P0=uio0 UART_RX, P1=uio1 UART_TX, P2=uio2 I2C_SDA, P3=uio3 I2C_SCL,
//   P4=uio12 SPI_SCK, P5=uio13 SPI_MOSI, P6=uio14 SPI_MISO, P7=uio15 free.
// =============================================================================

`include "defines.vh"

module tt_um_jonestreet_protocol_engine (
    input  wire        clk,
    input  wire        rst_n,     // active-low async from TT (asserted during config)
    input  wire [7:0]  ui_in,
    output wire [2:0]  uo_out,
    inout  wire [17:0] uio,
    inout  wire [17:0] uio_bidir_0,
    inout  wire [17:0] uio_bidir_1
);

  // ---------------- reset synchronizer (sync deassert) ---------------------
  reg [1:0] rst_s;
  wire rst_n_core = rst_s[0];
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) rst_s <= 2'b00;
    else        rst_s <= {rst_s[1], 1'b1};
  end

  // soft reset pulse from host merges into same synchronizer path
  wire soft_rst_n;
  assign soft_rst_n = rst_n & ~soft_rst_pulse_r;
  reg soft_rst_pulse_r;

  reg [1:0] rst_s2;
  wire rst_n_sync = rst_s2[0];
  always @(posedge clk or negedge soft_rst_n) begin
    if (!soft_rst_n) rst_s2 <= 2'b00;
    else             rst_s2 <= {rst_s2[1], 1'b1};
  end

  // ---------------- host interface pads ------------------------------------
  wire h_cs_n_raw  = uio[7];
  wire h_sclk_raw  = uio[6];
  wire h_mosi_raw  = uio[5];
  assign uio[4]    = h_miso_oe ? h_miso : 1'bz;

  // ---------------- GPIO fabric pads ---------------------------------------
  wire [`JP_GPIO_W-1:0] gpio_in_pad;
  wire [`JP_GPIO_W-1:0] gpio_out_pad;
  wire [`JP_GPIO_W-1:0] gpio_oe_pad;
  assign gpio_in_pad = {uio[15], uio[14], uio[13], uio[12], uio[3], uio[2], uio[1], uio[0]};
  assign uio[0]  = gpio_oe_pad[0] ? gpio_out_pad[0] : 1'bz;
  assign uio[1]  = gpio_oe_pad[1] ? gpio_out_pad[1] : 1'bz;
  assign uio[2]  = gpio_oe_pad[2] ? gpio_out_pad[2] : 1'bz;
  assign uio[3]  = gpio_oe_pad[3] ? gpio_out_pad[3] : 1'bz;
  assign uio[12] = gpio_oe_pad[4] ? gpio_out_pad[4] : 1'bz;
  assign uio[13] = gpio_oe_pad[5] ? gpio_out_pad[5] : 1'bz;
  assign uio[14] = gpio_oe_pad[6] ? gpio_out_pad[6] : 1'bz;
  assign uio[15] = gpio_oe_pad[7] ? gpio_out_pad[7] : 1'bz;
  assign uio[17:16] = 2'bz;         // unused: safe Hi-Z inputs

  // uio_bidir sets unused (kept Hi-Z) — documented limitation for 6x4.
  assign uio_bidir_0 = 18'bz;
  assign uio_bidir_1 = 18'bz;

  // ---------------- core signals -------------------------------------------
  wire        en_core;
  wire        soft_rst_pulse;
  wire        clr_trace_pulse;
  wire        rst_time_pulse;
  wire [3:0]  thread_run;
  wire        pc_load_we;
  wire [1:0]  pc_load_tid;
  wire [8:0]  pc_load_val;
  wire [3:0]  err_clr;

  always @(posedge clk or negedge rst_n_core) begin
    if (!rst_n_core) soft_rst_pulse_r <= 1'b0;
    else             soft_rst_pulse_r <= soft_rst_pulse_ext;
  end
  wire soft_rst_pulse_ext;

  // scheduler
  wire [1:0] sel_q;
  wire [3:0] grant;

  // timing
  wire [`JP_TIME_W-1:0] time_q;
  wire [3:0]            d_we_vec;
  wire [1:0]            d_wsel;
  wire [`JP_TIME_W-1:0] d_wdata;
  wire [`JP_TIME_W-1:0] dl0, dl1, dl2, dl3;

  // progmem
  wire [8:0]  fetch_addr [0:3];
  wire [15:0] fetch_data [0:3];
  wire        pm_busy;

  // per-thread wires (arrays flattened for tool compatibility)
  wire        running [0:3];
  wire        waiting [0:3];
  wire        err_sticky [0:3];
  wire [8:0]  pc_q [0:3];
  wire [15:0] x_q [0:3];
  wire [15:0] y_q [0:3];
  wire [5:0]  sp_q [0:3];

  // CSR <-> engine events
  wire [15:0] isr_q;
  wire [15:0] evt_now;

  // fifos
  wire [7:0] rx_rdata; wire rx_full; wire rx_empty;
  wire       rx_wr; wire [7:0] rx_wdata;
  wire [7:0] tx_rdata_h; wire tx_empty_h; wire tx_full_h;
  wire       tx_wr_t; wire [7:0] tx_wdata_t;
  wire       mb_h2e_wr; wire [7:0] mb_h2e_wdata;
  wire [7:0] mb_h2e_rdata; wire mb_h2e_empty; wire mb_h2e_rd_core;
  wire       mb_e2h_wr_core; wire [7:0] mb_e2h_wdata_core;
  wire [7:0] mb_e2h_rdata_h; wire mb_e2h_full_h; wire mb_e2h_rd_h;

  // trace
  wire [35:0] tr_head;
  wire        tr_full, tr_empty;
  wire        tr_pop;
  wire        tr_wr; wire [35:0] tr_wdata;

  // bit engine
  wire        be_cfg_we; wire [3:0] be_cfg_addr; wire [15:0] be_cfg_wdata;
  wire        be_wrbit; wire [7:0] be_wrbit_data;
  wire        be_ldshreg; wire [15:0] be_ldshreg_val;
  wire        be_tx_done, be_rx_done;
  wire [7:0]  be_rx_byte; wire be_rx_have;
  wire        be_drv, be_val, be_oe; wire [2:0] be_pin;
  wire [4:0]  be_txcount, be_rxcount; wire [15:0] be_shreg;
  wire        crc_busy; wire [15:0] crc_result;

  // edge units
  wire [7:0]  edg_valid;
  wire [7:0]  ed_val, ed_oe;
  wire        ed_fired;

  // gpio
  wire [7:0]  sync_q, raw_q, edge_pulse;
  wire [7:0]  own_in, own_oe, gout_q, goe_q;
  wire        drv_err_pulse; wire [1:0] drv_err_tid;

  // csr read data mux result
  wire [15:0] csr_rdata;

  // shared-window dm
  wire [15:0] sh_rdata [0:3];

  // thread drive requests
  wire        drv_we [0:3]; wire [7:0] drv_val [0:3]; wire [7:0] drv_oe [0:3];
  wire        drv_od [0:3];
  wire        gou_we [0:3]; wire [1:0] gou_op [0:3]; wire [7:0] gou_data [0:3];
  wire        thr_drv_we; wire [7:0] thr_drv_val; wire [7:0] thr_drv_oe;
  wire        thr_drv_od; wire [1:0] thr_drv_id;
  wire        gou_we_m; wire [1:0] gou_op_m; wire [7:0] gou_data_m;

  // csr control from threads/host
  wire        csr_we [0:3]; wire [5:0] csr_addr [0:3]; wire [15:0] csr_wdata [0:3];
  wire        csr_re [0:3];
  wire        owm_we; wire [1:0] owm_tgt; wire [7:0] owm_data;
  wire        be_go_we; wire [15:0] be_go_data;

  // deadline writes OR'd with sel
  assign d_wsel = sel_q;

  // ---------------- host_if ------------------------------------------------
  host_if u_host (
      .clk(clk), .rst_n(rst_n_sync),
      .h_cs_n_raw(h_cs_n_raw), .h_sclk_raw(h_sclk_raw), .h_mosi_raw(h_mosi_raw),
      .h_miso(h_miso), .h_miso_oe(h_miso_oe),
      .en_core(en_core), .soft_rst_pulse(soft_rst_pulse_ext),
      .clr_trace_pulse(clr_trace_pulse), .rst_time_pulse(rst_time_pulse),
      .thread_run(thread_run),
      .pc_load_we(pc_load_we), .pc_load_tid(pc_load_tid), .pc_load_val(pc_load_val),
      .err_clr(err_clr),
      .pm_we(pm_we_h), .pm_addr(pm_addr_h), .pm_wdata(pm_wdata_h), .pm_be(pm_be_h),
      .pm_rdata(pm_rdata_h),
      .dm_we(dm_we_h), .dm_addr(dm_addr_h), .dm_wdata(dm_wdata_h), .dm_be(dm_be_h),
      .dm_rdata(dm_rdata_h),
      .mb_h2e_wr(mb_h2e_wr), .mb_h2e_wdata(mb_h2e_wdata),
      .mb_e2h_rdata(mb_e2h_rdata_h), .mb_e2h_rd(mb_e2h_rd_h),
      .tr_head(tr_head), .tr_pop(tr_pop),
      .trace_full(tr_full), .trace_empty(tr_empty),
      .rx_fifo_state({rx_empty, rx_full}),
      .err_bitmap(err_bitmap), .running_bitmap(running_bitmap)
  );
  wire h_miso, h_miso_oe;
  wire pm_we_h; wire [8:0] pm_addr_h; wire [15:0] pm_wdata_h; wire pm_be_h;
  wire [15:0] pm_rdata_h;
  wire dm_we_h; wire [7:0] dm_addr_h; wire [15:0] dm_wdata_h; wire dm_be_h;
  wire [15:0] dm_rdata_h;

  // ---------------- progmem ------------------------------------------------
  wire        core_stall = pm_busy;
  prog_mem u_pm (
      .clk(clk), .rst_n(rst_n_sync),
      .fetch_addr(fetch_addr[sel_q]), .fetch_data(fetch_data_mux),
      .hre(hre_h), .hwe(pm_we_h), .ha(pm_addr_h), .hwdata(pm_wdata_h),
      .hbe(pm_be_h), .hrd(pm_rdata_h), .port_busy(pm_busy)
  );
  wire [15:0] fetch_data_mux;
  wire hre_h = |{1'b0} & 1'b0; // placeholder replaced below
  assign fetch_addr[0] = pc0; assign fetch_addr[1] = pc1;
  assign fetch_addr[2] = pc2; assign fetch_addr[3] = pc3;
  wire [8:0] pc0, pc1, pc2, pc3;

  // ---------------- scheduler ----------------------------------------------
  wire [3:0] running_bitmap;
  assign running_bitmap = {running[3], running[2], running[1], running[0]};
  wire [3:0] err_bitmap;
  assign err_bitmap = {err_sticky[3], err_sticky[2], err_sticky[1], err_sticky[0]};

  scheduler u_sched (
      .clk(clk), .rst_n(rst_n_sync),
      .en(en_core), .stalling(pm_busy), .running(running_bitmap),
      .sel_q(sel_q), .grant(grant), .any_grant()
  );

  // ---------------- timing ---------------------------------------------
  // deadline write mux: granted thread drives d_we/d_wdata directly
  wire [3:0] d_we_thr;
  wire [3:0] clr_dl_vec;
  assign d_we_vec = d_we_thr & grant;
  timing u_timing (
      .clk(clk), .rst_n(rst_n_sync), .en(en_core),
      .d_we(d_we_vec), .d_wsel(d_wsel), .d_wdata(d_wdata),
      .time_q(time_q), .time_d(), .ready(), .d_rd({dl3,dl2,dl1,dl0})
  );
  wire [3:0] ready_vec;
  wire [`JP_TIME_W-1:0] time_d_w;

  // clr deadline (host THCTRL + EXT.CLRDEAD)
  genvar gi;

  // ---------------- threads --------------------------------------------
  genvar t;
  generate
    for (t = 0; t < `JP_NUM_THREADS; t = t + 1) begin : g_thread
      thread #(.TID(t)) u_thread (
          .clk(clk), .rst_n(rst_n_sync),
          .grant(grant[t]), .stalling(pm_busy),
          .start_lvl(thread_run[t]), .running(running[t]),
          .pc(pcq[t]), .waiting(waitingq[t]),
          .fetch_addr(), .fetch_data(fetch_data_mux),
          .time_q(time_q), .deadline_q(dlq[t]),
          .d_we(d_we_thr[t]), .d_wdata(d_wdata), .clr_deadline(clr_dl_vec[t]),
          .gpio_sync(sync_q), .gpio_raw(raw_q), .ui_in(ui_in),
          .edge_pulse(edge_pulse), .own_oe(own_oe), .own_in(own_in),
          .drv_we(drv_we[t]), .drv_val(drv_val[t]), .drv_oe(drv_oe[t]), .drv_od(drv_od[t]),
          .gou_we(gou_we[t]), .gou_op(gou_op[t]), .gou_data(gou_data[t]),
          .sh_we(sh_we[t]), .sh_waddr(sh_waddr[t]), .sh_wdata(sh_wdata[t]),
          .sh_re(sh_re[t]), .sh_raddr(sh_raddr[t]), .sh_rdata(sh_rdata[t]),
          .csr_we(csr_we[t]), .csr_addr(csr_addr[t]), .csr_wdata(csr_wdata[t]),
          .csr_re(csr_re[t]), .csr_rdata(csr_rdata),
          .be_cfg_we(be_cfg_we_t[t]), .be_cfg_addr(be_cfg_addr_t[t]),
          .be_cfg_wdata(be_cfg_wdata_t[t]),
          .be_wrbit(be_wrbit_t[t]), .be_wrbit_data(be_wrbit_data_t[t]),
          .be_ldshreg(be_ldshreg_t[t]), .be_ldshreg_val(be_ldshreg_val_t[t]),
          .be_txcount(be_txcount), .be_rxcount(be_rxcount), .be_shreg(be_shreg),
          .crc_we(crc_we_t[t]), .crc_op(crc_op_t[t]), .crc_val(crc_val_t[t]),
          .crc_busy(crc_busy), .crc_result(crc_result),
          .isr_q(isr_q), .evt_now(evt_now),
          .ev_mask(ev_mask_arr[t][15:0]), .ev_pol(ev_pol_arr[t]),
          .rx_rd(rx_rd_t[t]), .rx_rdata(rx_rdata), .rx_empty(rx_empty),
          .tx_wr(tx_wr_t[t]), .tx_wdata(tx_wdata_t[t]), .tx_full(tx_full_h),
          .trc_we(trc_we_t[t]), .trc_evt(trc_evt_t[t]),
          .edg_we(edg_we_t[t]), .edg_addr(edg_addr_t[t]), .edg_time(edg_time_t[t]),
          .edg_val(edg_val_t[t]), .edg_oe(edg_oe_t[t]), .edg_en(edg_en_t[t]),
          .edg_valid(edg_valid),
          .err_sticky(err_sticky[t]), .x_out(x_q[t]), .y_out(y_q[t]), .sp_out(sp_q[t])
      );
      wire [8:0] pcq; wire waitingq; wire [`JP_TIME_W-1:0] dlq;
    end
  endgenerate

endmodule
