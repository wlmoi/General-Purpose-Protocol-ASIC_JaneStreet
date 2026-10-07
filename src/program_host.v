`default_nettype none
module program_host (
 input wire clk, rst_n, cs_n, sclk, mosi,
 output wire miso,
 output reg write_strobe, read_strobe,
 output reg [6:0] address,
 output reg [7:0] write_data,
 input wire [7:0] read_data
);
 reg [2:0] cs_sync, clock_sync;
 reg [1:0] data_sync;
 reg [2:0] count;
 reg [7:0] rx, tx;
 reg command, writing, first_fall;
 wire rising = clock_sync[1] & ~clock_sync[2];
 wire falling = ~clock_sync[1] & clock_sync[2];
 wire [7:0] received = {rx[6:0], data_sync[1]};
 assign miso = !cs_sync[1] && command ? tx[7] : 1'b0;
 always @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
   cs_sync <= 3'b111; clock_sync <= 0; data_sync <= 0;
   count <= 0; rx <= 0; tx <= 0; command <= 0; writing <= 0;
   first_fall <= 0; address <= 0; write_data <= 0;
   write_strobe <= 0; read_strobe <= 0;
  end else begin
   cs_sync <= {cs_sync[1:0], cs_n};
   clock_sync <= {clock_sync[1:0], sclk};
   data_sync <= {data_sync[0], mosi};
   write_strobe <= 0; read_strobe <= 0;
   if (cs_sync[1]) begin
    count <= 0; command <= 0; first_fall <= 0; tx <= 0;
   end else begin
    if (rising) begin
     rx <= received; count <= count + 3'd1;
     if (count == 7) begin
      first_fall <= 1;
      if (!command) begin
       address <= received[6:0]; writing <= received[7]; command <= 1;
      end else if (writing) begin
       write_data <= received; write_strobe <= 1;
      end else read_strobe <= 1;
     end
    end
    if (falling && command) begin
     if (first_fall) begin
      tx <= writing ? 8'd0 : read_data; first_fall <= 0;
     end else tx <= {tx[6:0], 1'b0};
    end
   end
  end
 end
endmodule
