# Implementation status

The integrated top is `tt_um_janestreet_protocol_engine` in `src/jane_top.v`,
with `src/program_host.v` providing its synchronized mode-0 SPI transport.
It implements four deterministic round-robin contexts; host-loadable 256 x
16-bit storage; X/Y and receive registers; full-byte cycle waits and pin waits;
conditional branches; masked push-pull/open-drain GPIO; synchronized inputs;
halt, stop/restart, status, and sticky errors. GPIO activity is no longer
modified by the earlier hardening activity accumulator.

The host can load/read back all 512 program bytes, configure disjoint output
ownership, and start contexts at different entry points. Live program writes
and ownership changes are rejected. Reset halts execution and releases pins.
HALT preserves outputs; host STOP releases them. Program memory is not reset
or initialized and is not an SRAM macro. It has one shared read port; host readback
requires software pause and literal loads consume two context grants.

Firmware and regression coverage demonstrate UART TX/RX, SPI mode-0 byte
transfers, and single-master I2C writes with ACK/NACK and stretching. A packed
four-context program demonstrates concurrent operation. See [protocol scope](PROTOCOLS.md).

Python tools provide validated assembly encoders, a cycle model, a transport-
independent host driver, and demo-image generation. Tests compare RTL state
against the model every execution clock and independently inspect serial
waveforms. The CI test workflow runs both stdlib regressions and the pin-only
cocotb test. See [verification status](VERIFICATION.md) for actual run results.

Legacy standalone modules (`thread.v`, `host_if.v`, `prog_mem.v`, `dm.v`,
`gpio.v`, `bit_engine.v`, `edge_units.v`, `fifo.v`, and `timing.v`) remain
unconnected and are not in the Tiny Tapeout source list.

Local IHP-library synthesis now reports 395106.8436 um^2 of mapped cells,
about 43.8% of the supplied 6x4 core area. The comparable previous RTL maps
to 898632.0630 um^2. This is a synthesis estimate, not physical closure.
See [area results](AREA_TIMING.md).

Still unverified or unimplemented: formal proof, integrated SRAM macros,
area/timing closure, a physical/GDS run for this revision, board testing,
streaming FIFOs, automatic pin-wait timeouts, trace capture, and advanced
protocol modes. Earlier GDS-flow progress does not validate these RTL changes.
