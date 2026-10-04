// SPDX-FileCopyrightText: © 2026 General-Purpose Protocol ASIC contributors
// SPDX-License-Identifier: Apache-2.0
// `default_nettype none

// -----------------------------------------------------------------------------
// timing — global free-running absolute time base + per-thread deadlines.
//
// Semantics (see docs/TIMING.md):
//   * time_q increments every enabled cycle; wraps at 2^`JP_TIME_W.
//   * Each thread owns a deadline register D[t]. "ready" means T >= D using
//     modular comparison ((T - D) MSB-free rule): ready = (D == 0) ||
//     ((T - D) < 2^(W-1)) i.e. unsigned difference has MSB clear.
//   * Deadlines are written by the granted thread only (one writer/cycle).
//   * clr_deadline sets D := 0 which is defined as "always ready".
// -----------------------------------------------------------------------------
`include "defines.vh"

module timing (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          en,            // core enabled (time runs)
    // thread deadline writes (one-hot from scheduler grant)
    input  wire [`JP_NUM_THREADS-1:0]    d_we,
    input  wire [`JP_TIME_W-1:0]         d_wdata,       // shared data bus
    input  wire [`JP_NUM_THREADS-1:0]    clr_dl,        // level: D := 0
    output reg  [`JP_TIME_W-1:0]         time_q,
    output wire [`JP_TIME_W-1:0]         time_d,       // next value (sampled same-cycle)
    // per-thread readiness
    output wire [`JP_NUM_THREADS-1:0]    ready,
    // deadline readout for CSRs
    output wire [`JP_TIME_W-1:0]         dl0,
    output wire [`JP_TIME_W-1:0]         dl1,
    output wire [`JP_TIME_W-1:0]         dl2,
    output wire [`JP_TIME_W-1:0]         dl3
);

  reg [`JP_TIME_W-1:0] dl [0:`JP_NUM_THREADS-1];

  integer i;
  initial begin
    for (i = 0; i < `JP_NUM_THREADS; i = i + 1) dl[i] = {`JP_TIME_W{1'b0}};
  end

  assign time_d = time_q + {{`JP_TIME_W-1{1'b0}}, 1'b1};

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)        time_q <= {`JP_TIME_W{1'b0}};
    else if (en)       time_q <= time_d;
  end

  genvar g;
  generate
    for (g = 0; g < `JP_NUM_THREADS; g = g + 1) begin : g_ready
      wire [`JP_TIME_W-1:0] diff = time_q - dl[g];
      assign ready[g] = (dl[g] == {`JP_TIME_W{1'b0}}) ? 1'b1 : ~diff[`JP_TIME_W-1];
    end
  endgenerate

  assign dl0 = dl[0];
  assign dl1 = dl[1];
  assign dl2 = dl[2];
  assign dl3 = dl[3];

  always @(posedge clk) begin
    if (clr_dl[0])   dl[0] <= {`JP_TIME_W{1'b0}};
    else if (d_we[0]) dl[0] <= d_wdata;
    if (clr_dl[1])   dl[1] <= {`JP_TIME_W{1'b0}};
    else if (d_we[1]) dl[1] <= d_wdata;
    if (clr_dl[2])   dl[2] <= {`JP_TIME_W{1'b0}};
    else if (d_we[2]) dl[2] <= d_wdata;
    if (clr_dl[3])   dl[3] <= {`JP_TIME_W{1'b0}};
    else if (d_we[3]) dl[3] <= d_wdata;
  end

endmodule
