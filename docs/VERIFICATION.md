# Verification

The local stdlib suite has passed 29 tests using Python 3.11 and Icarus Verilog
for both ASIC storage and the FPGA block-RAM read implementation:

```text
python -m unittest discover -s test -p "test_*.py" -v
```

Twelve tests cover model/host behavior: round-robin and halt; all supported
branch conditions and signed offset boundaries; 255-grant waits; enable
freezing; literal wrap; masked open-drain updates; rejected encodings;
demo size/ownership; RTL/tool geometry consistency; literal pause/restart;
host frame endianness; readback/transport failures; UART baud selection and
firmware period bounds; and explicit firmware error signaling.

Seventeen RTL regressions use `test/integration_tb.v`. Each simulation loads and
reads back all 256 program words through the external SPI pins, including
high byte-address bits and wraparound. No hierarchical memory writes are used.
Execution is compared every clock against `tools/reference_model.py`: scheduler
slot, all PCs, X/Y, receive registers, wait counters, halted/errors, output
values, and output enables. The input synchronizer pipeline is modeled too.

RTL cases cover randomized programs with reproducible seed 20261007, four
contexts, randomized external pins and `ena` pauses; branch/literal boundaries;
UART TX wire decoding and UART RX reception; SPI MOSI edge decoding and MISO
reception; I2C address/data/ACK wire decoding with physical SCL stretching;
NACK-to-STOP; all four protocol contexts concurrently; live-write protection;
stop/restart/reset; and overlapping-mask rejection and reassignment; rejected live memory reads
and out-of-range host addresses. Immediate GPIO operations are also included
in randomized differential tests.

Simulation safety invariants check known outputs, disabled output release,
output enables confined to owned pins, and pairwise-disjoint ownership. These
are runtime assertions, not formal proofs. Randomized differential testing
checks model consistency but is not exhaustive; independent wire-level checks
help catch shared model/RTL misunderstandings.

Expanded UART cases check idle arming, short start-pulse recovery, low stop-bit
framing status through the host, 0x00/0xFF/0x55/0xAA patterns, programmable pins,
start phases, RX grant counts from 4 to 256, and TX counts from 3 to 257.
An independent peer varies its bit period from 424 to 440 clocks against a
432-clock receiver. The firmware sets a sticky error and halts on a low stop.

Set JP_TEST_FPGA=1 when running the stdlib suite to compile with
JP_FPGA_SYNC_MEMORY. CI runs both variants and compares each against the same
cycle model, covering host readback, literals, reset, protection, and the
concurrent UART/SPI/I2C demo.

## Local FPGA implementation evidence

The complete Tiny Tapeout FabricFox wrapper passed synthesis, placement,
routing, and bitstream packing for ICE40UP5K on 2026-10-10. The local build
used Yosys 0.33, nextpnr-ice40 0.6, seed 10, the official FabricFox v2 pin
constraints, and a 12 MHz timing target. The packaged routing tool used a
workspace-relative device-database lookup.

| Metric | Local routed result |
|---|---:|
| Logic cells | 2488 / 5280, approximately 47% |
| Program block RAM | 1 / 30 |
| Post-route clock estimate | 16.64 MHz |
| Timing target | 12 MHz, passed |
| Packed bitstream | 104090 bytes |

Logs, the JSON netlist, routed ASC, and packed binary are local artifacts
under `build/fpga-check/`. CI uses Tiny Tapeout's official FPGA action and
OSS CAD Suite, providing a separate build result for its tool versions.
The workflow checks that the bitstream is present and the netlist contains
exactly one program block RAM.

Protocol timing on an FPGA uses its supplied core clock. At 12 MHz, 26 grants
per UART bit gives approximately 115385 baud. Use uart_bit_grants with the
actual clock when generating a program for a board.

`test/test.py` is a pin-only cocotb test that programs the chip, reads memory
back, runs a GPIO program, rejects a live write, and releases pins on STOP.
The CI workflow runs the stdlib suite before the existing cocotb flow. A
matching gate netlist can use that pin-only test without hierarchical accesses.
The local pin-only cocotb test passed with cocotb 2.0.1 and Icarus Verilog 12.0
using `python -m tools.run_cocotb` (the Python runner does not require Make).

The locally mapped IHP netlist also passed the pin-only cocotb test using
zero-delay functional cell models generated from the mapping Liberty library:

```text
python -m tools.run_cocotb --netlist build/area/compact.v --cell-models build/area/compact-cells-functional.v
```

GitHub subsequently passed the Tiny Tapeout SG13G2 GDS build, precheck, gate-level
test, and viewer for commit `269b380`:
[physical-flow and gate-level results](https://github.com/wlmoi/General-Purpose-Protocol-ASIC_JaneStreet/actions/runs/37646552561).
The [RTL test workflow](https://github.com/wlmoi/General-Purpose-Protocol-ASIC_JaneStreet/actions/runs/37646552427)
also passed for that commit. These results establish CI success for the linked
revision; current workflow badges show later runs.

Formal properties have not been proved. SRAM macro integration, SDF timing
simulation, and board testing remain pending. See [area evidence](AREA_TIMING.md)
for the distinction between local mapping estimates and the physical-flow run.
The current ASIC workflow targets the competition's CMOS5L template and
matching gate-level models. Fresh CMOS5L CI evidence is a physical-flow milestone.
Streaming traffic, parity, additional SPI modes, I2C reads/arbitration, and
board electrical timing are development milestones.
