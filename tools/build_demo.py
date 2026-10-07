"""Generate a four-context program image and its host configuration."""
import argparse
import json
from pathlib import Path
from tools.assembler import halt
from tools.protocols import i2c_write, spi_transfer, uart_rx, uart_tx

def build_demo() -> tuple[list[int], list[dict]]:
    image = [halt()] * 512
    contexts = []
    cursor = 0
    for tid, name, mask, words in [
        (0, "UART RX", 0, uart_rx()),
        (1, "UART TX 0xA5", 2, uart_tx(0xA5)),
        (2, "I2C write 0xA7 to 0x52", 12, i2c_write(0x52, 0xA7)),
        (3, "SPI mode-0 transfer 0xA6", 176, spi_transfer(0xA6)),
    ]:
        if cursor + len(words) > len(image):
            raise ValueError("demo exceeds program memory")
        image[cursor:cursor + len(words)] = words
        contexts.append(dict(tid=tid, name=name, entry=cursor, pin_mask=mask, words=len(words)))
        cursor += len(words)
    return image, contexts

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("build/demo"))
    args = parser.parse_args()
    image, contexts = build_demo()
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "program.hex").write_text("".join(f"{word:04x}\n" for word in image))
    (args.output / "contexts.json").write_text(json.dumps(contexts, indent=2) + "\n")
    print(f"Wrote {sum(c['words'] for c in contexts)}/512 used words to {args.output}")

if __name__ == "__main__":
    main()
