// SPDX-FileCopyrightText: (c) 2026 General-Purpose Protocol ASIC contributors
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

// =============================================================================
// edge_units.v — atomic future-edge scheduler for the GPIO fabric.
// 8 units total (2 per thread). Each unit fires ONCE when time_q[15:0]
// reaches its programmed absolute time (modular >=), applying {val, oe} to
// selected pins for exactly that cycle, then invalidates itself.
// After firing, software convention is that the persistent state comes from
// the global-out/thread path (firmware pre-loads gout/goe accordingly; see
// firmware libs). This keeps HW tiny while giving instruction-rate-independent
// edge placement with single-cycle jitter bound (docs/TIMING.md §Edge).
// =============================================================================

`include "defines.vh"

module edge_units (
    input  wire            clk,
    input  wire            rst_n,
    // arm port (granted thread only; addr space TID*2+u)
    input  wire            arm_we,
    input  wire [2:0]      arm_addr,
    input  wire [15:0]     arm_time,
    input  wire [7:0]      arm_val,
    input  wire [7:0]      arm_oe,
    input  wire            arm_en,
    output reg  [7:0]      valid_q,
    // time base
    input  wire [23:0]     time_q,
    // fired override (one cycle)
    output reg  [7:0]      ed_val,
    output reg  [7:0]      ed_oe,
    output reg             fired_pulse
);

  reg [15:0] t_q [0:7];
  reg [7:0]  v_q [0:7];
  reg [7:0]  m_q [0:7];

  wire [15:0] tnow = time_q[15:0];

  integer i;
  initial begin
    valid_q = 8'h0; ed_val = 8'h0; ed_oe = 8'h0; fired_pulse = 1'b0;
    for (i = 0; i < 8; i = i + 1) begin t_q[i] = 16'h0; v_q[i] = 8'h0; m_q[i] = 8'h0; end
  end

  // modular due test within +-half-window rule
  function automatic due(input [15:0] t);
    reg [15:0] d;
    begin
      d = tnow - t;
      due = ~d[15];
    end
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_q <= 8'h0; ed_val <= 8'h0; ed_oe <= 8'h0; fired_pulse <= 1'b0;
    end else begin
      ed_val <= 8'h00; ed_oe <= 8'h00; fired_pulse <= 1'b0;

      if (arm_we) begin
        valid_q[arm_addr] <= arm_en;
        t_q[arm_addr]     <= arm_time;
        v_q[arm_addr]     <= arm_val;
        m_q[arm_addr]     <= arm_oe;
      end

      for (i = 0; i < 8; i = i + 1) begin
        if (valid_q[i] && !(arm_we && (arm_addr == i[2:0])) && due(t_q[i])) begin
          ed_val      <= ed_val | (v_q[i] & m_q[i]);
          ed_oe       <= ed_oe  | m_q[i];
          valid_q[i]  <= 1'b0;
          fired_pulse <= 1'b1;
        end
      end
    end
  end

endmodule
