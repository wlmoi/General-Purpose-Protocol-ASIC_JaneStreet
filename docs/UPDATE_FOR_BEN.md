# Draft progress update for Ben

Subject: JaneStreet programmable protocol engine — UART and verification update

Hi Ben,

Thanks for clarifying the priorities. I’m focusing on a programmable UART
implementation, with SPI and I2C running on the same architecture to cover
the required protocols.

Since my last update, I’ve integrated a host SPI program loader and four
independent execution contexts with configurable, disjoint output pin masks.
In RTL simulation, the firmware demonstrates UART 8N1 transmit and receive,
SPI mode-0 byte transfers, and single-master I2C writes with ACK sampling,
NACK-to-STOP handling, and clock stretching. A combined demo runs the four
contexts concurrently and uses 335 of the 512 available instruction words.

Verification now includes a Python cycle reference model, clock-by-clock
differential comparison with the RTL, reproducible randomized programs and
inputs, independent protocol waveform checks, and runtime safety assertions.
The local suite passed 18 tests, plus a pin-only cocotb test for programming,
readback, GPIO execution, and protection/control behavior.

I’ve documented the pin assignments and external interface requirements,
including the I2C pull-ups and compatible digital logic levels. Actual pull-up
values and electrical timing still need validation against the chosen board
and attached devices.

The earlier GDS-flow result predates these changes, so I haven’t yet claimed
physical-flow closure for this revision. Program storage is currently a
synthesizable array; SRAM macro integration and Tiny Tapeout precheck remain
pending. The assertions are simulation checks, and formal proof is also
still pending.

My next priorities are to extend UART error-case verification, run the updated
physical flow and precheck, and follow the applicable Tiny Tapeout SRAM
template once the configuration is established.

Repository: https://github.com/wlmoi/General-Purpose-Protocol-ASIC_JaneStreet

Thanks,
William
