`default_nettype none
`include "defines.vh"
module tt_um_janestreet_protocol_engine (
 input wire [7:0] ui_in,
 output wire [7:0] uo_out,
 input wire [7:0] uio_in,
 output wire [7:0] uio_out, uio_oe,
 input wire ena, clk, rst_n
);
 reg [8:0] pc [0:3];
 reg [15:0] x [0:3], y [0:3], received [0:3];
 reg [7:0] wait_count [0:3], pin_mask [0:3];
 reg [3:0] halted, errors;
 reg [1:0] slot, host_tid;
 reg [15:0] prog_mem_q [0:`JP_PROG_DEPTH-1];
 reg [7:0] output_q, output_oe_q;
 reg [7:0] gpio_meta, gpio_sync;
 reg core_enabled;
 reg [9:0] byte_address;
 reg [8:0] entry_pc;
 integer i;
 wire host_write, host_read, host_miso;
 wire [6:0] host_address;
 wire [7:0] host_data;
 reg [7:0] host_read_data;
 program_host host (
  .clk(clk), .rst_n(rst_n), .cs_n(ui_in[0]), .sclk(ui_in[1]),
  .mosi(ui_in[2]), .miso(host_miso), .write_strobe(host_write),
  .read_strobe(host_read), .address(host_address),
  .write_data(host_data), .read_data(host_read_data)
 );
 wire [8:0] active_pc = pc[slot];
 wire [15:0] active_x = x[slot], active_y = y[slot];
 wire [15:0] instruction = prog_mem_q[active_pc];
 wire [3:0] opcode = instruction[15:12];
 wire [7:0] immediate = instruction[7:0];
 wire [2:0] function_code = instruction[11:9];
 wire [8:0] branch_target = active_pc + {instruction[8], instruction[8:1]} + 9'd1;
 wire [7:0] owned = pin_mask[slot];
 wire pin_ready = gpio_sync[instruction[2:0]] == instruction[3];
 wire host_mutation = host_write;
 wire [7:0] other_pins =
   ((host_tid != 0) ? pin_mask[0] : 8'd0) |
   ((host_tid != 1) ? pin_mask[1] : 8'd0) |
   ((host_tid != 2) ? pin_mask[2] : 8'd0) |
   ((host_tid != 3) ? pin_mask[3] : 8'd0);
 always @* begin
  host_read_data = 0;
  case (host_address)
   0: host_read_data = {7'd0, core_enabled};
   1: host_read_data = {errors, ~halted};
   2: host_read_data = byte_address[7:0];
   3: host_read_data = {6'd0, byte_address[9:8]};
   4: host_read_data = byte_address[0] ? prog_mem_q[byte_address[9:1]][15:8] : prog_mem_q[byte_address[9:1]][7:0];
   5: host_read_data = {6'd0, host_tid};
   6: host_read_data = entry_pc[7:0];
   7: host_read_data = {7'd0, entry_pc[8]};
   10: host_read_data = pin_mask[host_tid];
   12: host_read_data = 8'hA6;
   13: host_read_data = received[host_tid][7:0];
   14: host_read_data = received[host_tid][15:8];
   15: host_read_data = pc[host_tid][7:0];
   16: host_read_data = {7'd0, pc[host_tid][8]};
   17: host_read_data = x[host_tid][7:0];
   18: host_read_data = x[host_tid][15:8];
   default: ;
  endcase
 end
 always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin gpio_meta <= 0; gpio_sync <= 0; end
  else begin gpio_meta <= uio_in; gpio_sync <= gpio_meta; end
 end
 // Host writes paused memory only; memory deliberately has no reset/init.
 always @(posedge clk) begin
  if (rst_n && host_write && host_address == 4 && !core_enabled) begin
   if (byte_address[0]) prog_mem_q[byte_address[9:1]][15:8] <= host_data;
   else prog_mem_q[byte_address[9:1]][7:0] <= host_data;
  end
 end
 always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
   slot <= 0; halted <= 4'hF; errors <= 0;
   output_q <= 0; output_oe_q <= 0;
   core_enabled <= 0; byte_address <= 0; host_tid <= 0; entry_pc <= 0;
   for (i = 0; i < 4; i = i + 1) begin
    pc[i] <= 0; x[i] <= 0; y[i] <= 0; received[i] <= 0;
    wait_count[i] <= 0; pin_mask[i] <= 0;
   end
  end else begin
   if (host_read && host_address == 4) byte_address <= byte_address + 10'd1;
   if (host_write) begin
    case (host_address)
     0: core_enabled <= host_data[0];
     2: byte_address[7:0] <= host_data;
     3: byte_address[9:8] <= host_data[1:0];
     4: begin
      if (!core_enabled) byte_address <= byte_address + 10'd1;
      else errors[host_tid] <= 1;
     end
     5: host_tid <= host_data[1:0];
     6: entry_pc[7:0] <= host_data;
     7: entry_pc[8] <= host_data[0];
     8: for (i = 0; i < 4; i = i + 1)
      if (host_data[i]) begin
       pc[i] <= entry_pc; x[i] <= 0; y[i] <= 0;
       received[i] <= 0; wait_count[i] <= 0;
       halted[i] <= 0; errors[i] <= 0;
      end
     9: begin
      halted <= halted | host_data[3:0];
      for (i = 0; i < 8; i = i + 1)
       if ((host_data[0] && pin_mask[0][i]) || (host_data[1] && pin_mask[1][i]) ||
           (host_data[2] && pin_mask[2][i]) || (host_data[3] && pin_mask[3][i])) output_oe_q[i] <= 0;
     end
     10: begin
      if (!core_enabled && !(|(host_data & other_pins))) begin
       pin_mask[host_tid] <= host_data;
       output_oe_q <= output_oe_q & ~pin_mask[host_tid];
      end else errors[host_tid] <= 1;
     end
     11: errors <= errors & ~host_data[3:0];
     default: ;
    endcase
   end
   if (ena && core_enabled && !host_mutation) begin
    slot <= slot + 2'd1;
    if (!halted[slot]) begin
     if (wait_count[slot] != 0) wait_count[slot] <= wait_count[slot] - 8'd1;
     else begin
      pc[slot] <= active_pc + 9'd1;
      case (opcode)
       0: if (instruction[8]) y[slot] <= {8'd0, immediate}; else x[slot] <= {8'd0, immediate};
       1: case (function_code)
        0: begin
         output_q <= (output_q & ~owned) | (active_x[7:0] & owned);
         output_oe_q <= (output_oe_q & ~owned) | (active_y[7:0] & owned);
        end
        1: begin
         output_q <= output_q & ~owned;
         output_oe_q <= (output_oe_q & ~owned) | (~active_x[7:0] & owned);
        end
        default: errors[slot] <= 1;
       endcase
       2: case (function_code)
        0: x[slot] <= active_x + active_y;
        1: x[slot] <= active_x - active_y;
        2: x[slot] <= active_x | active_y;
        3: x[slot] <= active_x & active_y;
        4: x[slot] <= active_x ^ active_y;
        5: x[slot] <= active_x << 1;
        6: x[slot] <= active_x >> 1;
        7: x[slot] <= {active_x[14:0], active_x[15]};
       endcase
       3: case (function_code)
        0: pc[slot] <= branch_target;
        1: if (active_x == active_y) pc[slot] <= branch_target;
        2: if (active_x != active_y) pc[slot] <= branch_target;
        3: if (active_x < active_y) pc[slot] <= branch_target;
        4: if (active_x > active_y) pc[slot] <= branch_target;
        5: errors[slot] <= 1;
        6: if (active_x != 0) pc[slot] <= branch_target;
        7: halted[slot] <= 1;
       endcase
       4: case (function_code)
        0: wait_count[slot] <= immediate;
        1: if (!pin_ready) pc[slot] <= active_pc;
        default: errors[slot] <= 1;
       endcase
       7: case (function_code)
        0: x[slot] <= {8'd0, gpio_sync};
        4: received[slot] <= {received[slot][14:0], gpio_sync[instruction[2:0]]};
        5: received[slot] <= {8'd0, gpio_sync[instruction[2:0]], received[slot][7:1]};
        6: x[slot] <= received[slot];
        default: errors[slot] <= 1;
       endcase
       9: begin
        if (instruction[8]) y[slot] <= prog_mem_q[(active_pc + 9'd1) & 9'h1FF];
        else x[slot] <= prog_mem_q[(active_pc + 9'd1) & 9'h1FF];
        pc[slot] <= active_pc + 9'd2;
       end
       default: errors[slot] <= 1;
      endcase
     end
    end
   end
  end
 end
 assign uo_out = {errors[1:0], ~halted, core_enabled, host_miso};
 assign uio_out = output_q;
 assign uio_oe = ena ? output_oe_q : 8'd0;
endmodule
