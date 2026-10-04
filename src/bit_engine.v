// SPDX-FileCopyrightText: (c) 2026 General-Purpose Protocol ASIC contributors
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

// =============================================================================
// bit_engine.v — autonomous line-level bit mover + CRC/LFSR primitive.
// NOT a protocol controller: the programmable CPU arms and feeds it so that
// 10-Mbit-class signaling does not depend on instruction issue rate.
//
// Modes (cfg.mode):
//   00 SHIFT : plain serial out of shreg at clkdiv ticks, tx_cnt bits;
//              dir_msb=1 MSB-first else LSB-first. TXDONE event at end.
//   01 UART-TX: idle high; EXT.WRBIT queues bytes; automatic start/8N1/stop
//              frames back-to-back at clkdiv+1 ticks per bit; TXDONE when
//              queue drains.
//   10 UART-RX: hunts falling start edge on raw pin; samples 8N1 mid-bit with
//              clkdiv = oversample_div - 1 (16x => clkdiv=15); raises RXDONE
//              and pushes byte into RX fifo via top-level handshake.
//   11 MAN-TX : Manchester encode queued bytes (IEEE 802.3 polarity:
//              '1' = hi->lo mid-transition), one half-tick per level,
//              tx_cnt counts HALF periods; ends with TXDONE.
//
// RX generic path in mode 00 collects rx_cnt bits into shreg (MSB or LSB
// insertion by dir_msb) then RXDONE.
//
// CRC unit: poly/xor/len/reflection programmable through cfg_addr 8..11.
// crc_op: 0 load reg, 1 xor byte into position (refl_in aware), 2 run 8
// bits one/cycle (crc_busy stalls the issuing thread's next CR-dependent
// read naturally because CGET returns busy-time value only after done;
// firmware convention: CR then CA chain is pipelined), 3 reverse-load X.
// =============================================================================

`include "defines.vh"

module bit_engine (
    input  wire                    clk,
    input  wire                    rst_n,

    // CSR write interface (granted thread or host only — one writer/cycle)
    input  wire                    cfg_we,
    input  wire [3:0]              cfg_addr,
    input  wire [15:0]             cfg_wdata,

    // byte pipeline into TX engines
    input  wire                    wrbit,
    input  wire [7:0]              wrbit_data,
    input  wire                    ldshreg,       // full-word shreg load (EXT.SETSHREG)
    input  wire [15:0]             ldshreg_val,

    // line interface
    input  wire                    rx_pin,        // synchronized sample
    input  wire                    rx_raw,        // async raw (start hunt)
    output reg                     tx_val,
    output reg                     tx_oe,
    output reg  [2:0]              pin_sel,
    output wire                    engine_active, // -> gpio be_drv

    // events / status
    output reg                     evt_tx_done,
    output reg                     evt_rx_done,
    output reg  [7:0]              rx_byte,
    output wire                    rx_byte_vld,
    input  wire                    rx_fifo_full,
    output wire                    rx_fifo_wr,
    output reg  [7:0]              rx_fifo_wdata,

    // readable state
    output wire [4:0]              tx_count_q,
    output wire [4:0]              rx_count_q,
    output wire [15:0]             shreg_q,

    // CRC ops
    input  wire                    crc_we,
    input  wire [1:0]              crc_op,
    input  wire [15:0]             crc_val,
    input  wire                    crc_len_set,   // cfg_wdata[4:0] used as len
    output wire                    crc_busy,
    output wire [15:0]             crc_result
);

  // ---- configuration registers --------------------------------------------
  reg [1:0]  mode;
  reg        dir_msb;
  reg [3:0]  width;                 // word width - 1 (7 => 8 bits)
  reg        refl_in, refl_out;
  reg [15:0] clkdiv, div_q;
  reg        tx_en, rx_en;
  reg [15:0] shreg;
  reg [4:0]  tx_cnt, rx_cnt;
  reg [7:0]  tx_hold;
  reg        tx_pend;
  reg [2:0]  step;                  // engine micro-state
  reg [3:0]  sub_cnt;               // bit index within frame
  reg        rx_have;

  // ---- CRC registers -------------------------------------------------------
  reg [15:0] crc_reg, crc_poly, crc_xor;
  reg [4:0]  crc_len;
  reg        crc_run;
  reg [3:0]  crc_bitcnt;
  reg [7:0]  crc_byte;

  wire [15:0] crc_rev = {crc_reg[0],crc_reg[1],crc_reg[2],crc_reg[3],
                         crc_reg[4],crc_reg[5],crc_reg[6],crc_reg[7],
                         crc_reg[8],crc_reg[9],crc_reg[10],crc_reg[11],
                         crc_reg[12],crc_reg[13],crc_reg[14],crc_reg[15]};
  assign crc_result   = (refl_out ? crc_rev : crc_reg) ^ crc_xor;
  assign crc_busy     = crc_run;
  assign tx_count_q   = tx_cnt;
  assign rx_count_q   = rx_cnt;
  assign shreg_q      = shreg;
  assign rx_byte_vld  = rx_have;
  assign engine_active= tx_en | rx_en;
  assign rx_fifo_wr   = evt_rx_done & (mode == 2'd2) & ~rx_fifo_full;

  initial begin
    mode = 2'd0; dir_msb = 1'b0; width = 4'd7; refl_in = 1'b0; refl_out = 1'b0;
    clkdiv = 16'd15; div_q = 16'd0; pin_sel = 3'd0;
    tx_en = 1'b0; rx_en = 1'b0; shreg = 16'h0; tx_cnt = 5'd0; rx_cnt = 5'd0;
    tx_hold = 8'h0; tx_pend = 1'b0; step = 3'd0; sub_cnt = 4'd0; rx_have = 1'b0;
    tx_val = 1'b1; tx_oe = 1'b0; evt_tx_done = 1'b0; evt_rx_done = 1'b0;
    rx_byte = 8'h0; rx_fifo_wdata = 8'h0;
    crc_reg = 16'h0; crc_poly = 16'h1021; crc_xor = 16'h0; crc_len = 5'd16;
    crc_run = 1'b0; crc_bitcnt = 4'd0; crc_byte = 8'h0;
  end

  // ---- config writes -------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mode <= 2'd0; dir_msb <= 1'b0; width <= 4'd7;
      refl_in <= 1'b0; refl_out <= 1'b0;
      clkdiv <= 16'd15; pin_sel <= 3'd0;
      tx_en <= 1'b0; rx_en <= 1'b0;
      tx_cnt <= 5'd0; rx_cnt <= 5'd0;
      crc_poly <= 16'h1021; crc_xor <= 16'h0; crc_len <= 5'd16;
      refl_in <= 1'b0; refl_out <= 1'b0;
    end else begin
      if (cfg_we) begin
        case (cfg_addr)
          4'd0: begin mode <= cfg_wdata[5:4]; dir_msb <= cfg_wdata[3];
                      pin_sel <= cfg_wdata[2:0]; width <= cfg_wdata[11:8];
                      refl_in <= cfg_wdata[12]; refl_out <= cfg_wdata[13]; end
          4'd1: clkdiv[7:0]  <= cfg_wdata[7:0];
          4'd2: clkdiv[15:8] <= cfg_wdata[7:0];
          4'd3: shreg[7:0]   <= cfg_wdata[7:0];
          4'd4: shreg[15:8]  <= cfg_wdata[7:0];
          4'd5: tx_cnt <= cfg_wdata[4:0];
          4'd6: rx_cnt <= cfg_wdata[4:0];
          4'd7: begin tx_en <= cfg_wdata[0]; rx_en <= cfg_wdata[1];
                    if (cfg_wdata[0]) begin div_q <= clkdiv; step <= 3'd0; sub_cnt <= 4'd0; end
                    if (cfg_wdata[2]) tx_en <= 1'b0;
                    if (cfg_wdata[3]) rx_en <= 1'b0;
                  end
          4'd8: crc_poly[7:0]  <= cfg_wdata[7:0];
          4'd9: crc_poly[15:8] <= cfg_wdata[7:0];
          4'd10: crc_xor[7:0]  <= cfg_wdata[7:0];
          4'd11: crc_xor[15:8] <= cfg_wdata[7:0];
          4'd12: crc_len <= cfg_wdata[4:0];
          default: ;
        endcase
      end
      if (wrbit) begin tx_hold <= wrbit_data; tx_pend <= 1'b1; end
      if (ldshreg) shreg <= ldshreg_val;
      if (crc_we) begin
        case (crc_op)
          2'd0: crc_reg <= crc_val;
          2'd1: crc_reg <= refl_in ? (crc_reg ^ {8'h00, crc_val[7:0]})
                                   : (crc_reg ^ {crc_val[7:0], 8'h00});
          2'd3: crc_reg <= {crc_val[0],crc_val[1],crc_val[2],crc_val[3],
                            crc_val[4],crc_val[5],crc_val[6],crc_val[7],
                            crc_val[8],crc_val[9],crc_val[10],crc_val[11],
                            crc_val[12],crc_val[13],crc_val[14],crc_val[15]};
          default: crc_byte <= crc_val[7:0];
        endcase
      end
    end
  end

  // ---- tick generator ------------------------------------------------------
  wire tick = (div_q == 16'h0);
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)            div_q <= 16'h0;
    else if (tick)         div_q <= clkdiv;
    else if (tx_en|rx_en)  div_q <= div_q - 16'h1;
  end

  // ---- CRC run -------------------------------------------------------------
  wire crc_in_bit = refl_in ? (crc_byte[0] ^ crc_reg[0])
                             : (crc_byte[7] ^ crc_reg[15]);
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      crc_run <= 1'b0; crc_bitcnt <= 4'd0;
    end else begin
      if (crc_we && crc_op == 2'd2) begin
        crc_run <= 1'b1; crc_bitcnt <= 4'd7;
      end else if (crc_run) begin
        if (refl_in) crc_reg <= crc_in_bit ? ({1'b0, crc_reg[15:1]} ^ crc_poly)
                                            : {1'b0, crc_reg[15:1]};
        else         crc_reg <= crc_in_bit ? ({crc_reg[14:0], 1'b0} ^ crc_poly)
                                            : {crc_reg[14:0], 1'b0};
        crc_byte   <= refl_in ? {1'b0, crc_byte[7:1]} : {crc_byte[6:0], 1'b0};
        if (crc_bitcnt != 4'd0) crc_bitcnt <= crc_bitcnt - 4'd1;
        else crc_run <= 1'b0;
      end
    end
  end

  // ---- TX engine -----------------------------------------------------------
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_val <= 1'b1; tx_oe <= 1'b0; evt_tx_done <= 1'b0; step <= 3'd0;
      sub_cnt <= 4'd0; tx_pend <= 1'b0; tx_hold <= 8'h0;
    end else begin
      evt_tx_done <= 1'b0;
      if (tx_en && tick) begin
        case (mode)
          2'd0: begin // plain shift
            tx_val <= dir_msb ? shreg[(width == 4'd0) ? 4'd15 : (width - 4'd1)] : shreg[0];
            shreg  <= dir_msb ? {shreg[14:0], 1'b0} : {1'b0, shreg[15:1]};
            tx_oe  <= 1'b1;
            if (tx_cnt != 5'd0) tx_cnt <= tx_cnt - 5'd1;
            else begin tx_en <= 1'b0; tx_oe <= 1'b0; evt_tx_done <= 1'b1; end
          end
          2'd1: begin // UART TX steps: 0 wait/hi, 1 start, 2 data, 3 stop
            tx_oe <= 1'b1;
            case (step)
              3'd0: begin tx_val <= 1'b1;
                        if (tx_pend) begin
                          tx_pend <= 1'b0; shreg <= {8'h00, tx_hold};
                          sub_cnt <= width; step <= 3'd1;
                        end else if (!tx_pend) begin
                          // drained: finish frame boundary then done
                          tx_en <= 1'b0; evt_tx_done <= 1'b1;
                        end
                      end
              3'd1: begin tx_val <= 1'b0; step <= 3'd2; end       // start bit
              3'd2: begin tx_val <= shreg[0]; shreg <= {1'b0, shreg[15:1]};
                        if (sub_cnt != 4'd0) sub_cnt <= sub_cnt - 4'd1;
                        else step <= 3'd3;
                      end
              3'd3: begin tx_val <= 1'b1; step <= 3'd0; end        // stop bit
              default: step <= 3'd0;
            endcase
          end
          2'd3: begin // Manchester TX
            tx_oe <= 1'b1;
            case (step)
              3'd0: begin tx_val <= shreg[sub_cnt]; step <= 3'd1; end
              3'd1: begin tx_val <= ~shreg[sub_cnt];
                        if (sub_cnt != 4'd0) sub_cnt <= sub_cnt - 4'd1;
                        else if (tx_pend) begin
                          shreg <= {8'h00, tx_hold}; tx_pend <= 1'b0; sub_cnt <= width;
                        end
                        step <= 3'd0;
                        if (tx_cnt != 5'd0) tx_cnt <= tx_cnt - 5'd1;
                        else begin tx_en <= 1'b0; evt_tx_done <= 1'b1; end
                      end
              default: step <= 3'd0;
            endcase
          end
          default: tx_en <= 1'b0;
        endcase
      end
      if (mode == 2'd1 && tx_en) tx_oe <= 1'b1;   // uart idles driven high
    end
  end

  // ---- RX engine -----------------------------------------------------------
  reg [7:0] rx_acc;
  reg [3:0] rx_bits_left;
  wire start_edge = (mode == 2'd2) && !rx_en && !rx_raw;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      evt_rx_done <= 1'b0; rx_byte <= 8'h0; rx_have <= 1'b0;
      step <= 3'd0; rx_bits_left <= 4'd0; rx_acc <= 8'h0; rx_fifo_wdata <= 8'h0;
    end else begin
      evt_rx_done <= 1'b0;
      if (start_edge) begin
        rx_en        <= 1'b1;
        div_q        <= {1'b0, clkdiv[15:1]};      // half tick to center sample
        step         <= 3'd1;                       // confirm start
        rx_bits_left <= width;
        rx_acc       <= 8'h0;
      end else if (rx_en && tick) begin
        case (step)
          3'd1: begin
            if (rx_pin) begin rx_en <= 1'b0; step <= 3'd0; end  // false start
            else begin step <= 3'd2; div_q <= clkdiv; end
          end
          3'd2: begin
            rx_acc <= {rx_pin, rx_acc[7:1]};
            if (rx_bits_left != 4'd0) rx_bits_left <= rx_bits_left - 4'd1;
            else step <= 3'd3;
          end
          3'd3: begin
            rx_byte <= rx_acc; rx_have <= 1'b1; rx_fifo_wdata <= rx_acc;
            evt_rx_done <= 1'b1; rx_en <= 1'b0; step <= 3'd0;
          end
          3'd4: begin // generic shift RX (mode 00)
            shreg <= dir_msb ? {shreg[14:0], rx_pin} : {rx_pin, shreg[15:1]};
            if (rx_cnt != 5'd0) rx_cnt <= rx_cnt - 5'd1;
            else begin rx_en <= 1'b0; rx_byte <= shreg[7:0]; rx_have <= 1'b1;
                       rx_fifo_wdata <= shreg[7:0]; evt_rx_done <= 1'b1; end
          end
          default: step <= 3'd4;
        endcase
      end
      // ack/clear pending byte via GO write bit4
      if (cfg_we && cfg_addr == 4'd7 && cfg_wdata[4]) rx_have <= 1'b0;
      if (mode == 2'd0 && rx_en && step != 3'd4) step <= 3'd4;
    end
  end

endmodule
