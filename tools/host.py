"""Host driver independent of board/vendor libraries.

Pass a callable transfer(bytes)->bytes that keeps CS low for the entire frame,
uses SPI mode 0, and returns one received byte per transmitted byte. The
transport must obey the documented clock limits and serialize calls.
"""
from collections.abc import Callable
from tools.assembler import assemble
from tools.config import PROGRAM_DEPTH

class Engine:
    def __init__(self, transfer: Callable[[bytes], bytes]):
        self.transfer = transfer

    def _exchange(self, frame: bytes) -> bytes:
        result = bytes(self.transfer(frame))
        if len(result) != len(frame):
            raise IOError("SPI transport returned an incomplete frame")
        return result

    def write(self, address: int, values: int | bytes) -> None:
        if not 0 <= address <= 127:
            raise ValueError("register address out of range")
        data = bytes([values]) if isinstance(values, int) else bytes(values)
        self._exchange(bytes([128 | address]) + data)

    def read(self, address: int, count: int = 1) -> bytes:
        if not 0 <= address <= 127 or count < 1:
            raise ValueError("invalid register address or read length")
        return self._exchange(bytes([address]) + bytes(count))[1:]

    def identify(self) -> int:
        return self.read(12)[0]

    def pause(self) -> None:
        self.write(0, 0)

    def resume(self) -> None:
        self.write(0, 1)

    def load(self, words: list[int], entry: int = 0, verify: bool = True) -> None:
        words = assemble(words)
        if not 0 <= entry < PROGRAM_DEPTH or entry + len(words) > PROGRAM_DEPTH:
            raise ValueError("program does not fit at entry address")
        data = b"".join(word.to_bytes(2, "little") for word in words)
        self.pause()
        self.write(2, (entry * 2) & 255)
        self.write(3, (entry * 2) >> 8)
        if data:
            self.write(4, data)
            if verify:
                self.write(2, (entry * 2) & 255)
                self.write(3, (entry * 2) >> 8)
                if self.read(4, len(data)) != data:
                    raise IOError("program readback mismatch")

    def configure(self, tid: int, pin_mask: int) -> None:
        if not 0 <= tid <= 3 or not 0 <= pin_mask <= 255:
            raise ValueError("invalid context or pin mask")
        self.pause()
        self.write(5, tid)
        self.write(10, pin_mask)
        if self.read(10)[0] != pin_mask or self.read(1)[0] & (1 << (tid + 4)):
            raise IOError("pin ownership configuration rejected; inspect/clear sticky errors")

    def start(self, mask: int, entry: int = 0) -> None:
        if not 1 <= mask <= 15 or not 0 <= entry < PROGRAM_DEPTH:
            raise ValueError("invalid start mask or entry address")
        self.write(6, entry & 255)
        self.write(7, entry >> 8)
        self.write(8, mask)

    def stop(self, mask: int = 15) -> None:
        if not 0 <= mask <= 15:
            raise ValueError("invalid stop mask")
        self.write(9, mask)

    def received(self, tid: int) -> int:
        if not 0 <= tid <= 3:
            raise ValueError("invalid context")
        # Pausing makes the two-byte snapshot coherent. Resume explicitly.
        self.pause()
        self.write(5, tid)
        return self.read(13)[0] | (self.read(14)[0] << 8)
