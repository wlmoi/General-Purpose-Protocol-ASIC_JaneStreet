# Protocols

`tools/protocols.py` generates firmware for the same integrated instruction
engine. The RTL has no UART-, SPI-, or I2C-specific datapath.

| Generator | Demonstrated behavior | Limits |
|---|---|---|
| uart_tx | One 8N1 frame, LSB first, programmable pin/period, idle-high retained | No continuous FIFO stream or parity |
| uart_rx | Start-low wait, eight center samples, stop-high wait; byte in receive register | One frame; no false-start rejection or parity/framing-error reporting |
| spi_transfer | Mode 0, MSB-first byte, CS_n, programmable pins/period, MISO sampling | One byte; modes 1..3 not supplied |
| i2c_write | START, 7-bit address+W, one data byte, ACK sampling, STOP; SCL-high waits allow stretching | Single master, no read or arbitration; host STOP interrupts stuck pin waits |

I2C branches to STOP on a NACK rather than transmitting the next byte. ACK bits
are shifted into the receive register; zero means the completed address/data
phases were acknowledged. A nonzero result indicates NACK; it does not identify
whether the address or data was rejected. No automatic retry is performed.

`python -m tools.build_demo` packs four contexts into one 512-word image: UART
RX, UART TX, I2C write, and SPI transfer. The combined RTL regression executes
all four concurrently and checks received results and preservation of other
contexts' outputs. UART TX/RX, SPI transfer, I2C ACK/stretching, and I2C NACK
handling also have separate wire-level checks.

These are simulation demonstrations, not board or protocol-certification
results. Electrical interfaces and exact timing must be checked for the
selected peer. JTAG, SWD, CAN, USB, Manchester, and Ethernet are not demonstrated
by this integrated implementation.
