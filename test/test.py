"""Pin-only cocotb regression, suitable for RTL or a matching gate netlist."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, Timer

@cocotb.test()
async def test_project(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = 1
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)
    await Timer(1, unit="ns")
    assert int(dut.uio_oe.value) == 0
    assert int(dut.uio_out.value) == 0
    assert int(dut.uo_out.value) == 0

    async def transfer(frame):
        await FallingEdge(dut.clk)
        dut.ui_in.value = 0
        await ClockCycles(dut.clk, 8)
        result = []
        for byte in frame:
            received = 0
            for bit in range(7, -1, -1):
                await FallingEdge(dut.clk)
                dut.ui_in.value = ((byte >> bit) & 1) << 2
                await ClockCycles(dut.clk, 4)
                await FallingEdge(dut.clk)
                received = (received << 1) | (int(dut.uo_out.value) & 1)
                dut.ui_in.value = (((byte >> bit) & 1) << 2) | 2
                await ClockCycles(dut.clk, 4)
                await FallingEdge(dut.clk)
                dut.ui_in.value = ((byte >> bit) & 1) << 2
                await ClockCycles(dut.clk, 4)
            result.append(received)
        await FallingEdge(dut.clk)
        dut.ui_in.value = 1
        await ClockCycles(dut.clk, 8)
        return bytes(result)

    async def write(address, data):
        await transfer(bytes([128 | address]) + bytes(data))

    async def read(address, count=1):
        return (await transfer(bytes([address]) + bytes(count)))[1:]

    assert await read(12) == b'\xA7'
    program = b'\x5A\x00\xFF\x01\x00\x10\x00\x3E'
    await write(4, program)
    await write(2, [0])
    assert await read(4, len(program)) == program
    await write(10, [255])
    await write(8, [1])
    await write(0, [1])
    await ClockCycles(dut.clk, 100)
    await Timer(1, unit="ns")
    assert int(dut.uio_out.value) == 0x5A
    assert int(dut.uio_oe.value) == 255
    assert await read(1) == b'\0'
    await write(4, [0])
    assert await read(1) == b'\x10'
    await write(9, [1])
    await Timer(1, unit="ns")
    assert int(dut.uio_oe.value) == 0
