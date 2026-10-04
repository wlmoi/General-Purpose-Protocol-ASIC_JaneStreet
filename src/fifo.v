// SPDX-FileCopyrightText: © 2026 General-Purpose Protocol ASIC contributors
// SPDX-License-Identifier: Apache-2.0
// `default_nettype none

// -----------------------------------------------------------------------------
// fifo — simple synchronous FIFO (flop array; depth power of two).
// Single clock domain. Write and read may occur in the same cycle.
// Writes when full and reads when empty are ignored (flagged); assertions
// at instantiation sites check software never does that silently.
// -----------------------------------------------------------------------------

module fifo #(
    parameter DEPTH = 8,
    parameter WIDTH = 8,
    parameter AW    = 3
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire             wr,
    input  wire [WIDTH-1:0] wdata,
    input  wire             rd,
    output reg  [WIDTH-1:0] rdata,
    output wire             full,
    output wire             empty
);

  reg [WIDTH-1:0] mem [0:DEPTH-1];

  reg [AW:0] wp, rp;
  wire [AW:0] wc = {1'b0, wp[AW-1:0]} + {{AW{1'b0}}, wr};
  wire [AW:0] rc = {1'b0, rp[AW-1:0]} + {{AW{1'b0}}, rd};

  assign full  = (wp[AW]   != rc[AW])  && (wp[AW-1:0] == rc[AW-1:0]);
  assign empty = (wp == rc);

  integer i;
  initial begin
    for (i = 0; i < DEPTH; i = i + 1) mem[i] = {WIDTH{1'b0}};
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wp    <= {(AW+1){1'b0}};
      rp    <= {(AW+1){1'b0}};
      rdata <= {WIDTH{1'b0}};
    end else begin
      if (wr && !full) begin
        mem[wp[AW-1:0]] <= wdata;
        wp              <= wc;
      end
      if (rd && !empty) begin
        rdata <= mem[rp[AW-1:0]];
        rp    <= rc;
      end
    end
  end

endmodule
