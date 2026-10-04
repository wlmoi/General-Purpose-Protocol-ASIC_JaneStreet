// SPDX-FileCopyrightText: © 2026 General-Purpose Protocol ASIC contributors
// SPDX-License-Identifier: Apache-2.0
// `default_nettype none

// -----------------------------------------------------------------------------
// dm — thread data memory: 4 x 32 registers of 16 bits + shared window
//      (addresses 192..223 visible to every thread; used for host<->engine
//       byte FIFO staging and inter-thread messages).
// Single writer per cycle (the currently granted thread) plus asynchronous
// read ports (registered by callers one cycle later than write if needed).
// Written/read with byte enables so PUSH/POP bytes touch only one half.
// Verilator-friendly: plain arrays, no unpacked struct dimensions.
// -----------------------------------------------------------------------------
`include "defines.vh"

module dm (
    input  wire        clk,
    input  wire        rst_n,
    // write port (one per cycle, from granted thread or host bridge)
    input  wire        we,
    input  wire [7:0]  waddr,
    input  wire [15:0] wdata,
    input  wire [1:0]  be,          // byte enables: bit1 = high byte, bit0 = low
    // read port A (thread context X), read port B (Y / second operand)
    input  wire [7:0]  raddr_a,
    output wire [15:0] rdata_a,
    input  wire [7:0]  raddr_b,
    output wire [15:0] rdata_b
);

  reg [15:0] mem [0:`JP_DM_TOTAL-1];

  integer i;
  initial begin
    for (i = 0; i < `JP_DM_TOTAL; i = i + 1) mem[i] = 16'h0000;
  end

  assign rdata_a = mem[raddr_a];
  assign rdata_b = mem[raddr_b];

  always @(posedge clk) begin
    if (we) begin
      if (be[0]) mem[waddr][7:0]   <= wdata[7:0];
      if (be[1]) mem[waddr][15:8]  <= wdata[15:8];
    end
  end

endmodule
