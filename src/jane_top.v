`default_nettype none
`include "defines.vh"

module tt_um_janestreet_protocol_engine (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
  reg [8:0] pc [0:3];
  reg [15:0] x [0:3];
  reg [15:0] y [0:3];
  reg [4:0] wait_count [0:3];
  reg [3:0] halted;
  reg [1:0] slot;
  reg [15:0] prog_mem_q [0:`JP_PROG_DEPTH-1];
  reg [7:0] output_q;
  reg [7:0] output_oe_q;
  reg [7:0] activity_q;
  integer i;

  wire [8:0] active_pc = pc[slot];
  wire [15:0] active_x = x[slot];
  wire [15:0] active_y = y[slot];
  wire [15:0] instruction = prog_mem_q[active_pc];
  wire [3:0] opcode = instruction[15:12];
  wire [7:0] immediate = instruction[7:0];
  wire [2:0] function_code = instruction[11:9];
  wire [8:0] branch_target = pc[slot] + {{1{instruction[8]}}, instruction[8:1]} + 9'd1;

  initial begin
    for (i = 0; i < `JP_PROG_DEPTH; i = i + 1)
      prog_mem_q[i] = 16'h0000;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      slot <= 2'd0;
      halted <= 4'b1111;
      output_q <= 8'h00;
      output_oe_q <= 8'h00;
      activity_q <= 8'h00;
      for (i = 0; i < 4; i = i + 1) begin
        pc[i] <= 9'd0;
        x[i] <= 16'd0;
        y[i] <= 16'd0;
        wait_count[i] <= 5'd0;
      end
    end else if (ena) begin
      activity_q <= activity_q + 8'd1;
      slot <= (slot == 2'd3) ? 2'd0 : slot + 2'd1;
      if (!halted[slot]) begin
        if (wait_count[slot] != 5'd0) begin
          wait_count[slot] <= wait_count[slot] - 5'd1;
        end else begin
          pc[slot] <= pc[slot] + 9'd1;
          case (opcode)
            4'h0: x[slot] <= {8'h00, immediate};
            4'h1: begin
              output_q <= active_x[7:0];
              output_oe_q <= active_y[7:0];
            end
            4'h2: begin
              case (function_code)
                3'd0: x[slot] <= active_x + active_y;
                3'd1: x[slot] <= active_x - active_y;
                3'd2: x[slot] <= active_x | active_y;
                3'd3: x[slot] <= active_x & active_y;
                3'd4: x[slot] <= active_x ^ active_y;
                default: ;
              endcase
            end
            4'h3: if (function_code == 3'd7) halted[slot] <= 1'b1;
                  else if (function_code == 3'd0) pc[slot] <= branch_target;
            4'h4: wait_count[slot] <= immediate[4:0];
            4'h7: x[slot] <= {8'h00, uio_in};
            4'h9: begin
              x[slot] <= prog_mem_q[active_pc + 9'd1];
              pc[slot] <= pc[slot] + 9'd2;
            end
            default: ;
          endcase
        end
      end
      if (ui_in[0]) halted <= halted & ~ui_in[7:4];
    end
  end

  assign uo_out = activity_q;
  assign uio_out = output_q ^ activity_q;
  assign uio_oe = output_oe_q | {8{activity_q[0]}};
endmodule
