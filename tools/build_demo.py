"""Generate a four-context program image and its host configuration."""
import argparse
import json
from pathlib import Path
from tools.assembler import halt
from tools.config import PROGRAM_DEPTH
from tools.protocols import i2c_write, spi_transfer, uart_bit_grants, uart_rx, uart_tx

def build_demo(clock_hz: int = 50_000_000, uart_baud: int = 115_200) -> tuple[list[int], list[dict]]:
    image = [halt()] * PROGRAM_DEPTH
    uart_period = uart_bit_grants(clock_hz, uart_baud, receive=True)
    contexts = []
    cursor = 0
    for tid, name, mask, words in [
        (0, "UART RX", 0, uart_rx(bit_grants=uart_period)),
        (1, "UART TX 0xA5", 2, uart_tx(0xA5, bit_grants=uart_period)),
        (2, "I2C write 0xA7 to 0x52", 12, i2c_write(0x52, 0xA7)),
        (3, "SPI mode-0 transfer 0xA6", 176, spi_transfer(0xA6)),
    ]:
        if cursor + len(words) > len(image):
            raise ValueError("demo exceeds program memory")
        image[cursor:cursor + len(words)] = words
        contexts.append(dict(tid=tid, name=name, entry=cursor, pin_mask=mask, words=len(words)))
        contexts[-1]['clock_hz'] = clock_hz
        if tid in (0, 1):
            contexts[-1].update(bit_grants=uart_period, requested_baud=uart_baud,
                                actual_baud=clock_hz / (4 * uart_period))
        cursor += len(words)
    return image, contexts

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("build/demo"))
    parser.add_argument("--clock-hz", type=int, default=50_000_000)
    parser.add_argument("--uart-baud", type=int, default=115_200)
    args = parser.parse_args()
    try:
        image, contexts = build_demo(args.clock_hz, args.uart_baud)
    except ValueError as error:
        parser.error(str(error))
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "program.hex").write_text("".join(f"{word:04x}\n" for word in image))
    (args.output / "contexts.json").write_text(json.dumps(contexts, indent=2) + "\n")
    print(f"Wrote {sum(c['words'] for c in contexts)}/{PROGRAM_DEPTH} used words to {args.output}")

if __name__ == "__main__":
    main()
