import unittest
from tools.assembler import alu, assemble, branch, halt, ldi, mov, out, out_immediate, sample, signal_error, wait
from tools.build_demo import build_demo
from tools.host import Engine
from tools.protocols import i2c_write, spi_transfer, uart_bit_grants, uart_rx, uart_tx
from tools.reference_model import Machine
from tools.config import PROGRAM_DEPTH, PROGRAM_MASK

class ModelTests(unittest.TestCase):
    def test_uart_baud_selection_and_firmware_boundaries(self):
        for receive in (False, True):
            grants = uart_bit_grants(50_000_000, 115_200, receive=receive)
            self.assertEqual(grants, 108 if receive else 109)
            self.assertLess(abs(50_000_000 / (4 * grants) / 115_200 - 1), 0.02)
        for clock, baud in ((0, 115_200), (50_000_000, 0), (50_000_000, 9_600)):
            with self.subTest(clock=clock, baud=baud), self.assertRaises(ValueError):
                uart_bit_grants(clock, baud, receive=True)
        self.assertEqual(len(uart_rx(bit_grants=256)), 29)
        for period in (3, 5, 258):
            with self.subTest(period=period), self.assertRaises(ValueError):
                uart_rx(bit_grants=period)
        for clock, expected_grants in ((50_000_000, 108), (12_000_000, 26)):
            image, contexts = build_demo(clock_hz=clock, uart_baud=115_200)
            self.assertEqual(len(image), PROGRAM_DEPTH)
            self.assertEqual(sum(context['words'] for context in contexts), 254)
            for context in contexts[:2]:
                self.assertEqual(context['bit_grants'], expected_grants)
                self.assertLess(abs(context['actual_baud'] / 115_200 - 1), 0.02)

    def test_firmware_error_flag(self):
        machine = Machine()
        machine.program[:2] = [signal_error(), halt()]
        machine.start(1)
        machine.tick()
        self.assertTrue(machine.errors[0])
        self.assertFalse(machine.halted[0])
        for _ in range(4):
            machine.tick()
        self.assertTrue(machine.halted[0])

    def test_round_robin_and_halt(self):
        machine = Machine()
        machine.program[:2] = [mov(0x5A), halt()]
        machine.start(1)
        machine.tick()
        self.assertEqual(machine.x[0], 0x5A)
        self.assertEqual(machine.slot, 1)
        for _ in range(3):
            machine.tick()
        self.assertFalse(machine.halted[0])
        machine.tick()
        self.assertTrue(machine.halted[0])

    def test_branch_conditions_and_signed_boundaries(self):
        for fn, a, b, taken in [(0, 0, 0, True), (1, 7, 7, True), (1, 7, 8, False),
                                (2, 7, 8, True), (2, 7, 7, False), (3, 7, 8, True),
                                (3, 8, 7, False), (4, 8, 7, True), (4, 7, 8, False),
                                (6, 1, 0, True), (6, 0, 1, False)]:
            for offset in (-128, -1, 0, 127):
                with self.subTest(fn=fn, offset=offset, taken=taken):
                    machine = Machine()
                    machine.start(1, PROGRAM_MASK)
                    machine.x[0], machine.y[0] = a, b
                    machine.program[PROGRAM_MASK] = branch(offset, fn)
                    machine.tick()
                    self.assertEqual(machine.pc[0], (offset if taken else 0) & PROGRAM_MASK)

    def test_wait_full_byte_and_enable_freeze(self):
        machine = Machine()
        machine.program[:3] = [wait(255), mov(9), halt()]
        machine.start(1)
        machine.tick()
        before = (machine.slot, machine.pc.copy(), machine.wait.copy())
        machine.tick(gpio=255, enabled=False)
        self.assertEqual((machine.slot, machine.pc, machine.wait), before)
        for _ in range(4 * 255):
            machine.tick()
        self.assertEqual(machine.wait[0], 0)
        self.assertEqual(machine.x[0], 0)
        for _ in range(4):
            machine.tick()
        self.assertEqual(machine.x[0], 9)

    def test_masked_open_drain_and_literal_wrap(self):
        machine = Machine()
        machine.start(1, PROGRAM_MASK)
        machine.program[PROGRAM_MASK], machine.program[0] = ldi(0xCAFE, "y")
        machine.tick()
        self.assertTrue(machine.pending[0])
        self.assertEqual(machine.pc[0], 0)
        for _ in range(4):
            machine.tick()
        self.assertEqual(machine.y[0], 0xCAFE)
        self.assertEqual(machine.pc[0], 1)
        machine.program[1] = out(True)
        machine.x[0], machine.masks[0] = 4, 12
        machine.output, machine.output_oe = 255, 255
        for _ in range(4):
            machine.tick()
        self.assertEqual(machine.output, 243)
        self.assertEqual(machine.output_oe, 251)

    def test_rejected_encodings(self):
        for call in [lambda: mov(256), lambda: wait(256), lambda: branch(-129),
                     lambda: branch(128), lambda: branch(0, 5), lambda: ldi(-1),
                     lambda: alu(8), lambda: sample(8), lambda: mov(0, "z"),
                     lambda: spi_transfer(0, sck=5, mosi=5), lambda: i2c_write(128, 0),
                     lambda: uart_tx(0, pin=-1), lambda: uart_rx(bit_grants=5),
                     lambda: uart_tx(0, bit_grants=258), lambda: spi_transfer(0, half_grants=258),
                     lambda: out_immediate(256), lambda: assemble([halt()] * (PROGRAM_DEPTH + 1))]:
            with self.assertRaises(ValueError):
                call()
        self.assertLessEqual(len(uart_tx(0, bit_grants=257)), PROGRAM_DEPTH)
        self.assertLessEqual(len(spi_transfer(0, half_grants=257)), PROGRAM_DEPTH)

    def test_demo_fits_and_ownership_is_disjoint(self):
        image, contexts = build_demo()
        self.assertEqual(len(image), PROGRAM_DEPTH)
        self.assertLessEqual(sum(c['words'] for c in contexts), PROGRAM_DEPTH)
        used = 0
        for context in contexts:
            self.assertEqual(used & context['pin_mask'], 0)
            used |= context['pin_mask']

    def test_literal_fetch_pause_and_restart(self):
        machine = Machine()
        machine.program[:3] = [*ldi(0x1234), halt()]
        machine.start(1)
        machine.tick()
        self.assertTrue(machine.pending[0])
        machine.tick(enabled=False)
        self.assertEqual(machine.x[0], 0)
        self.assertTrue(machine.pending[0])
        for _ in range(4):
            machine.tick()
        self.assertEqual(machine.x[0], 0x1234)
        self.assertFalse(machine.pending[0])
        machine.start(1)
        self.assertEqual(machine.pc[0], 0)
        self.assertFalse(machine.pending[0])

    def test_geometry_matches_rtl(self):
        import re
        from pathlib import Path
        defines = (Path(__file__).resolve().parents[1] / 'src/defines.vh').read_text()
        self.assertEqual(int(re.search(r'`define JP_PROG_DEPTH\s+(\d+)', defines)[1]), PROGRAM_DEPTH)
        self.assertEqual(1 << int(re.search(r'`define JP_PROG_AW\s+(\d+)', defines)[1]), PROGRAM_DEPTH)

class HostTests(unittest.TestCase):
    def test_load_frames_endianness_and_readback(self):
        frames = []
        def transfer(frame):
            frames.append(frame)
            return b'\0\x34\x12\xef\xbe' if frame == b'\x04\0\0\0\0' else bytes(len(frame))
        Engine(transfer).load([0x1234, 0xBEEF], entry=150)
        self.assertEqual(frames, [b'\x80\0', b'\x82\x2C', b'\x83\x01',
                                 b'\x84\x34\x12\xef\xbe', b'\x82\x2C',
                                 b'\x83\x01', b'\x04\0\0\0\0'])

    def test_bad_readback_and_short_transport(self):
        with self.assertRaises(IOError):
            Engine(lambda frame: bytes(len(frame))).load([0x1234])
        with self.assertRaises(IOError):
            Engine(lambda frame: b'').identify()

if __name__ == '__main__':
    unittest.main()
