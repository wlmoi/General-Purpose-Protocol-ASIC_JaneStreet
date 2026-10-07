"""Validated encoders for the integrated programmable GPIO core."""
from __future__ import annotations
from tools.config import PROGRAM_DEPTH

def _range(value: int, low: int, high: int, name: str) -> int:
    if not low <= value <= high:
        raise ValueError(f"{name} must be in {low}..{high}")
    return value

def _word(opcode: int, body: int = 0) -> int:
    return (opcode << 12) | body

def mov(value: int, register: str = "x") -> int:
    if register not in ("x", "y"):
        raise ValueError("register must be x or y")
    return _word(0, (int(register == "y") << 8) | _range(value, 0, 255, "immediate"))

def out(open_drain: bool = False) -> int:
    return _word(1, int(open_drain) << 9)

def out_immediate(value: int, open_drain: bool = False) -> int:
    return _word(1, ((3 if open_drain else 2) << 9) | _range(value, 0, 255, "GPIO value"))

def alu(function: int) -> int:
    return _word(2, _range(function, 0, 7, "ALU function") << 9)

def branch(offset: int = 0, condition: int = 0) -> int:
    _range(offset, -128, 127, "branch offset")
    if condition not in (0, 1, 2, 3, 4, 6):
        raise ValueError("unsupported branch condition")
    return _word(3, (condition << 9) | ((offset & 255) << 1))

def wait(cycles: int) -> int:
    return _word(4, _range(cycles, 0, 255, "wait cycles"))

def wait_pin(pin: int, level: int = 1) -> int:
    return _word(4, (1 << 9) | (_range(level, 0, 1, "level") << 3) | _range(pin, 0, 7, "pin"))

def inp() -> int:
    return _word(7)

def sample(pin: int, lsb_first: bool = False) -> int:
    return _word(7, ((5 if lsb_first else 4) << 9) | _range(pin, 0, 7, "pin"))

def receive() -> int:
    return _word(7, 6 << 9)

def ldi(value: int, register: str = "x") -> tuple[int, int]:
    if register not in ("x", "y"):
        raise ValueError("register must be x or y")
    return _word(9, int(register == "y") << 8), _range(value, 0, 65535, "literal")

def halt() -> int:
    return _word(3, 7 << 9)

def assemble(words: list[int]) -> list[int]:
    if len(words) > PROGRAM_DEPTH:
        raise ValueError(f"program exceeds {PROGRAM_DEPTH} words")
    return [_range(word, 0, 65535, "word") for word in words]
