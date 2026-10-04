// SPDX-FileCopyrightText: (c) 2026 General-Purpose Protocol ASIC contributors
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

// =============================================================================
// gpio.v — GPIO fabric: synchronization, ownership, drive arbitration, pads.
// Full semantics in docs/GPIO.md. One clock domain; inputs are the only
// asynchronous signals and pass a 2-flop synchronizer before any consumer.
//
// Drive source priority per pin (deterministic, no electrical contention):
//   1. edge unit firing this cycle        (atomic scheduled event)
//   2. bit engine (if enabled for this pin)
//   3. thread OUT/OUTD immediate drive    (latched persistent state)
//   4. global out registers (SET/CLR/OEN)
// A thread driving an unowned pin: request is masked off AND the owning
// error flag pulses to ISR[DRV_ERR] so firmware can detect violations.
// =============================================================================

`include "defines.vh"

module gpio (
    input  wire                    clk,
    input  wire                    rst_n,

    // pad interface (uio bidirectional group)
    input  wire [`JP_GPIO_W-1:0]   uio_in_pad,
    output wire [`JP_GPIO_W-1:0]   uio_out_pad,
    output wire [`JP_GPIO_W-1:0]   uio_oe_pad,

    // ownership masks (CSR writes; full-value write, one writer/cycle)
    input  wire                    owm_we,
    input  wire [1:0]              owm_tgt,      // 0 own_in, 1 own_oe
    input  wire [`JP_GPIO_W-1:0]   owm_data,
    output reg  [`JP_GPIO_W-1:0]   own_in,
    output reg  [`JP_GPIO_W-1:0]   own_oe,

    // thread immediate drive request (from granted thread)
    input  wire                    thr_we,
    input  wire [`JP_GPIO_W-1:0]   thr_val,
    input  wire [`JP_GPIO_W-1:0]   thr_oe,       // pins to drive (pre-mask)
    input  wire                    thr_od,       // open-drain encoding
    input  wire [1:0]              thr_id,

    // global out register ops
    input  wire                    gou_we,
    input  wire [1:0]              gou_op,       // 0 set,1 clr,2 oe-write
    input  wire [`JP_GPIO_W-1:0]   gou_data,

    // bit engine override (single pin)
    input  wire                    be_drv,
    input  wire [2:0]              be_pin,
    input  wire                    be_val,
    input  wire                    be_oe,

    // edge-unit fired override
    input  wire [`JP_GPIO_W-1:0]   ed_val,
    input  wire [`JP_GPIO_W-1:0]   ed_oe,       // already includes value bits

    // synchronized views
    output reg  [`JP_GPIO_W-1:0]   sync_q,
    output wire [`JP_GPIO_W-1:0]   raw_q,
    output reg  [`JP_GPIO_W-1:0]   edge_pulse,
    output reg                     drv_err_pulse,
    output reg  [1:0]              drv_err_tid,
    output reg  [`JP_GPIO_W-1:0]   gout_q,
    output reg  [`JP_GPIO_W-1:0]   goe_q
);

  reg [`JP_GPIO_W-1:0] s1, s2, s2d;
  reg [`JP_GPIO_W-1:0] tval, toe;

  assign raw_q = uio_in_pad;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1 <= {`JP_GPIO_W{1'b0}}; s2 <= {`JP_GPIO_W{1'b0}};
      s2d <= {`JP_GPIO_W{1'b0}};
    end else begin
      s1  <= uio_in_pad;
      s2  <= s1;
      s2d <= s2;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sync_q     <= {`JP_GPIO_W{1'b0}};
      edge_pulse <= {`JP_GPIO_W{1'b0}};
    end else begin
      sync_q     <= s2;
      edge_pulse <= s2 ^ s2d;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      own_in <= {`JP_GPIO_W{1'b0}};
      own_oe <= {`JP_GPIO_W{1'b0}};
    end else if (owm_we) begin
      if (owm_tgt == 2'd0) own_in  <= owm_data;
      else                 own_oe  <= owm_data;
    end
  end

  wire [`JP_GPIO_W-1:0] allowed   = thr_oe & own_oe;
  wire                  viol      = thr_we & |(thr_oe & ~own_oe);
  wire [`JP_GPIO_W-1:0] req_oe    = thr_od ? (~thr_val) : thr_oe;
  wire [`JP_GPIO_W-1:0] eff_oe    = req_oe & own_oe;         // owned-only
  wire [`JP_GPIO_W-1:0] eff_val   = thr_val;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tval <= {`JP_GPIO_W{1'b0}}; toe <= {`JP_GPIO_W{1'b0}};
      gout_q <= {`JP_GPIO_W{1'b0}}; goe_q <= {`JP_GPIO_W{1'b0}};
      drv_err_pulse <= 1'b0; drv_err_tid <= 2'd0;
    end else begin
      if (thr_we) begin
        tval <= eff_val;
        toe  <= eff_oe;
      end
      drv_err_pulse <= viol;
      drv_err_tid   <= thr_id;
      if (gou_we) begin
        case (gou_op)
          2'd0:    gout_q <= gout_q | gou_data;
          2'd1:    gout_q <= gout_q & ~gou_data;
          default: goe_q  <= gou_data;
        endcase
      end
    end
  end

  initial begin
    tval = 8'h0; toe = 8'h0; gout_q = 8'h0; goe_q = 8'h0;
    own_in = 8'h0; own_oe = 8'h0; sync_q = 8'h0; edge_pulse = 8'h0;
    drv_err_pulse = 1'b0; drv_err_tid = 2'd0;
  end

  genvar p;
  generate
    for (p = 0; p < `JP_GPIO_W; p = p + 1) begin : g_mux
      wire sel_be = be_drv && (be_pin == p[2:0]);
      wire d_oe   = ed_oe[p] ? 1'b1 :
                   sel_be    ? be_oe : (toe[p] | goe_q[p]);
      wire d_val  = ed_oe[p] ? ed_val[p] :
                   sel_be    ? be_val :
                   toe[p]    ? tval[p] : gout_q[p];
      assign uio_oe_pad[p]  = d_oe;
      assign uio_out_pad[p] = d_val;
    end
  endgenerate

endmodule
