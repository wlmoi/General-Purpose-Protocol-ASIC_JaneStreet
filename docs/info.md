<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

The design contains four round-robin execution slots. Each enabled clock
selects the next slot and executes one instruction from its 512-word program
array. The current integrated instruction subset provides immediate loads,
basic ALU operations, branches, waits, GPIO reads, output updates, and halt.
The output also exposes an activity accumulator so the clock and input pins
remain physically connected in the Tiny Tapeout hardening flow.

## How to test

Compile and run the RTL smoke test from the repository root:

```text
iverilog -g2012 -Isrc -o sim.out src/*.v test/tb.v
vvp sim.out
```

Assert `rst_n` low for reset, then set `ena` high. The current prototype has
no host program-loader protocol; the program array is initialized to zero in
simulation. The Python assembler and reference model are in `tools/`.

## External hardware

No external hardware is required for the RTL smoke test.
