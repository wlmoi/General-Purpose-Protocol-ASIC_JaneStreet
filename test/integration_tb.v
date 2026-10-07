`timescale 1ns/1ps
module integration_tb;
 reg clk = 0;
 always #5 clk = ~clk;
 reg rst_n = 0, ena = 0;
 reg [7:0] ui_in = 8'd1;
 reg [7:0] gpio_drive = 0;
 wire [7:0] uio_in, uo_out, uio_out, uio_oe;
 // External drivers are used on released pins. Models pull-ups by driving 1.
 assign uio_in = (gpio_drive & ~uio_oe) | (uio_out & uio_oe);
 tt_um_janestreet_protocol_engine dut (
  .clk(clk), .rst_n(rst_n), .ena(ena), .ui_in(ui_in),
  .uio_in(uio_in), .uo_out(uo_out), .uio_out(uio_out), .uio_oe(uio_oe)
 );
 task clocks(input integer n);
  repeat(n) begin @(posedge clk); #1; end
 endtask
 task spi_begin;
  begin @(negedge clk); ui_in = 0; clocks(8); end
 endtask
 task spi_end;
  begin @(negedge clk); ui_in = 1; clocks(8); end
 endtask
 task spi_byte(input [7:0] value, output [7:0] result);
  integer b;
  begin
   result = 0;
   for (b = 7; b >= 0; b = b - 1) begin
    @(negedge clk); ui_in[2] = value[b]; clocks(4);
    @(negedge clk); result = {result[6:0], uo_out[0]}; ui_in[1] = 1;
    clocks(4); @(negedge clk); ui_in[1] = 0; clocks(4);
   end
  end
 endtask
 reg [7:0] discarded;
 task wr(input [6:0] address, input [7:0] value);
  begin
   spi_begin(); spi_byte({1'b1,address}, discarded);
   spi_byte(value, discarded); spi_end();
  end
 endtask
 task rd(input [6:0] address, output [7:0] value);
  begin
   spi_begin(); spi_byte({1'b0,address}, discarded);
   spi_byte(0, value); spi_end();
  end
 endtask
 task select_thread(input [1:0] tid, input [8:0] entry, input [7:0] mask);
  begin
   wr(5, {6'd0,tid}); wr(6, entry[7:0]); wr(7, {7'd0,entry[8]});
   wr(10, mask); wr(8, 8'd1 << tid);
  end
 endtask
 task trace_state(input integer cycle, input [7:0] before_gpio);
  integer t;
  begin
   $write("TRACE %0d %0d %0d %0d %0d %0d %0d %0d", cycle, before_gpio,
    ena, dut.slot, uio_out, uio_oe, dut.halted, dut.errors);
   for(t = 0; t < 4; t = t+1)
    $write(" %0d %0d %0d %0d %0d", dut.pc[t], dut.x[t], dut.y[t],
      dut.received[t], dut.wait_count[t]);
   $write("\n");
  end
 endtask
 reg [15:0] image [0:511];
 // Safety invariants checked on every simulation clock, including host loads.
 always @(posedge clk) begin
  #1;
  if(rst_n) begin
   if(^{uio_out, uio_oe, uo_out} === 1'bx) $fatal(1,"unknown output");
   if(!ena && uio_oe !== 0) $fatal(1,"disabled design drives pins");
   if(|(dut.output_oe_q & ~(dut.pin_mask[0] | dut.pin_mask[1] |
                              dut.pin_mask[2] | dut.pin_mask[3])))
    $fatal(1,"unowned pin driven");
   if(|((dut.pin_mask[0] & dut.pin_mask[1]) | (dut.pin_mask[0] & dut.pin_mask[2]) |
         (dut.pin_mask[0] & dut.pin_mask[3]) | (dut.pin_mask[1] & dut.pin_mask[2]) |
         (dut.pin_mask[1] & dut.pin_mask[3]) | (dut.pin_mask[2] & dut.pin_mask[3])))
    $fatal(1,"overlapping ownership");
  end
 end
 integer i;
 reg [7:0] value;
 initial begin
  clocks(4); @(negedge clk); rst_n = 1; clocks(8);
  if (uio_oe !== 0 || uio_out !== 0 || uo_out !== 0) $fatal(1,"reset outputs");
  rd(12, value); if(value !== 8'hA6) $fatal(1,"host ID: %h", value);
  $readmemh("program.hex", image);
  // Burst covers all 1024 bytes, including address bit 9 and wraparound.
  spi_begin(); spi_byte(8'h84, discarded);
  for(i=0; i<512; i=i+1) begin
   spi_byte(image[i][7:0], discarded); spi_byte(image[i][15:8], discarded);
  end
  spi_end();
  rd(2, value); if(value !== 0) $fatal(1,"address did not wrap");
  rd(3, value); if(value !== 0) $fatal(1,"high address did not wrap");
  spi_begin(); spi_byte(8'h04, discarded);
  for(i=0; i<512; i=i+1) begin
   spi_byte(0, value); if(value !== image[i][7:0]) $fatal(1,"readback low %d",i);
   spi_byte(0, value); if(value !== image[i][15:8]) $fatal(1,"readback high %d",i);
  end
  spi_end();
  // CASE_BODY is supplied by the Python integration runner.
  `include "case_body.vh"
  $display("PASS"); $finish;
 end
 initial begin #100000000; $fatal(1,"simulation timeout"); end
endmodule
