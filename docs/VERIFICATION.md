# Verification

The baseline RTL compile is `iverilog -g2012 -Isrc -o sim.out src/*.v test/tb.v`. `test/test.py` checks deterministic reset outputs. `tools/reference_model.py` models the integrated instruction subset and `test/test_reference_model.py` checks round-robin progression and halt behavior.

Verilator, Yosys, formal checks, protocol-level tests, and gate-level tests have not been run in the current Windows environment.
