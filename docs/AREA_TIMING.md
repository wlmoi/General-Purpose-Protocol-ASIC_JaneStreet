# Area and timing

The supplied physical-flow log failed at OpenROAD global placement with
`GPL-0301`: utilization was 113.101%, exceeding the available 6x4 core area.
Changing placement density cannot make cells occupying more than the core fit.

The RTL now uses 256 x 16-bit program storage with **one shared read port**,
replacing the previous 512 x 16-bit array with instruction, literal, and host
read paths. LDI fetches its literal on the context's next grant, and host DATA
readback requires software pause. Immediate push-pull/open-drain instructions
reduce the concurrent UART TX/RX + SPI + I2C demonstration from 335 words to
245 words, retaining all four contexts within the smaller storage budget.

Local synthesis used Yosys 0.69 via YoWASP, `synth -flatten -noabc`,
`dfflibmap`, and ABC mapping against the official IHP typical Liberty library.
The supplied core area is 902417.242 um^2. The results below are mapped cell
areas, not post-placement utilization or timing results.

| Metric | Previous RTL | Compact RTL |
|---|---:|---:|
| Program storage | 512 x 16 bits | 256 x 16 bits |
| Program read ports | 3 | 1 |
| Mapped IHP cell area | 898632.0630 um^2 | 395106.8436 um^2 |
| Mapped IHP cells | 49985 | 19493 |
| Cell area / supplied core area | 99.58% | 43.78% |

The mapped area reduction is approximately 56.0%. The compact result is below
both 100% capacity and the configured 60% placement density target, with room
for physical-flow overhead. It does not prove routing or timing closure.

Library source:
[IHP typical standard-cell Liberty](https://raw.githubusercontent.com/IHP-GmbH/IHP-Open-PDK/main/ihp-sg13g2/libs.ref/sg13g2_stdcell/lib/sg13g2_stdcell_typ_1p20V_25C.lib).
The measured file's SHA-256 is
`7677a8918689f452e80405ad16a83e744709342574f2aedcc507c2758986b396`.

To reproduce the compact synthesis estimate, provide that Liberty file and
install Yosys or `yowasp-yosys` in the Python environment:

```text
python -m tools.synth_area --liberty build/area/sg13g2_typ.lib
```

The tool writes the synthesis script, log, mapped netlist, functional cell
models, memory structure, and metrics under `build/area/`. It exits unsuccessfully
if mapped area exceeds the 60% budget or program memory has multiple read ports.
The generated metrics and logs are local build artifacts, not committed files.

The mapped netlist passed the external-pin cocotb regression using zero-delay
functional cell models generated from the same Liberty library. This validates
functional behavior after synthesis; it is not an SDF timing simulation.

The full LibreLane/OpenROAD flow was not rerun locally: Docker's Linux engine
is unavailable. The updated revision still needs the GitHub GDS workflow,
precheck, post-route STA, DRC/LVS, and board validation. No passing GDS or timing
closure is claimed for this revision.
