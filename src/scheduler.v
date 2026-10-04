// SPDX-FileCopyrightText: (c) 2026 General-Purpose Protocol ASIC contributors
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

// =============================================================================
// scheduler.v — deterministic round-robin grant generator + core enable.
//
// Grant sequence is strictly T0,T1,T2,T3,T0,... on enabled cycles, skipping
// nothing (determinism beats efficiency here; waiting threads consume their
// slot for one re-evaluation cycle which is architecturally visible and
// formally checkable). A thread that is not running issues no side effects
// during its slot (the thread module gates execution on `running`).
//
// Host progmem access (hre/hwe) occupies the single memory port for one
// cycle: the current slot is *stalled* (grant suppressed, RR index frozen),
// so a host write never corrupts an in-flight fetch and the instruction
// executes exactly once when the port frees. This is the precise definition
// of concurrent CPU/host memory behavior (docs/ISA.md §Memory).
// =============================================================================

`include "defines.vh"

module scheduler (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    en,             // core time enabled
    input  wire                    stalling,       // progmem port busy
    input  wire [`JP_NUM_THREADS-1:0] running,     // thread run bitmap
    output reg  [1:0]              sel_q,          // current slot owner
    output wire [`JP_NUM_THREADS-1:0] grant,       // one-hot, this cycle executes
    output wire [`JP_NUM_THREADS-1:0] any_grant
);

  wire [1:0] sel_next = (sel_q == 2'd3) ? 2'd0 : sel_q + 2'd1;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)        sel_q <= 2'd0;
    else if (en && !stalling) sel_q <= sel_next;
  end

  genvar g;
  generate
    for (g = 0; g < `JP_NUM_THREADS; g = g + 1) begin : g_grant
      assign grant[g] = en & ~stalling & (sel_q == g[1:0]) & running[g];
    end
  endgenerate

  assign any_grant = |grant;

endmodule
