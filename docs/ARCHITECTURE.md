# Architecture

The integrated design is `tt_um_janestreet_protocol_engine` in `src/jane_top.v`,
with the synchronized SPI register transport in `src/program_host.v`.
`src/top.v` is a compatibility wrapper. The Tiny Tapeout source list includes
only the integrated design, transport, and defines header.

Four contexts share 256 x 16-bit program storage. Each context has an 8-bit PC,
16-bit X/Y registers, a 16-bit serial receive register, an 8-bit wait counter,
a halted flag, a sticky error flag, and an 8-bit output ownership mask. Each
enabled core clock grants the next context, including halted/waiting contexts,
so other contexts' timing is independent of whether a neighbor is runnable.

Program storage has one shared asynchronous read port. Execution uses the
selected PC; paused host readback uses the host byte address. LDI consumes
two grants of its context: the first records the destination and advances
to the literal; the second loads the literal and advances again. Immediate
GPIO output instructions reduce firmware size without consuming X.

The FPGA workflow selects JP_FPGA_SYNC_MEMORY for a falling-edge synchronous
read. This maps program storage to one ICE40 block RAM and presents the next
instruction before rising-edge execution. Both variants pass the same cycle
reference model, host programming, and protocol waveform regressions.

The host loads and reads back program bytes while the core is paused. Reset does not reset
or initialize program memory; it disables execution and clears all context
and GPIO state. No boot firmware is implied. Host entry-point and restart
commands make every context independently programmable within shared memory.

All GPIO inputs pass through two flip-flops. Each output update merges only
the issuing context's ownership mask into shared value/enable registers.
Overlapping ownership is rejected by the host configuration interface. In
open-drain mode, zero drives low and one releases the line; the output value
for owned pins is always zero. Input pins need no output ownership allocation.

The serial receive register separates sampled data from X, allowing GPIO
output instructions to modify X while accumulating incoming bits. Both
MSB-first 16-bit shifting and LSB-first 8-bit shifting are supported.

Host configuration/control writes serialize with instruction retirement and
can stretch protocol timing. Load/configure/start while paused; avoid control
writes during time-sensitive transfers. Pin-level waits consume only that
context's grants and can wait indefinitely without blocking neighbors.

The legacy `host_if.v`, `thread.v`, `prog_mem.v`, `dm.v`, `gpio.v`,
`bit_engine.v`, `edge_units.v`, `fifo.v`, and `timing.v` are not integrated.
Their comments and constants describe earlier proposals, not supported ISA
or proven implementation behavior. See [ISA](ISA.md) for the implemented ISA.
