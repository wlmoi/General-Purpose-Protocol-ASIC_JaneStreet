![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# JaneStreet Programmable Protocol Engine

Four programmable execution contexts share a compact 256-word instruction memory
and eight protocol GPIO pins on Tiny Tapeout. Firmware demonstrates UART
transmit/receive, SPI mode-0 transfers, and I2C writes using the same execution
architecture. Disjoint output masks allow the contexts to run concurrently.

The SPI host interface supports program loading/readback, entry points,
start/stop, ownership, and status. GPIO supports synchronized inputs,
masked push-pull outputs, and open-drain outputs. Differential regressions
compare RTL against a Python cycle model, with separate serial wire checks.

```text
python -m unittest discover -s test -p "test_*.py" -v
python -m tools.build_demo --output build/demo
```

Use Python 3.11+, Icarus Verilog, and vvp on PATH. The stdlib tests need no pip
packages. The existing cocotb flow additionally uses `test/requirements.txt`.

- [Project datasheet](docs/info.md)
- [Host interface and programming](docs/HOST_INTERFACE.md)
- [Implemented ISA](docs/ISA.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Protocol demonstrations and limits](docs/PROTOCOLS.md)
- [Verification evidence](docs/VERIFICATION.md)
- [GPIO and board wiring](docs/GPIO.md)
- [Organizer priorities](docs/DESIGN_PRIORITIES.md)

This revision passes RTL simulation and a local mapped-netlist functional test.
IHP-library synthesis estimates 43.8% core utilization; see [area evidence](docs/AREA_TIMING.md). SRAM macro integration, formal
proof, physical area/timing, a new GDS flow, and board validation remain
outstanding. See [implementation status](docs/IMPLEMENTATION.md).

Tiny Tapeout is an educational project for manufacturing custom chips.
See [Tiny Tapeout](https://tinytapeout.com) for board and shuttle information.

## Project and author

This project is part of the work of [William Anthony](https://www.linkedin.com/in/wlmoi/).

- [Portfolio](https://wlmoi.vercel.app)
- [LinkedIn](https://www.linkedin.com/in/wlmoi/)
- [Instagram](https://www.instagram.com/wlmoi/)
- [Resume](https://wlmoi.vercel.app/resume?print=1)
