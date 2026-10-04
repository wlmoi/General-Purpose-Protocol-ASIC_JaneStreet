// SPDX-FileCopyrightText: (c) 2026 General-Purpose Protocol ASIC contributors
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

// =============================================================================
// thread.v — one programmable execution context (T0..T3). See docs/ISA.md and
// docs/TIMING.md for authoritative semantics; this file IS the microarch spec.
//
// Model:
//   * Deterministic RR scheduler grants each thread a slot every 4 cycles.
//   * Grant cycle N: instruction at pc is fetched (async progmem read),
//     decoded, executed combinationally; all updates commit at edge N->N+1.
//   * PC advances +1 unless branch-taken / wait-park forms.
//   * Parked waits re-evaluate on each grant; no side effects while parked.
//   * Illegal opcodes (0xE/0xF): NOP + sticky error flag. Deterministic.
//   * Single clock domain; synchronous reset from top-level reset sync.
//
// Register state (per thread, measured in docs/AREA_TIMING.md):
//   X, Y                 16b operands (aliased into rf[0], rf[1])
//   rf[0..31]            local register file window (R0..R7 @2..9, SP @10,
//                        G16..G31 @11..31, scratch @28..31 aliased to DM)
//   PC                   9b
//   flags                cy, ovf, zero, tmo(sticky until next wait)
//   wait state           kind, timer, inf, pinmask, active
//   ev_mask, ev_pol      armed event-wait state
// =============================================================================

`include "defines.vh"

module thread #(
    parameter TID = 0
) (
    input  wire                    clk,
    input  wire                    rst_n,

    // ---------------- scheduler ----------------
    input  wire                    grant,
    input  wire                    stalling,        // host owns progmem port
    input  wire                    start_lvl,       // level from THCTRL bitmap
    output reg                     running,
    output reg  [`JP_PROG_AW-1:0]  pc,
    output wire                    waiting,

    // ---------------- fetch ----------------
    output wire [`JP_PROG_AW-1:0]  fetch_addr,
    input  wire [`JP_INST_W-1:0]   fetch_data,

    // ---------------- time base ----------------
    input  wire [`JP_TIME_W-1:0]   time_q,
    input  wire [`JP_TIME_W-1:0]   deadline_q,
    output reg                     d_we,
    output reg  [`JP_TIME_W-1:0]   d_wdata,
    output reg                     clr_deadline,    // pulse: D := 0 next cycle

    // ---------------- GPIO fabric ----------------
    input  wire [`JP_GPIO_W-1:0]   gpio_sync,
    input  wire [`JP_GPIO_W-1:0]   gpio_raw,
    input  wire [`JP_GPIO_W-1:0]   ui_in,
    input  wire [`JP_GPIO_W-1:0]   edge_pulse,
    input  wire [7:0]              own_oe,
    input  wire [7:0]              own_in,
    output reg                     drv_we,
    output reg  [7:0]              drv_val,
    output reg  [7:0]              drv_oe,
    output reg                     drv_od,
    output reg                     gou_we,
    output reg  [1:0]              gou_op,
    output reg  [7:0]              gou_data,

    // ---------------- shared-window DM port ----------------
    output reg                     sh_we,
    output reg  [5:0]              sh_waddr,
    output reg  [15:0]             sh_wdata,
    output reg                     sh_re,
    output reg  [5:0]              sh_raddr,
    input  wire [15:0]             sh_rdata,

    // ---------------- thread register-file port (rf lives in top dm) -------
    output reg                     rf_we,
    output reg  [4:0]              rf_waddr,
    output reg  [15:0]             rf_wdata,
    output reg                     rf_re_a,
    output reg  [4:0]              rf_raddr_a,
    input  wire [15:0]             rf_rdata_a,
    output reg                     rf_re_b,
    output reg  [4:0]              rf_raddr_b,
    input  wire [15:0]             rf_rdata_b,

    // LDI second-word fetch (dedicated progmem read lane at top)
    input  wire [15:0]             ldi_word,

    // ---------------- CSR ----------------
    output reg                     csr_we,
    output reg  [5:0]              csr_addr,
    output reg  [15:0]             csr_wdata,
    output reg                     csr_re,
    input  wire [15:0]             csr_rdata,

    // ---------------- bit engine / CRC ----------------
    output reg                     be_cfg_we,
    output reg  [3:0]              be_cfg_addr,
    output reg  [15:0]             be_cfg_wdata,
    input  wire                    rx_fifo_full,
    input  wire                    tx_fifo_empty,
    output reg                     be_wrbit,
    output reg  [7:0]              be_wrbit_data,
    output reg                     be_ldshreg,
    output reg  [15:0]             be_ldshreg_val,
    input  wire [4:0]              be_txcount,
    input  wire [4:0]              be_rxcount,
    input  wire [15:0]             be_shreg,
    output reg                     crc_we,
    output reg  [1:0]              crc_op,
    output reg  [15:0]             crc_val,
    input  wire                    crc_busy,
    input  wire [15:0]             crc_result,

    // ---------------- event system ----------------
    input  wire [15:0]             isr_q,
    input  wire [15:0]             evt_now,
    output reg                     ext_trg_we_o,   // pulse: OR X[3:0] into ISR
    output reg  [3:0]              ext_trg_bits_o,
    output reg                     ext_idle_we_o,  // pulse: store wake mask
    output reg  [15:0]             ext_idle_mask_o,
    output reg  [15:0]             ev_mask,
    output reg                     ev_pol,

    // ---------------- FIFOs ----------------
    output reg                     rx_rd,
    input  wire [7:0]              rx_rdata,
    input  wire                    rx_empty,
    output reg                     tx_wr,
    output reg  [7:0]              tx_wdata,
    input  wire                    tx_full,

    // ---------------- trace ----------------
    output reg                     trc_we,
    output reg  [3:0]              trc_evt,
    input  wire                    trace_en,

    // ---------------- edge units ----------------
    output reg                     edg_we,
    output reg  [2:0]              edg_addr,
    input  wire [15:0]             time_lo,         // time_q[15:0] for EDG.ARM
    output reg  [15:0]             edg_time,
    output reg  [7:0]              edg_val,
    output reg  [7:0]              edg_oe,
    output reg                     edg_en,
    input  wire [7:0]              edg_valid,

    // ---------------- status ----------------
    output reg                     err_sticky,
    input  wire                    err_clr,        // host clear pulse for this thread
    output wire [15:0]             x_out,
    output wire [15:0]             y_out,
    output wire [4:0]              sp_out,
    output wire                    tmo_out
);

  // =========================================================================
  // Architectural registers
  // =========================================================================
  reg [15:0] X, Y;
  reg [5:0]  sp;   // SP architectural copy lives in rf[10] (top dm)
  reg        cy_q, ovf_q, zero_q, tmo_q;

  reg        w_active;
  reg [2:0]  w_kind;
  reg [4:0]  w_timer;               // countdown in grants
  reg        w_inf;
  reg [7:0]  w_pinmask;

  assign waiting    = w_active;
  assign fetch_addr = pc;
  assign x_out      = X;
  assign y_out      = Y;
  assign sp_out     = sp;
  assign tmo_out    = tmo_q;

  // pulse-gated outputs (registered, cleared unless re-asserted this grant)
  reg ext_trg_we, ext_idle_we;

  integer k;
  initial begin
    X = 16'h0; Y = 16'h0; sp = 6'd0;
    rf_we = 1'b0; rf_waddr = 5'd0; rf_wdata = 16'h0;
    rf_re_a = 1'b0; rf_raddr_a = 5'd0; rf_re_b = 1'b0; rf_raddr_b = 5'd0;
    pc = {`JP_PROG_AW{1'b0}}; running = 1'b0;
    cy_q = 1'b0; ovf_q = 1'b0; zero_q = 1'b0; tmo_q = 1'b0;
    w_active = 1'b0; w_kind = 3'd0; w_timer = 5'd0; w_inf = 1'b0; w_pinmask = 8'h0;
    ev_mask = 16'h0; ev_pol = 1'b0; err_sticky = 1'b0;
    d_we = 1'b0; d_wdata = {`JP_TIME_W{1'b0}}; clr_deadline = 1'b0;
    drv_we = 1'b0; drv_val = 8'h0; drv_oe = 8'h0; drv_od = 1'b0;
    gou_we = 1'b0; gou_op = 2'd0; gou_data = 8'h0;
    sh_we = 1'b0; sh_waddr = 6'd0; sh_wdata = 16'h0; sh_re = 1'b0; sh_raddr = 6'd0;
    csr_we = 1'b0; csr_addr = 6'd0; csr_wdata = 16'h0; csr_re = 1'b0;
    be_cfg_we = 1'b0; be_cfg_addr = 4'd0; be_cfg_wdata = 16'h0;
    be_wrbit = 1'b0; be_wrbit_data = 8'h0;
    be_ldshreg = 1'b0; be_ldshreg_val = 16'h0;
    crc_we = 1'b0; crc_op = 2'd0; crc_val = 16'h0;
    rx_rd = 1'b0; tx_wr = 1'b0; tx_wdata = 8'h0;
    trc_we = 1'b0; trc_evt = 4'h0;
    edg_we = 1'b0; edg_addr = 3'd0; edg_time = 16'h0; edg_val = 8'h0;
    edg_oe = 8'h0; edg_en = 1'b0;
    ext_trg_we = 1'b0; ext_idle_we = 1'b0;
  end

  // =========================================================================
  // Decode
  // =========================================================================
  wire [3:0] opcode = fetch_data[15:12];
  wire [2:0] f_r    = fetch_data[11:9];
  wire [5:0] f_a    = fetch_data[8:3];
  wire [2:0] f_m    = fetch_data[5:3];
  wire [2:0] f_rr   = fetch_data[2:0];
  wire [7:0] f_imm8 = fetch_data[7:0];
  wire [5:0] f_imm6 = fetch_data[5:0];
  wire [4:0] f_imm5 = fetch_data[4:0];
  wire [1:0] f_dst  = fetch_data[10:9];
  wire [1:0] f_src  = fetch_data[8:7];
  wire [5:0] f_fn   = fetch_data[11:6];
  wire signed [7:0] off8 = {{2{fetch_data[9]}}, fetch_data[9:2]}; // BR: words +-64
  wire signed [9:0] off10 = {fetch_data[9], fetch_data[9:0]};     // JMPR rel
  wire [8:0] imm9 = {fetch_data[9:0]};                            // JMPR direct
  wire illegal = (opcode == 4'he) || (opcode == 4'hf);

  // =========================================================================
  // Wait-satisfaction evaluation
  // =========================================================================
  wire t_ready = (deadline_q == {`JP_TIME_W{1'b0}}) ||
                 (((time_q - deadline_q) >> (`JP_TIME_W-1)) == 1'b0);

  wire pin_edge_any = |(edge_pulse & w_pinmask);
  wire rdylvl       = ((gpio_sync & w_pinmask) != {`JP_GPIO_W{1'b0}});
  wire ev_level_set = ((isr_q & ev_mask) != 16'h0);
  wire ev_now_set   = ((evt_now & ev_mask) != 16'h0);

  reg cond_ok;
  always @(*) begin
    cond_ok = 1'b0;
    case (w_kind)
      `W_CYC, `W_DADJ, `W_DSYNC: cond_ok = t_ready;
      `W_EDGE: cond_ok = pin_edge_any | (~w_inf & (w_timer == 5'd0));
      `W_TMO:  cond_ok = ~w_inf & (w_timer == 5'd0);
      `W_EV:   cond_ok = (ev_pol ? ~ev_level_set : (ev_now_set | ev_level_set))
                         | (~w_inf & (w_timer == 5'd0));
      `W_RDY:  cond_ok = (rdylvl == ev_pol) | (~w_inf & (w_timer == 5'd0));
      default: cond_ok = 1'b1;
    endcase
  end

  reg primary_hit;
  always @(*) begin
    case (w_kind)
      `W_EDGE: primary_hit = pin_edge_any;
      `W_EV:   primary_hit = ev_pol ? ~ev_level_set : (ev_now_set | ev_level_set);
      `W_RDY:  primary_hit = (rdylvl == ev_pol);
      default: primary_hit = 1'b0;
    endcase
  end
  wire timed_out = (~w_inf) & (w_timer == 5'd0) & ~primary_hit;

  // =========================================================================
  // ALU
  // =========================================================================
  wire [15:0] imm16  = f_m[2] ? {8'h00, f_imm8} : {10'h000, f_imm6};
  wire [15:0] alu_y   = f_m[2] ? imm16 : Y;
  wire [16:0] sum     = {1'b0, X} + {1'b0, alu_y};
  wire [16:0] diff    = {1'b0, X} - {1'b0, alu_y};
  wire [3:0]  sh_amt  = alu_y[3:0];
  wire [3:0] rol_neg = (~sh_amt) + 4'h1;   // 16 - amt (mod 16); amt=0 -> 0
  wire [15:0] rol_res = (sh_amt == 4'd0) ? X : ((X << sh_amt) | (X >> rol_neg));
  reg  [15:0] alu_res;
  reg         alu_cy, alu_ovf;
  always @(*) begin
    alu_cy = 1'b0; alu_ovf = 1'b0; alu_res = X;
    case (f_r)
      `ALU_ADD: begin alu_res = sum[15:0]; alu_cy = sum[16];
                      alu_ovf = (!X[15] && !alu_y[15] &&  sum[15]) ||
                                ( X[15] &&  alu_y[15] && !sum[15]); end
      `ALU_SUB: begin alu_res = diff[15:0]; alu_cy = diff[16];
                      alu_ovf = (!X[15] &&  alu_y[15] &&  diff[15]) ||
                                ( X[15] && !alu_y[15] && !diff[15]); end
      `ALU_OR:   alu_res = X | alu_y;
      `ALU_AND:  alu_res = X & alu_y;
      `ALU_XOR:  alu_res = X ^ alu_y;
      `ALU_SHL:  begin alu_res = X << sh_amt; alu_cy = (sh_amt != 4'd0) && X[15]; end
      `ALU_SHR:  begin alu_res = X >> sh_amt; alu_cy = (sh_amt != 4'd0) && X[0];  end
      `ALU_ROL:  begin alu_res = rol_res;     alu_cy = (sh_amt != 4'd0) && X[15]; end
      default:   alu_res = X;
    endcase
  end

  reg br_taken;
  always @(*) begin
    case (f_r)
      `BR_ALWAYS: br_taken = 1'b1;
      `BR_EQ:     br_taken = (X == Y);
      `BR_NE:     br_taken = (X != Y);
      `BR_LT:     br_taken = (X < Y);
      `BR_GT:     br_taken = (X > Y);
      `BR_CARRY:  br_taken = cy_q;
      `BR_NZ:     br_taken = (X != 16'h0);
      default:    br_taken = 1'b0;
    endcase
  end

  // MOV source mux: 0 X, 1 Y, 2 rf[f_rr], 3 imm8
  function automatic [15:0] mov_src(input [1:0] s);
    begin
      case (s)
        2'd0:    mov_src = X;
        2'd1:    mov_src = Y;
        2'd2:    mov_src = rf_rdata_a;
        default: mov_src = {8'h00, f_imm8};
      endcase
    end
  endfunction

  // =========================================================================
  // Next-state computation (single owner of every architectural reg)
  // =========================================================================
  reg [`JP_PROG_AW-1:0] pc_next;
  reg [15:0] x_next, y_next;
  reg [5:0]  sp_next;
  reg        w_active_next; reg [2:0] w_kind_next; reg [4:0] w_timer_next;
  reg        w_inf_next;    reg [7:0] w_pinmask_next;
  reg        cy_next, ovf_next, zero_next, tmo_next;
  reg        err_set;
  reg        halt_next;
  reg [15:0] ev_mask_next;
  reg        ev_pol_next;

  always @(*) begin : exec_blk
    // ------- defaults: hold state, advance pc -------
    pc_next        = pc + 1'b1;
    x_next         = X;      y_next = Y;       sp_next = sp;
    rf_we = 1'b0; rf_waddr = {1'b0, f_rr}; rf_wdata = X;
    d_we = 1'b0;   d_wdata = deadline_q; clr_deadline = 1'b0;
    drv_we = 1'b0; drv_val = X[7:0]; drv_oe = 8'h00; drv_od = 1'b0;
    gou_we = 1'b0; gou_op = 2'd0; gou_data = X[7:0];
    sh_we = 1'b0;  sh_waddr = X[5:0]; sh_wdata = Y;
    sh_re = 1'b0;  sh_raddr = Y[5:0];
    csr_we = 1'b0; csr_re = 1'b0; csr_addr = f_a; csr_wdata = X;
    be_cfg_we = 1'b0; be_cfg_addr = f_imm6[3:0]; be_cfg_wdata = X;
    be_wrbit = 1'b0; be_wrbit_data = X[7:0];
    be_ldshreg = 1'b0; be_ldshreg_val = X;
    crc_we = 1'b0; crc_op = 2'd0; crc_val = X;
    rx_rd = 1'b0;  tx_wr = 1'b0;  tx_wdata = X[7:0];
    trc_we = 1'b0; trc_evt = f_r[3:0];
    edg_we = 1'b0; edg_addr = {TID[1:0], f_rr[0]};
    ext_trg_we = 1'b0; ext_idle_we = 1'b0;
    // rf read ports are combinational in top (muxed); these outputs carry the
    // addresses computed this grant cycle.
    rf_re_a = 1'b0; rf_raddr_a = {1'b0, f_rr};
    rf_re_b = 1'b0; rf_raddr_b = 5'd1;
    edg_time = X; edg_val = Y[7:0]; edg_oe = Y[15:8]; edg_en = 1'b1;
    w_active_next = w_active; w_kind_next = w_kind; w_timer_next = w_timer;
    w_inf_next = w_inf; w_pinmask_next = w_pinmask;
    cy_next = cy_q; ovf_next = ovf_q; zero_next = zero_q; tmo_next = 1'b0;
    err_set = 1'b0;
    halt_next = 1'b0;
    ev_mask_next = ev_mask; ev_pol_next = ev_pol;

    if (grant && running && !stalling) begin
      if (w_active) begin
        // -------- parked wait re-evaluation --------
        if (cond_ok) begin
          w_active_next = 1'b0;
          tmo_next = timed_out;
          if (timed_out) begin trc_we = 1'b1; trc_evt = `TEVT_TMO; end
        end else begin
          pc_next = pc;
          if (!w_inf && w_timer != 5'd0) w_timer_next = w_timer - 5'd1;
        end
      end else if (illegal) begin
        err_set = 1'b1;
      end else begin
        case (opcode)
          // -----------------------------------------------------------
          `OP_MOV: begin
            rf_re_a = 1'b1; rf_raddr_a = {1'b0, f_rr};
            case (f_dst)
              2'd0: x_next = mov_src(f_src);
              2'd1: y_next = mov_src(f_src);
              2'd2: begin rf_we = 1'b1; rf_waddr = {1'b0, f_rr};
                        rf_wdata = mov_src(f_src); end
              default: x_next = rf_rdata_a;   // LDS-style read
            endcase
          end
          // -----------------------------------------------------------
          `OP_OUT: begin
            case (f_r)
              `O_OUT:  begin drv_we = 1'b1; drv_val = X[7:0]; drv_oe = Y[7:0]; end
              `O_OUTD: begin drv_we = 1'b1; drv_val = X[7:0]; drv_oe = ~X[7:0]; drv_od = 1'b1; end
              `O_SET:  begin gou_we = 1'b1; gou_op = 2'd0; gou_data = X[7:0]; end
              `O_CLR:  begin gou_we = 1'b1; gou_op = 2'd1; gou_data = X[7:0]; end
              `O_OEN:  begin gou_we = 1'b1; gou_op = 2'd2; gou_data = X[7:0]; end
              `O_OUTM: begin drv_we = 1'b1; drv_val = X[7:0];
                           drv_oe = {8'h00, f_imm6} & own_oe; end
              default: ;
            endcase
          end
          // -----------------------------------------------------------
          `OP_ALU: begin
            x_next = alu_res;
            cy_next = alu_cy; ovf_next = alu_ovf; zero_next = (alu_res == 16'h0);
          end
          // -----------------------------------------------------------
          `OP_BR: begin
            if (f_r == `BR_HALT) begin
              halt_next = 1'b1;          // deterministic halt at commit
              pc_next = pc + 1'b1;       // resume continues after HALT
            end else if (br_taken) begin
              pc_next = pc + 9'(off8) + 9'd1;
              if (f_a[5]) begin // link form: return addr -> rf[9]
                rf_we = 1'b1; rf_waddr = 5'd9; rf_wdata = {6'h0, pc + 1'b1};
              end
            end
          end
          // -----------------------------------------------------------
          `OP_WAIT: begin
            case (f_r)
              `W_CYC: begin
                d_we = 1'b1;
                d_wdata = time_q + {{(`JP_TIME_W-5){1'b0}}, f_imm5};
                w_active_next = 1'b1; w_kind_next = `W_CYC; w_inf_next = 1'b1;
                pc_next = pc + 1'b1;
              end
              `W_DADJ: begin
                d_we = 1'b1;
                d_wdata = deadline_q + {{(`JP_TIME_W-5){1'b0}}, f_imm5};
                w_active_next = 1'b1; w_kind_next = `W_DADJ; w_inf_next = 1'b1;
                pc_next = pc + 1'b1;
              end
              `W_DSYNC: begin
                if (t_ready) begin
                  d_we = 1'b1;
                  d_wdata = deadline_q + {{(`JP_TIME_W-5){1'b0}}, f_imm5};
                end
                w_active_next = 1'b1; w_kind_next = `W_DSYNC; w_inf_next = 1'b1;
                pc_next = pc + 1'b1;
              end
              `W_EDGE: begin
                w_active_next = 1'b1; w_kind_next = `W_EDGE;
                w_inf_next = (f_imm5 == 5'd0);
                w_timer_next = (f_imm5 == 5'd0) ? 5'd0 : f_imm5 - 5'd1;
                w_pinmask_next = X[7:0];
                pc_next = pc + 1'b1;
              end
              `W_TMO: begin
                w_active_next = 1'b1; w_kind_next = `W_TMO; w_inf_next = 1'b0;
                w_timer_next = (f_imm5 == 5'd0) ? 5'd0 : f_imm5 - 5'd1;
                pc_next = pc + 1'b1;
              end
              `W_EV: begin
                w_active_next = 1'b1; w_kind_next = `W_EV;
                w_inf_next = (f_imm5 == 5'd0);
                w_timer_next = (f_imm5 == 5'd0) ? 5'd0 : f_imm5 - 5'd1;
                ev_mask_next = Y; ev_pol_next = f_a[5];
                pc_next = pc + 1'b1;
              end
              `W_RDY: begin
                w_active_next = 1'b1; w_kind_next = `W_RDY;
                w_inf_next = (f_imm5 == 5'd0);
                w_timer_next = (f_imm5 == 5'd0) ? 5'd0 : f_imm5 - 5'd1;
                w_pinmask_next = X[7:0]; ev_pol_next = f_imm5[0];
                pc_next = pc + 1'b1;
              end
              `W_RQ: begin
                w_active_next = 1'b1; w_kind_next = `W_TMO; w_inf_next = 1'b0;
                w_timer_next = 5'd0;
                pc_next = pc + 1'b1;
              end
              default: ;
            endcase
          end
          // -----------------------------------------------------------
          `OP_PUSH: begin
            case (f_r)
              `PS_XLO: begin tx_wr = 1'b1; tx_wdata = X[7:0]; end
              `PS_XHI: begin tx_wr = 1'b1; tx_wdata = X[15:8]; end
              `PS_STK: begin
                rf_we = 1'b1; rf_waddr = sp[4:0]; rf_wdata = X;
                sp_next = sp - 6'd1;
              end
              `PS_MBX: begin tx_wr = 1'b1; tx_wdata = X[7:0]; end
              default: ;
            endcase
          end
          // -----------------------------------------------------------
          `OP_POP: begin
            case (f_r)
              `PP_XLO: begin rx_rd = 1'b1; x_next = {X[15:8], rx_rdata}; end
              `PP_XHI: begin rx_rd = 1'b1; x_next = {rx_rdata, X[7:0]}; end
              `PP_STK: begin rf_re_a = 1'b1; rf_raddr_a = sp[4:0];
                           x_next = rf_rdata_a; sp_next = sp + 6'd1; end
              `PP_MBX: begin rx_rd = 1'b1; x_next = {8'h00, rx_rdata}; end
              default: ;
            endcase
          end
          // -----------------------------------------------------------
          `OP_IN: begin
            case (f_r)
              `I_GPIO: x_next = {8'h00, gpio_sync};
              `I_RAW:  x_next = {8'h00, gpio_raw};
              `I_GI:   x_next = {8'h00, ui_in};
              default: x_next = {8'h00, gpio_sync & own_in};
            endcase
            zero_next = ({8'h00, gpio_sync} == 16'h0);
          end
          // -----------------------------------------------------------
          `OP_CSR: begin
            csr_addr = f_a;
            if (f_m[2] == 1'b0) begin
              csr_re = 1'b1; x_next = csr_rdata;
            end else begin
              csr_we = 1'b1; csr_wdata = {8'h00, f_imm8};
            end
          end

          // -----------------------------------------------------------
          `OP_LDI: begin
            // LDI r, imm16 — immediate word lives at pc+1; fetched through a
            // dedicated read lane (ldi_word). PC skips the operand word.
            rf_we = 1'b1; rf_waddr = {1'b0, f_rr}; rf_wdata = ldi_word;
            pc_next = pc + 2'd2;
          end
          // -----------------------------------------------------------
          `OP_JMPR: begin
            rf_re_a = 1'b1; rf_raddr_a = {1'b0, f_rr};
            if (f_a[5] == 1'b0) begin
              pc_next = rf_rdata_a[`JP_PROG_AW-1:0];
            end else begin
              pc_next = pc + {1'b0, imm9} + 1'b1; // direct relative imm9
            end
            if (f_a[4]) begin
              rf_we = 1'b1; rf_waddr = 5'd9; rf_wdata = {6'h0, pc + 1'b1};
            end
          end
          // -----------------------------------------------------------
          `OP_TRC: begin
            trc_we = trace_en;
            trc_evt = f_r[2] ? `TEVT_SW2 : `TEVT_SW1;
          end
          // -----------------------------------------------------------
          `OP_EXT: begin
            case (f_fn)
              `EXT_NOP: ;
              `EXT_SLEEP: begin
                w_active_next = 1'b1; w_kind_next = `W_TMO; w_inf_next = 1'b0;
                w_timer_next = (X[4:0] == 5'd0) ? 5'd0 : X[4:0] - 5'd1;
                pc_next = pc + 1'b1;
              end
              `EXT_CLRDEAD: clr_deadline = 1'b1;
              `EXT_CLOAD:   begin crc_we = 1'b1; crc_op = 2'd0; end
              `EXT_CA:      begin crc_we = 1'b1; crc_op = 2'd1; end
              `EXT_CR:      begin crc_we = 1'b1; crc_op = 2'd2; end
              `EXT_CGET16:  begin crc_we = 1'b1; crc_op = 2'd3;
                              x_next = crc_result; end
              `EXT_CGET8:   begin crc_we = 1'b1; crc_op = 2'd3;
                              x_next = {8'h00, crc_result[15:8]}; end
              `EXT_SHIFT:   x_next = f_a[0] ? {X[14:0], 1'b0} : {1'b0, X[15:1]};
              `EXT_GETTCNT: x_next = {11'h0, be_txcount};
              `EXT_SETTCNT: begin be_cfg_we = 1'b1; be_cfg_addr = 4'd5;
                                  be_cfg_wdata = {11'h0, X[4:0]}; end
              `EXT_GETRCNT: x_next = {11'h0, be_rxcount};
              `EXT_SETRCNT: begin be_cfg_we = 1'b1; be_cfg_addr = 4'd6;
                                  be_cfg_wdata = {11'h0, X[4:0]}; end
              `EXT_GETSHREG:x_next = be_shreg;
              `EXT_SETSHREG:begin be_ldshreg = 1'b1; be_ldshreg_val = X; end
              `EXT_TADD:    begin d_we = 1'b1; d_wdata = deadline_q + {{8'h00}, X}; end
              `EXT_TSUB:    x_next = t_ready & (deadline_q != time_q) ?
                                      (time_q - deadline_q) : 16'h0;
              `EXT_READT:   x_next = time_q[15:0];
              `EXT_READTH:  x_next = {8'h00, time_q[23:16]};
              `EXT_WRBIT:   begin be_wrbit = 1'b1; be_wrbit_data = X[7:0]; end
              `EXT_RDSTSW:  begin sh_re = 1'b1; sh_raddr = X[5:0]; x_next = sh_rdata; end
              `EXT_WRSTSW:  begin sh_we = 1'b1; sh_waddr = X[5:0]; sh_wdata = Y; end
              `EXT_GETOWM:  x_next = {8'h00, own_oe};
              `EXT_GETIOM:  x_next = {8'h00, own_in};
              `EXT_TRG:     begin ext_trg_we = 1'b1; ext_trg_bits_o = X[3:0]; end
              `EXT_ERR:     err_set = 1'b1;
              `EXT_DBGWR:   begin gou_we = 1'b1; gou_op = 2'd2; end
              `EXT_DBGRD:   x_next = {8'h00, ui_in};
              `EXT_GETSP:   x_next = {10'h0, sp};
              `EXT_SETSP:   begin sp_next = X[5:0];
                            rf_we = 1'b1; rf_waddr = 5'd10;
                            rf_wdata = {10'h0, X[5:0]}; end
              `EXT_IDLE: begin
                w_active_next = 1'b1; w_kind_next = `W_EV; w_inf_next = 1'b1;
                ev_mask_next = X; ev_pol_next = 1'b0; pc_next = pc + 1'b1;
                ext_idle_we = 1'b1; ext_idle_mask_o = X;
              end
              default: ;
            endcase
          end
          // -----------------------------------------------------------
          `OP_EDG: begin
            case (f_r)
              3'd0: begin edg_we = 1'b1; edg_en = 1'b1; end   // ARM: X=val,Y=oe,time_lo
              3'd1: begin edg_we = 1'b1; edg_en = 1'b0; end   // cancel
              3'd2: x_next = {12'h0, edg_valid[`JP_THREAD_W'(TID)*2 +: 2]};  // STAT
              default: ;
            endcase
          end
          default: err_set = 1'b1;
        endcase
      end
    end
  end

  // =========================================================================
  // Commit
  // =========================================================================
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc <= {`JP_PROG_AW{1'b0}}; running <= 1'b0;
      X <= 16'h0; Y <= 16'h0; sp <= 6'h0;
      cy_q <= 1'b0; ovf_q <= 1'b0; zero_q <= 1'b0; tmo_q <= 1'b0;
      w_active <= 1'b0; w_kind <= 3'd0; w_timer <= 5'd0; w_inf <= 1'b0;
      w_pinmask <= 8'h0; err_sticky <= 1'b0; ev_pol <= 1'b0; ev_mask <= 16'h0;
      ext_trg_we_o <= 1'b0; ext_trg_bits_o <= 4'h0;
      ext_idle_we_o <= 1'b0; ext_idle_mask_o <= 16'h0;
    end else begin
      pc        <= pc_next;
      running   <= start_lvl & ~halt_next;
      X         <= x_next;
      Y         <= y_next;
      sp        <= sp_next;
      cy_q <= cy_next; ovf_q <= ovf_next; zero_q <= zero_next; tmo_q <= tmo_next;
      w_active <= w_active_next; w_kind <= w_kind_next; w_timer <= w_timer_next;
      w_inf <= w_inf_next; w_pinmask <= w_pinmask_next;
      ev_pol <= ev_pol_next; ev_mask <= ev_mask_next;
      err_sticky <= err_sticky | err_set;
      ext_trg_we_o <= ext_trg_we_o & grant & running & ~stalling & ~w_active & ~illegal;
      ext_idle_we_o <= ext_idle_we_o & grant & running & ~stalling & ~w_active & ~illegal;
      if (rf_wen) rf[rf_widx] <= rf_wval;
    end
  end

endmodule
