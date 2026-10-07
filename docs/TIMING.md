# Timing

When both `ena` and the host core-enable register are high, the scheduler grants
T0, T1, T2, T3 in order. Every context receives one grant per four clocks,
including halted and waiting contexts. A cycle WAIT(N) skips N subsequent
context grants. WAIT_PIN holds that context's PC until the synchronized input
matches, without delaying another context. GPIO input visibility includes
two synchronizer stages.

For `tools.protocols.uart_tx`, a bit lasts `4 * bit_grants` core clocks.
UART RX uses the same period, sampling around bit centers after a start-low
wait. At a 50 MHz input clock the default 16-grant test period corresponds
to 781250 baud. Use a period suitable for the peer; 108 grants gives about
115741 baud at 50 MHz. RX requires an even grant period in 4..170; TX permits
3..258. These are cycle-derived rates, not measured board rates.

SPI mode-0 firmware uses `4 * half_grants` clocks per high/low data half-period.
The default 8 grants corresponds to 781250 Hz at 50 MHz. CS setup/hold and
final idle timing include additional instruction overhead.

I2C firmware explicitly waits for physical SCL high after releasing it. Clock
stretching therefore changes its period. `hold_grants` supplies an additional
hold after each phase; instruction and synchronization overhead must be included
when deriving bus timing. This example does not claim a particular I2C speed
class or electrical rise-time compliance.

Host SPI uses mode 0, MSB first. Hold CS assertion/deassertion for at least four
core clocks and each SCLK half-period for at least four core clocks; the core
clock must remain running. Host control writes suppress instruction retirement
for one clock and can stretch protocol timing. Avoid them during timed transfers,
except to interrupt an unwanted transaction. Host reads do not stall the core.
`ena=0` pauses the scheduler and releases physical GPIO; toggling it during a
transaction changes the bus waveform.

Reset is asynchronous active-low for control/GPIO state. Program memory is
host-written, with no reset initialization. Timing closure, metastability MTBF,
and physical propagation delays have not been characterized.
