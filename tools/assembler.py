"""Assembler for the currently implemented JaneStreet core subset."""

from __future__ import annotations


def _word(opcode: int, body: int = 0) -> int:
    return ((opcode & 0xF) << 12) | (body & 0xFFF)


def mov(value: int) -> int:
    return _word(0, value)


def out() -> int:
    return _word(1)


def alu(function: int) -> int:
    return _word(2, (function & 0x7) << 9)


def branch(offset: int = 0) -> int:
    if not -64 <= offset <= 63:
        raise ValueError("branch offset must fit signed 7-bit encoding")
    return _word(3, (offset & 0x7F) << 1)


def wait(cycles: int) -> int:
    return _word(4, cycles & 0xFF)


def inp() -> int:
    return _word(7)


def ldi(address: int) -> tuple[int, int]:
    return _word(9), address & 0xFFFF


def halt() -> int:
    return _word(3, 7 << 9)


def assemble(words: list[int]) -> list[int]:
    if len(words) > 512:
        raise ValueError("program exceeds 512 words")
    return [word & 0xFFFF for word in words]
