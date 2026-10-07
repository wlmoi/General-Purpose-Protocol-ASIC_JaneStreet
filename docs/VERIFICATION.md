# Verification

The local stdlib suite has passed 18 tests using Python 3.11 and Icarus Verilog:

```text
python -m unittest discover -s test -p "test_*.py" -v
```

Eight tests cover model/host behavior: round-robin and halt; all supported
branch conditions and signed offset boundaries; 255-grant waits; enable
freezing; literal wrap; masked open-drain updates; rejected encodings;
demo size/ownership; host frame endianness; and readback/transport failures.

Ten RTL regressions use `test/integration_tb.v`. Each simulation loads and
reads back all 512 program words through the external SPI pins, including
high byte-address bits and wraparound. No hierarchical memory writes are used.
Execution is compared every clock against `tools/reference_model.py`: scheduler
slot, all PCs, X/Y, receive registers, wait counters, halted/errors, output
values, and output enables. The input synchronizer pipeline is modeled too.

RTL cases cover randomized programs with reproducible seed 20261007, four
contexts, randomized external pins and `ena` pauses; branch/literal boundaries;
UART TX wire decoding and UART RX reception; SPI MOSI edge decoding and MISO
reception; I2C address/data/ACK wire decoding with physical SCL stretching;
NACK-to-STOP; all four protocol contexts concurrently; live-write protection;
stop/restart/reset; and overlapping-mask rejection and reassignment.

Simulation safety invariants check known outputs, disabled output release,
output enables confined to owned pins, and pairwise-disjoint ownership. These
are runtime assertions, not formal proofs. Randomized differential testing
checks model consistency but is not exhaustive; independent wire-level checks
help catch shared model/RTL misunderstandings.

`test/test.py` is a pin-only cocotb test that programs the chip, reads memory
back, runs a GPIO program, rejects a live write, and releases pins on STOP.
The CI workflow runs the stdlib suite before the existing cocotb flow. A
matching gate netlist can use that pin-only test without hierarchical accesses.
The local pin-only cocotb test passed with cocotb 2.0.1 and Icarus Verilog 12.0
using `python -m tools.run_cocotb` (the Python runner does not require Make).

Formal properties have not been proved. No gate-level netlist, SRAM macro,
physical timing, DRC/LVS, GDS flow, or board test was run for this revision.
UART error cases, streaming traffic, other SPI modes, I2C reads/arbitration,
and electrical timing remain outside the demonstrated coverage.
