# GPIO and board wiring

The host is on dedicated Tiny Tapeout pins; protocol firmware can use all eight
bidirectional pins. Outputs use active-high output enables. `ena=0` forces all
physical bidirectional output enables low, while retaining register state.

| Pin | Generated demo connection | Direction |
|---|---|---|
| ui[0] | Host SPI CS_n | Input, idle high |
| ui[1] | Host SPI SCLK | Input, mode 0 idle low |
| ui[2] | Host SPI MOSI | Input |
| ui[7:3] | Reserved | Input, ignored |
| uo[0] | Host SPI MISO | Output, zero while CS inactive |
| uo[1] | Core enabled | Output |
| uo[5:2] | Contexts 3:0 running | Output |
| uo[7:6] | Contexts 1:0 sticky errors | Output; all four errors available in host status |
| uio[0] | UART RX | Input |
| uio[1] | UART TX | Push-pull output |
| uio[2] | I2C SDA | Open-drain bidirectional, external pull-up |
| uio[3] | I2C SCL | Open-drain bidirectional, external pull-up |
| uio[4] | SPI SCK | Push-pull output |
| uio[5] | SPI MOSI | Push-pull output |
| uio[6] | SPI MISO | Input |
| uio[7] | SPI CS_n | Push-pull output |

Connect a common ground and compatible digital logic levels. The organizer's
board guidance specifies 3.3 V I/O. The UART example requires logic-level RX/TX;
an RS-232 or other electrically different link requires an external transceiver.
I2C requires pull-ups on both SDA and SCL. Select and record resistor values
against the actual bus capacitance, target speed, and device sink-current
limits before a board demonstration. No physical resistor values or bus rise
times have been validated by the RTL regressions.

Firmware pin indices can be changed. Assign disjoint output ownership masks
through host register 10: the demo uses masks 0x00, 0x02, 0x0C, and 0xB0 for
contexts 0..3. Mask 0x00 is valid for an input-only context. Changing a mask
while paused releases pins from that context's previous mask. Overlapping
masks or changes while enabled are rejected with a sticky context error.

GPIO inputs have a two-flop synchronizer. Open-drain firmware drives zero
or releases; a released input's high level comes from the external pull-up.
The host STOP command releases owned pins; firmware HALT retains their state.

Board references supplied by the organizer:

- [Demo board specification](https://tinytapeout.com/specs/pcb-etr/)
- [Pmod pinout conventions](https://tinytapeout.com/specs/pinouts/)
- [External-component example: audio Pmod](https://github.com/MichaelBell/tt-audio-pmod)

The table above is the chip's logical mapping. Map it to the actual selected
board/header before wiring; it does not claim automatic compatibility with
any standard Pmod connector layout.
