<div align="center">

# Programmable UART and Protocol Engine

**Precise serial timing. Programmable behavior. Verified hardware.**

A four-context digital ASIC developed for the Jane Street protocol emulator competition.

[![RTL tests](https://github.com/wlmoi/General-Purpose-Protocol-ASIC_JaneStreet/actions/workflows/test.yaml/badge.svg?branch=main)](https://github.com/wlmoi/General-Purpose-Protocol-ASIC_JaneStreet/actions/workflows/test.yaml)
[![GDS and precheck](https://github.com/wlmoi/General-Purpose-Protocol-ASIC_JaneStreet/actions/workflows/gds.yaml/badge.svg?branch=main)](https://github.com/wlmoi/General-Purpose-Protocol-ASIC_JaneStreet/actions/workflows/gds.yaml)
[![Datasheet](https://github.com/wlmoi/General-Purpose-Protocol-ASIC_JaneStreet/actions/workflows/docs.yaml/badge.svg?branch=main)](https://github.com/wlmoi/General-Purpose-Protocol-ASIC_JaneStreet/actions/workflows/docs.yaml)
[![FPGA build](https://github.com/wlmoi/General-Purpose-Protocol-ASIC_JaneStreet/actions/workflows/fpga.yaml/badge.svg?branch=main)](https://github.com/wlmoi/General-Purpose-Protocol-ASIC_JaneStreet/actions/workflows/fpga.yaml)

[Background](#background) | [UART](#uart-reliability) | [Architecture](#architecture) | [Quick start](#quick-start) | [Documentation](#documentation)

</div>

---

## Background

Jane Street builds FPGA and ASIC systems for latency-sensitive trading infrastructure. Its performance engineering work emphasizes precise measurement, deterministic behavior, and hardware acceleration. The firm develops **Hardcaml**, an open-source OCaml library for describing RTL and integrating hardware simulation and testing. These practices connect software engineering discipline with the physical realities of digital hardware. [Performance engineering at Jane Street](https://www.janestreet.com/performance-engineering/) and [hardware engineering](https://www.janestreet.com/join-jane-street/position/8646893002/).

The [Jane Street protocol emulator ASIC competition](https://blog.janestreet.com/protocol-emulator-asic-competition/) brings that engineering mindset to a compact, reprogrammable chip. Its objective is to implement UART, SPI, and I²C through firmware, with flexibility to support additional protocols after fabrication.

This project starts with **reliable programmable UART communication** and extends the same execution architecture to SPI and I²C. Verilog defines the hardware. Python provides the assembler, program loader, reference model, and verification tools. Tiny Tapeout supplies the path from RTL to a manufacturable chip.

## Engineering highlights

| Focus | Result |
|:--|:--|
| **UART reliability** | Qualified start bits, centered data sampling, stop-bit validation, and host-visible framing status |
| **Programmability** | Reloadable firmware, four execution contexts, and configurable GPIO ownership |
| **Verification** | 29 regression tests with differential RTL comparison and independent serial waveform checks |
| **Area efficiency** | Approximately 56% reduction in local mapped cell area through compact storage and a shared read port |
| **Implementation evidence** | Recorded SG13G2 GDS and precheck success, a routed FPGA bitstream, and a CMOS5L competition flow |

## UART reliability

The UART firmware implements **8N1**, with eight data bits transmitted least significant bit first and a high idle level.

| Behavior | Implementation and coverage |
|:--|:--|
| Start-bit qualification | Reception arms on idle high and checks the start-bit center |
| Glitch recovery | Short start pulses return the receiver to idle detection |
| Data capture | Eight samples use a deterministic four-clock context cadence |
| Framing status | A low stop-bit center sets the context's sticky error flag and completes the receive program |
| Host acceptance | Read `STATUS` after completion and accept `RECEIVED` when the context error bit is clear |
| Timing selection | `uart_bit_grants()` selects a representable bit period within a 2% baud-rate budget |
| Waveform tests | Data patterns, pin assignments, start phases, baud mismatch, and transmit timing boundaries |

At a configured 50 MHz ASIC core clock, **108 grants per bit** produces approximately **115,741 baud**, within 0.47% of 115,200 baud. At a 12 MHz FPGA clock, **26 grants per bit** gives approximately **115,385 baud**. Generate timing from the clock supplied to the board and use the RX-compatible period for a shared transmit/receive setting.

```python
from tools.protocols import uart_bit_grants, uart_rx, uart_tx

period = uart_bit_grants(50_000_000, 115_200, receive=True)
rx_program = uart_rx(pin=0, bit_grants=period)
tx_program = uart_tx(0xA5, pin=1, bit_grants=period)
```

Each supplied UART program handles one frame per start command. Host STOP provides control over an idle-line wait. The [protocol guide](docs/PROTOCOLS.md) documents timing, framing status, and the roadmap for streaming and additional frame formats.

## Architecture

```mermaid
flowchart LR
    Host["Host controller"] --> Loader["SPI loader and control"]
    Loader --> Memory["256 x 16-bit program store"]
    Loader --> Contexts["4 execution contexts"]
    Memory --> Contexts
    Contexts --> GPIO["Owned GPIO outputs"]
    GPIO --> Pins["8 protocol pins"]
    Pins --> Sync["Input synchronizers"]
    Sync --> Contexts
```

Four contexts share a deterministic round-robin scheduler. Each receives one grant every four enabled core clocks and maintains its own program counter, registers, receive data, and wait state. Disjoint output masks keep concurrent GPIO updates within each context's ownership.

| Resource | Configuration |
|:--|:--|
| Program storage | **256 x 16-bit words**, totaling 512 bytes |
| Memory access | One shared read port with paused host readback |
| GPIO | Eight bidirectional pins with synchronized inputs |
| Output modes | Masked push-pull and open-drain |
| Host interface | SPI mode 0 with load, readback, configure, start, stop, and status |
| Concurrent firmware | **254 of 256 words** for UART RX, UART TX, SPI, and I²C |
| Tiny Tapeout allocation | **6 x 4 tiles** |
| Configured core clock | **50 MHz** |

Reset establishes a halted state and releases GPIO. The host loads reachable instructions, assigns ownership, and selects entry points before starting execution. Board reselection includes a fresh program load after the design's power cycle.

## Protocol coverage

| Firmware | Demonstration | Example GPIO assignment |
|:--|:--|:--|
| UART receiver | Qualified 8N1 reception with framing status | `uio[0]` RX |
| UART transmitter | 8N1 transmission with a complete stop-bit hold | `uio[1]` TX |
| I²C controller | Single-master write, ACK sampling, NACK-to-STOP, and clock stretching | `uio[2]` SDA, `uio[3]` SCL |
| SPI controller | Mode-0 byte transfer with transmit and receive | `uio[4]` SCK, `uio[5]` MOSI, `uio[6]` MISO, `uio[7]` CS_n |

The generated demo runs all four contexts concurrently. Pin assignments are firmware-configurable through the [host interface](docs/HOST_INTERFACE.md).

## Verification and implementation

The verification flow combines a Python cycle model, clock-by-clock RTL comparison, reproducible randomized programs, independent protocol peers, and runtime ownership assertions. The pin-only cocotb regression exercises loading, readback, GPIO execution, control, and protection through the external interface.

| Evidence | Reference |
|:--|:--|
| Expanded UART and protocol regression | [Verification approach and cases](docs/VERIFICATION.md) |
| Recorded RTL CI success | [Test run for commit 269b380](https://github.com/wlmoi/General-Purpose-Protocol-ASIC_JaneStreet/actions/runs/37646552427) |
| Recorded physical-flow CI success | [SG13G2 GDS, precheck, gate-level test, and viewer for commit 269b380](https://github.com/wlmoi/General-Purpose-Protocol-ASIC_JaneStreet/actions/runs/37646552561) |
| SG13G2 reference mapped cell area | **395,106.8436 square micrometers**, approximately **43.8%** of the supplied core area |
| Area methodology | [Synthesis measurements and physical-flow evidence](docs/AREA_TIMING.md) |

The linked GitHub runs identify the revision and SG13G2 flow they validate. Live badges track `main`. The expanded 29-test suite passes locally for both ASIC and FPGA storage. The current competition workflow targets CMOS5L, with fresh hardening and precheck evidence produced by its next CI run.

Development milestones include formal proof, SRAM macro integration, detailed post-route timing analysis, and board validation. [Implementation status](docs/IMPLEMENTATION.md) tracks this work.

## GitHub Actions

**Every workflow is enabled for pushes, pull requests, and manual dispatch.**

| Workflow | Deliverable |
|:--|:--|
| [test](.github/workflows/test.yaml) | Reference-model and RTL regressions plus pin-only cocotb |
| [docs](.github/workflows/docs.yaml) | Tiny Tapeout metadata validation and a PDF datasheet |
| [gds](.github/workflows/gds.yaml) | ASIC hardening, precheck, gate-level simulation, and viewer publication |
| [fpga](.github/workflows/fpga.yaml) | ICE40UP5K synthesis, placement, routing, and bitstream generation |

Precheck and gate-level simulation consume the GDS build artifact. The viewer publishes from the default branch. The FPGA build maps program storage to block RAM through `JP_FPGA_SYNC_MEMORY`. A falling-edge read prepares instructions for rising-edge execution. The local Tiny Tapeout board build passed synthesis, placement, routing, and bitstream packing at a **12 MHz** target, using **47%** of ICE40UP5K logic cells and **one block RAM**. Its post-route clock estimate is **16.64 MHz**. FPGA run artifacts capture the build logs and generated bitstream.

## Quick start

Use **Python 3.11+**, **Icarus Verilog**, and `vvp` on `PATH`. Run from the repository root.

```bash
python -m pip install -r test/requirements.txt
python -m unittest discover -s test -p "test_*.py" -v
python -m tools.run_cocotb
python -m tools.build_demo --output build/demo
```

The demo defaults to **115,200-baud UART timing at 50 MHz** and writes `build/demo/program.hex` plus `build/demo/contexts.json`. The configuration records the requested and actual baud rates. Connect the [Python host driver](tools/host.py) to a SPI transport, load the image, verify readback, and configure the four contexts.

Generate matching UART timing for a 12 MHz FPGA clock with:

```bash
python -m tools.build_demo --clock-hz 12000000 --uart-baud 115200 --output build/demo-fpga
```

## Tiny Tapeout integration

The project retains the standard Tiny Tapeout top-level interface, a source manifest in `info.yaml`, and a project datasheet in `docs/info.md`. ASIC builds use the official `ihp-cmos5l` actions, the `ihp-sg13cmos5l` PDK, and matching CMOS5L gate-level simulation models. The six-by-four tile allocation follows the competition's published starting footprint. [Competition rules and template](https://blog.janestreet.com/protocol-emulator-asic-competition/).

| Connection | Board requirement |
|:--|:--|
| Host SPI | `ui[0]` CS_n, `ui[1]` SCLK, `ui[2]` MOSI, `uo[0]` MISO |
| Digital signaling | Compatible 3.3 V interfaces with a common ground |
| I²C | External SDA and SCL pull-ups sized for capacitance, rise time, and sink current |
| External interface adaptation | Suitable level shifters or transceivers for the attached device |
| Hardware acceptance | Validate electrical timing and pull-up values on the selected board |

See the [wiring guide](docs/GPIO.md) before connecting peripherals.

## Documentation

| Design | Programming and validation |
|:--|:--|
| [Project datasheet](docs/info.md) | [Host programming guide](docs/HOST_INTERFACE.md) |
| [Architecture](docs/ARCHITECTURE.md) | [Instruction set](docs/ISA.md) |
| [Protocol firmware](docs/PROTOCOLS.md) | [Verification](docs/VERIFICATION.md) |
| [GPIO and wiring](docs/GPIO.md) | [Area and physical flow](docs/AREA_TIMING.md) |
| [Implementation status](docs/IMPLEMENTATION.md) | [Organizer priorities](docs/DESIGN_PRIORITIES.md) |

---

<div align="center">

**William Anthony**

[Portfolio](https://wlmoi.vercel.app) | [LinkedIn](https://www.linkedin.com/in/wlmoi/) | [Resume](https://wlmoi.vercel.app/resume?print=1)

Built with [Tiny Tapeout](https://tinytapeout.com).

</div>

Verilog syntax assistance uses AI tooling.
