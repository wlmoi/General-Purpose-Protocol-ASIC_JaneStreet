// SPDX-FileCopyrightText: © 2026 General-Purpose Protocol ASIC contributors
// SPDX-License-Identifier: Apache-2.0
// `default_nettype none

// -----------------------------------------------------------------------------
// prog_mem — shared writable program memory, 512 x 16 bits.
//
// Port contract (single physical port, IHP CMOS5L has no SRAM macro in the
// Tiny Tapeout tile set — verified against sg13g2 standard-cell flow; a
// flop-array is used and its area is documented in docs/AREA_TIMING.md):
//   * The engine fetches one instruction per cycle at `fetch_addr`.
//   * The host writes via hwe/ha/hwdata. Host access has PRIORITY: during a
//     host write the fetch port is ignored for ONE cycle and the scheduler
//     stalls (see scheduler: stalling is simply not advancing PC). This makes
//     host programming deterministic and can never corrupt an in-flight
//     fetch: the fetched word of the previous cycle is already registered.
//   * Read data for host: hrd_q updates on host reads (hre). Engine read is
//     the combinational fetch path (registered downstream in thread ctx).
// Reset semantics: memory contents are NOT reset (program persists across
// core reset so the host can reload atomically); control registers reset.
// -----------------------------------------------------------------------------
`include "defines.vh"

module prog_mem (
    input  wire                     clk,
    input  wire                     rst_n,
    // engine fetch port (granted thread's PC; top muxes sel_q)
    input  wire [`JP_PROG_AW-1:0]   fetch_addr,
    output wire [`JP_INST_W-1:0]    fetch_data,
    // LDI operand lane: combinational read at pc+1 (no write conflict:
    // host writes are staged to a shadow register and applied with hwe)
    input  wire [`JP_PROG_AW-1:0]   ldi_addr,
    output wire [`JP_INST_W-1:0]    ldi_data,
    // host port
    input  wire                     hre,
    input  wire                     hwe,
    input  wire [`JP_PROG_AW-1:0]   ha,
    input  wire [`JP_INST_W-1:0]    hwdata,
    input  wire                     hbe,           // 1=high byte,0=low byte
    output reg  [`JP_INST_W-1:0]    hrd,
    // stall flag to scheduler (host access occupies the port this cycle)
    output wire                     port_busy
);

  reg [`JP_INST_W-1:0] mem [0:`JP_PROG_DEPTH-1];

  // Contents intentionally un-initialized in hardware (host loads program
  // after reset). Simulation initializes to a known pattern to catch bugs.
  integer i;
  initial begin
    for (i = 0; i < `JP_PROG_DEPTH; i = i + 1) mem[i] = 16'h0000;
  end

  assign port_busy = hwe | hre;

  // single port: host write wins; otherwise nothing writes (read-only pass)
  always @(posedge clk) begin
    if (hwe) begin
      if (hbe) mem[ha][15:8] <= hwdata[15:8];
      else     mem[ha][7:0]  <= hwdata[7:0];
    end
  end

  always @(posedge clk) begin
    if (hre) hrd <= mem[ha];
  end

  assign fetch_data = mem[fetch_addr];
  assign ldi_data   = mem[ldi_addr];

endmodule
