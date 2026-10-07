"""Clock-level reference model, including the two-flop GPIO input pipeline."""
from dataclasses import dataclass, field

@dataclass
class Machine:
    program: list[int] = field(default_factory=lambda: [0] * 512)
    pc: list[int] = field(default_factory=lambda: [0] * 4)
    x: list[int] = field(default_factory=lambda: [0] * 4)
    y: list[int] = field(default_factory=lambda: [0] * 4)
    received: list[int] = field(default_factory=lambda: [0] * 4)
    wait: list[int] = field(default_factory=lambda: [0] * 4)
    masks: list[int] = field(default_factory=lambda: [0] * 4)
    halted: list[bool] = field(default_factory=lambda: [True] * 4)
    errors: list[bool] = field(default_factory=lambda: [False] * 4)
    slot: int = 0
    output: int = 0
    output_oe: int = 0
    gpio_meta: int = 0
    gpio_sync: int = 0

    def start(self, mask: int = 15, entry: int = 0) -> None:
        for t in range(4):
            if mask & (1 << t):
                self.pc[t] = entry
                self.x[t] = self.y[t] = self.received[t] = self.wait[t] = 0
                self.halted[t] = self.errors[t] = False

    def tick(self, gpio: int = 0, enabled: bool = True) -> None:
        pins = self.gpio_sync
        self.gpio_sync, self.gpio_meta = self.gpio_meta, gpio & 255
        if not enabled:
            return
        t = self.slot
        self.slot = (t + 1) & 3
        if self.halted[t]:
            return
        if self.wait[t]:
            self.wait[t] -= 1
            return
        old_pc = self.pc[t]
        word = self.program[old_pc]
        op, fn, imm = word >> 12, (word >> 9) & 7, word & 255
        a, b, mask = self.x[t], self.y[t], self.masks[t]
        self.pc[t] = (old_pc + 1) & 511
        if op == 0:
            (self.y if word & 256 else self.x)[t] = imm
        elif op == 1:
            if fn in (0, 1):
                value, oe = (a & 255, b & 255) if fn == 0 else (0, ~a & 255)
                self.output = (self.output & ~mask) | (value & mask)
                self.output_oe = (self.output_oe & ~mask) | (oe & mask)
            else:
                self.errors[t] = True
        elif op == 2:
            self.x[t] = (a + b, a - b, a | b, a & b, a ^ b,
                         a << 1, a >> 1, (a << 1) | (a >> 15))[fn] & 65535
        elif op == 3:
            if fn == 7:
                self.halted[t] = True
            elif fn == 5:
                self.errors[t] = True
            elif (True, a == b, a != b, a < b, a > b, False, a != 0)[fn]:
                offset = (word >> 1) & 255
                if offset >= 128:
                    offset -= 256
                self.pc[t] = (old_pc + 1 + offset) & 511
        elif op == 4:
            if fn == 0:
                self.wait[t] = imm
            elif fn == 1:
                if ((pins >> (word & 7)) & 1) != ((word >> 3) & 1):
                    self.pc[t] = old_pc
            else:
                self.errors[t] = True
        elif op == 7:
            bit = (pins >> (word & 7)) & 1
            if fn == 0:
                self.x[t] = pins
            elif fn == 4:
                self.received[t] = ((self.received[t] << 1) | bit) & 65535
            elif fn == 5:
                self.received[t] = (bit << 7) | ((self.received[t] & 255) >> 1)
            elif fn == 6:
                self.x[t] = self.received[t]
            else:
                self.errors[t] = True
        elif op == 9:
            (self.y if word & 256 else self.x)[t] = self.program[(old_pc + 1) & 511]
            self.pc[t] = (old_pc + 2) & 511
        else:
            self.errors[t] = True
