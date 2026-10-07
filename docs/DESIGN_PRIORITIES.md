# Design priorities from organizer feedback

Source: Ben's reply supplied by William. These are organizer clarifications,
not evidence that the current implementation meets the requirements.

## Competition scope

There is no fixed judging weighting. Flexibility is the main priority, together
with architectural novelty and the quality of verification and its write-up.
A smaller protocol set can be competitive when backed by a strong programmable
architecture, provided it covers **UART, SPI, and I2C**.

Multiple engines and independent contexts are allowed, with no specified count
requirement or limit. The current four-slot architecture is therefore within
the stated design space; its value still needs to be demonstrated.

## Electrical interface

Ben describes the chip interface as digital pins with 3.3 V I/O on the Tiny
Tapeout demo board. External pull-ups, transceivers, and other parts can connect
through the Pmod headers. Document all parts needed by each demonstrated
protocol, including supply voltage, connections, and component values.

References supplied by Ben:

- [Tiny Tapeout demo board specification](https://tinytapeout.com/specs/pcb-etr/)
- [Standard Pmod pinouts](https://tinytapeout.com/specs/pinouts/)
- [Audio Pmod example](https://github.com/MichaelBell/tt-audio-pmod)

These references are starting points for the eventual board wiring document;
no final wiring or component selection is established here.

## Program storage

There is no preferred SRAM configuration. Ben recommends following the Tiny
Tapeout reference template being prepared for IHP SRAM macros on CMOS5L.
Any macro is acceptable if it fits the allocated area and passes the Tiny
Tapeout precheck. Confirm template availability and compatibility with the
chosen shuttle before selecting or integrating a macro.

The current 512-word program array does not establish SRAM macro integration
or precheck compliance.

## Verification priorities

Ben explicitly values a reference model with differential testing, formal
properties, randomized tests, and a good explanation of the verification.
The existing model is a foundation; model presence alone does not demonstrate
RTL equivalence or protocol correctness.

## Recommended implementation order

1. Complete program loading and the execution/GPIO path needed to run protocol
   firmware on the integrated top.
2. Demonstrate UART, SPI, and I2C with documented timing, pin assignments,
   external hardware, and protocol-level tests.
3. Differentially compare RTL against the reference model, including randomized
   programs and inputs. Add formal properties for execution and interface
   invariants, and document coverage, results, and limitations.
4. Demonstrate independent contexts and explain how programmable instructions
   support different protocol behaviors without redesigning the core.
5. Select storage against the area budget and applicable SRAM template, then
   validate the integrated design through precheck and the physical flow.
6. Consider additional protocols only after the required three and their
   verification are established.

See [implementation status](IMPLEMENTATION.md), [protocol status](PROTOCOLS.md),
and [verification status](VERIFICATION.md) for what is currently implemented.
Ben's acknowledgement of GDS-flow progress is not a substitute for a recorded
build result tied to a specific revision and configuration.
