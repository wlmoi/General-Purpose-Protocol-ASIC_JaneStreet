## How it works

This is a programmable digital protocol engine with four independent execution
contexts sharing 256 x 16-bit host-loaded program storage. A deterministic
round-robin scheduler grants one context per enabled clock, so each context
executes at most one instruction every four core clocks.

Each context has a program counter, X/Y registers, a receive shift register,
a wait counter, and a host-configured output ownership mask. Masks must be
disjoint. Instructions support immediate/literal loads, arithmetic and shifts,
conditional branches, synchronized GPIO reads, sampled serial bits, bounded
cycle waits, pin-level waits, push-pull outputs, open-drain outputs, and halt.
GPIO updates affect only the issuing context's assigned pins.

Protocol behavior is firmware rather than dedicated UART/SPI/I2C hardware.
The integrated RTL regressions demonstrate UART 8N1 transmit and receive,
SPI mode-0 byte transfers, and single-master I2C writes with ACK sampling,
NACK-to-STOP handling, and clock stretching. A combined program demonstrates
all four contexts operating concurrently.

Program storage is a compact single-read-port synthesizable register array,
not an integrated SRAM macro. The concurrent demo uses 245/256 words. Local
IHP synthesis estimates 43.8% of the supplied core area; the full updated
physical/GDS flow still needs validation. See [area evidence](AREA_TIMING.md).

## How to test

From the repository root, with Python 3.11+, Icarus Verilog, and `vvp` on PATH:

```text
python -m unittest discover -s test -p "test_*.py" -v
python -m tools.build_demo --output build/demo
```

The first command runs model/host tests and RTL regressions. RTL tests load
and read back the full program image through the external SPI pins, compare
execution against the Python model every clock, and decode protocol waveforms.
The second command generates `program.hex` and `contexts.json` for a four-context
demo. Defaults are test timing parameters; choose timing for the attached devices.

Reset with `rst_n` low. Reset pauses the core, halts every context, clears
ownership masks, and releases GPIO. Program storage is not initialized by
reset: load every instruction and literal reachable by your program before
starting it. Configure pin masks and entry points while paused, start the
contexts, then enable execution. See [host interface](HOST_INTERFACE.md)
for the SPI register map and Python driver example.

`ena` pauses execution and releases physical GPIO when low. A software pause
preserves output levels/enables; a host STOP releases the selected contexts'
pins. HALT preserves outputs, allowing UART idle and SPI chip-select states.

## External hardware

The organizer describes digital pins with 3.3 V I/O on the Tiny Tapeout demo
board. The host uses `ui[0]` for CS_n, `ui[1]` for SCLK, `ui[2]` for MOSI,
and `uo[0]` for MISO, leaving all eight bidirectional pins for protocols.
Use a 3.3 V-compatible host and peripheral interfaces with a common ground.

The generated demo uses UART RX on `uio[0]`, UART TX on `uio[1]`, I2C SDA/SCL
on `uio[2:3]`, and SPI SCK/MOSI/MISO/CS_n on `uio[4:7]`. These are firmware
assignments, not fixed-function pins. UART here uses logic levels; other
physical interfaces require suitable external transceivers.

I2C requires external pull-ups on SDA and SCL to the compatible I/O supply.
Resistor values must be selected for bus capacitance, rise time, and sink-current
limits; the simulation's ideal pull-ups do not validate physical resistor
values. No other external component is required by the RTL tests.
See [GPIO and board wiring](GPIO.md) for the complete connection table.

## Design priorities and limitations

Organizer feedback prioritizes flexibility, architectural novelty, and
verification quality without fixed judging weights. UART, SPI, and I2C are
the required protocol coverage. See [organizer guidance](DESIGN_PRIORITIES.md).

The supplied firmware handles one byte/frame/transaction at a time. UART
parity/framing-error detection, other SPI modes, I2C reads and multi-master
arbitration, automatic pin-wait timeouts, and streaming FIFOs remain future
work. A stuck pin wait can be interrupted using host STOP. Formal proof,
SRAM macro integration, area/timing closure, and board measurements remain
unverified. See [verification](VERIFICATION.md) and [implementation](IMPLEMENTATION.md).
