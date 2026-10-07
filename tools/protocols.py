"""Small protocol programs for the integrated core; no protocol-specific RTL.

Timing is expressed in context grants (four enabled core clocks). Execute
without host control writes or ena pauses while a transaction is active.
"""
from tools.assembler import alu, assemble, branch, halt, mov, out, receive, sample, wait, wait_pin

def _pins(*pins: int) -> None:
    if any(not 0 <= pin <= 7 for pin in pins) or len(set(pins)) != len(pins):
        raise ValueError("protocol pins must be distinct indices in 0..7")

def uart_tx(value: int, pin: int = 1, bit_grants: int = 16) -> list[int]:
    """One 8N1 frame, LSB first, retaining idle high after HALT."""
    if not 0 <= value <= 255 or not 3 <= bit_grants <= 258:
        raise ValueError("byte or bit period out of range")
    _pins(pin)
    mask = 1 << pin
    words = [mov(mask, "y"), mov(mask), out(), wait(bit_grants - 3)]
    for bit in [0] + [(value >> n) & 1 for n in range(8)] + [1]:
        words += [mov(mask if bit else 0), out(), wait(bit_grants - 3)]
    # HALT is one grant after the last wait rather than a next MOV/OUT.
    words += [wait(2), halt()]
    return assemble(words)

def uart_rx(pin: int = 0, bit_grants: int = 16) -> list[int]:
    """Wait for start, sample eight bits near their centers, await stop high.

    This example accepts one frame and does not detect parity/framing errors.
    """
    if not 4 <= bit_grants <= 170 or bit_grants % 2:
        raise ValueError("RX bit grants must be even and in 4..170")
    _pins(pin)
    words = [wait_pin(pin, 0), wait(bit_grants + bit_grants // 2 - 2)]
    for n in range(8):
        words += [sample(pin, lsb_first=True)]
        if n != 7:
            words += [wait(bit_grants - 2)]
    words += [wait(bit_grants - 2), wait_pin(pin, 1), halt()]
    return assemble(words)

def spi_transfer(value: int, sck: int = 4, mosi: int = 5,
                 miso: int = 6, cs: int = 7, half_grants: int = 8) -> list[int]:
    """One mode-0 byte, MSB first, collecting MISO in received[context]."""
    if not 0 <= value <= 255 or not 4 <= half_grants <= 258:
        raise ValueError("byte or half period out of range")
    _pins(sck, mosi, miso, cs)
    mask = (1 << sck) | (1 << mosi) | (1 << cs)
    words = [mov(mask, "y"), mov(1 << cs), out(), wait(half_grants - 3)]
    for n in range(7, -1, -1):
        data = ((value >> n) & 1) << mosi
        words += [mov(data), out(), wait(half_grants - 3),
                  mov(data | (1 << sck)), out(), sample(miso), wait(half_grants - 4)]
    words += [mov(0), out(), wait(half_grants - 3), mov(1 << cs), out(), halt()]
    return assemble(words)

def i2c_write(address: int, value: int, sda: int = 2, scl: int = 3,
              hold_grants: int = 4) -> list[int]:
    """START, address+W, data, STOP. Both ACK bits are collected (0=ACK).

    SCL-high waits tolerate clock stretching; the host must stop a stuck bus.
    This is a single-master write example. NACKs cause STOP, without retry.
    """
    if not 0 <= address <= 127 or not 0 <= value <= 255 or not 0 <= hold_grants <= 255:
        raise ValueError("I2C argument out of range")
    _pins(sda, scl)
    sda_mask, scl_mask = 1 << sda, 1 << scl
    both = sda_mask | scl_mask
    words: list[int] = []
    nack_branches: list[int] = []
    def drive(released: int, clock_high: bool = False) -> None:
        words.extend([mov(released), out(open_drain=True)])
        if clock_high:
            words.append(wait_pin(scl, 1))
        words.append(wait(hold_grants))
    drive(both, True)
    drive(scl_mask, True)  # START: SDA falls while SCL remains high.
    drive(0)
    for byte in (address << 1, value):
        for n in range(7, -1, -1):
            data = sda_mask if byte & (1 << n) else 0
            drive(data)
            drive(data | scl_mask, True)
            drive(data)
        drive(sda_mask)  # Release SDA for slave ACK.
        drive(both, True)
        words.append(sample(sda))
        drive(sda_mask)
        words.extend([receive(), mov(1, "y"), alu(3)])
        nack_branches.append(len(words))
        words.append(0)
    stop = len(words)
    drive(0)
    drive(scl_mask, True)
    drive(both, True)  # STOP: SDA rises while SCL remains high.
    words.append(halt())
    for index in nack_branches:
        words[index] = branch(stop - index - 1, 6)
    return assemble(words)
