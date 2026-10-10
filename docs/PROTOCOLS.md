# Protocols

`tools/protocols.py` generates firmware for the same integrated instruction
engine. The RTL has no UART-, SPI-, or I2C-specific datapath.

| Generator | Demonstrated behavior | Limits |
|---|---|---|
| uart_tx | One 8N1 frame, LSB first, programmable pin/period, idle-high retained | No continuous FIFO stream or parity |
| uart_rx | Idle-high arming, qualified start center, eight data-center samples, checked stop center, sticky framing status | One 8N1 frame per start command |
| spi_transfer | Mode 0, MSB-first byte, CS_n, programmable pins/period, MISO sampling | One byte; modes 1..3 not supplied |
| i2c_write | START, 7-bit address+W, one data byte, ACK sampling, STOP; SCL-high waits allow stretching | Single master, no read or arbitration; host STOP interrupts stuck pin waits |

I2C branches to STOP on a NACK rather than transmitting the next byte. ACK bits
are shifted into the receive register; zero means the completed address/data
phases were acknowledged. A nonzero result indicates NACK; it does not identify
whether the address or data was rejected. No automatic retry is performed.

`python -m tools.build_demo` packs four contexts into one 256-word image: UART
RX, UART TX, I2C write, and SPI transfer. The combined RTL regression executes
all four concurrently (254/256 words) and checks received results and preservation of other
contexts' outputs. UART TX/RX, SPI transfer, I2C ACK/stretching, and I2C NACK
handling also have separate wire-level checks.
The demo defaults to 115200-baud UART timing at 50 MHz. Its `contexts.json`
records the core clock, requested baud, actual baud, and UART grant period.
For a 12 MHz FPGA clock, generate with `--clock-hz 12000000 --uart-baud 115200`.

## UART receive acceptance

UART RX first observes idle high, then detects a low start. At half a bit
period it checks that the line remains low. A short start pulse returns to
idle detection. Valid starts lead to eight LSB-first data samples at bit centers.
The stop-bit center must be high. A low stop center executes SIGNAL_ERROR and
HALT, exposing a sticky error through the host STATUS register.

Wait for the context's running bit to clear and inspect its error bit before
accepting RECEIVED as a valid byte. RESTART clears the receive and error state
for the next frame. STOP provides host control over a prolonged idle-line wait.

`uart_bit_grants(clock_hz, baud_rate, receive=True)` selects an even grant count
for both TX and RX. The selected baud rate is within a 2% budget of the request.
At 50 MHz, 108 grants yields approximately 115741 baud for a 115200-baud peer.
Use a core clock and period supported by the attached device and validate
electrical timing on the board. Tests cover start glitches, framing status,
0x00/0xFF/0x55/0xAA data, GPIO reassignment, asynchronous start phases, and
peer bit periods from 424 to 440 clocks against a 432-clock receiver.

These are simulation demonstrations, not board or protocol-certification
results. Electrical interfaces and exact timing must be checked for the
selected peer. JTAG, SWD, CAN, USB, Manchester, and Ethernet are not demonstrated
by this integrated implementation.
