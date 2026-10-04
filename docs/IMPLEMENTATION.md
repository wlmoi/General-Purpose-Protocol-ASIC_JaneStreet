# Implementation Status

The current checked-in implementation compiles with Icarus using `src/*.v` and the Tiny Tapeout testbench. The integrated top is `tt_um_jonestreet_protocol_engine` in `src/jane_top.v`; it has four deterministic round-robin slots, 512 x 16-bit program storage, X/Y state, wait counters, GPIO input, output value/output-enable registers, branch, halt, ALU, and load-immediate operations.

`src/thread.v`, `host_if.v`, `prog_mem.v`, `dm.v`, `gpio.v`, `bit_engine.v`, `edge_units.v`, `fifo.v`, and `csr.v` are present as standalone RTL modules but are not connected to the current top. Their integration is future work, as are host programming, trace capture, reference-model co-simulation, assertions, synthesis, STA, place-and-route, DRC, LVS, and protocol firmware.
