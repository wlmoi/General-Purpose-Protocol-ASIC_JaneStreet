"""Cycle model for the implemented four-slot execution core."""

from dataclasses import dataclass, field


@dataclass
class Machine:
    program: list[int] = field(default_factory=lambda: [0] * 512)
    pc: list[int] = field(default_factory=lambda: [0] * 4)
    x: list[int] = field(default_factory=lambda: [0] * 4)
    y: list[int] = field(default_factory=lambda: [0] * 4)
    wait: list[int] = field(default_factory=lambda: [0] * 4)
    halted: list[bool] = field(default_factory=lambda: [True] * 4)
    slot: int = 0
    output: int = 0
    output_oe: int = 0

    def start(self, mask: int = 0xF) -> None:
        self.halted = [not bool(mask & (1 << index)) for index in range(4)]

    def tick(self, gpio: int = 0, enabled: bool = True) -> None:
        if not enabled:
            return
        slot = self.slot
        self.slot = (slot + 1) & 3
        if self.halted[slot]:
            return
        if self.wait[slot]:
            self.wait[slot] -= 1
            return
        instruction = self.program[self.pc[slot]]
        opcode = (instruction >> 12) & 0xF
        function = (instruction >> 9) & 0x7
        immediate = instruction & 0xFF
        self.pc[slot] = (self.pc[slot] + 1) & 0x1FF
        if opcode == 0:
            self.x[slot] = immediate
        elif opcode == 1:
            self.output = self.x[slot] & 0xFF
            self.output_oe = self.y[slot] & 0xFF
        elif opcode == 2:
            if function == 0:
                self.x[slot] = (self.x[slot] + self.y[slot]) & 0xFFFF
            elif function == 1:
                self.x[slot] = (self.x[slot] - self.y[slot]) & 0xFFFF
            elif function == 2:
                self.x[slot] |= self.y[slot]
            elif function == 3:
                self.x[slot] &= self.y[slot]
            elif function == 4:
                self.x[slot] ^= self.y[slot]
        elif opcode == 3:
            if function == 7:
                self.halted[slot] = True
            elif function == 0:
                offset = (instruction >> 1) & 0x7F
                if offset & 0x40:
                    offset -= 0x80
                self.pc[slot] = (self.pc[slot] + offset) & 0x1FF
        elif opcode == 4:
            self.wait[slot] = immediate & 0x1F
        elif opcode == 7:
            self.x[slot] = gpio & 0xFF
        elif opcode == 9:
            self.x[slot] = self.program[self.pc[slot]]
            self.pc[slot] = (self.pc[slot] + 1) & 0x1FF
