import unittest
from tools.assembler import alu, branch, halt, ldi, mov, out, sample, wait
from tools.build_demo import build_demo
from tools.host import Engine
from tools.protocols import i2c_write, spi_transfer, uart_rx, uart_tx
from tools.reference_model import Machine

class ModelTests(unittest.TestCase):
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
                    machine.start(1, 511)
                    machine.x[0], machine.y[0] = a, b
                    machine.program[511] = branch(offset, fn)
                    machine.tick()
                    self.assertEqual(machine.pc[0], (offset if taken else 0) & 511)

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
        machine.start(1, 511)
        machine.program[511], machine.program[0] = ldi(0xCAFE, "y")
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
                     lambda: uart_tx(0, pin=-1), lambda: uart_rx(bit_grants=5)]:
            with self.assertRaises(ValueError):
                call()

    def test_demo_fits_and_ownership_is_disjoint(self):
        image, contexts = build_demo()
        self.assertEqual(len(image), 512)
        self.assertLessEqual(sum(c['words'] for c in contexts), 512)
        used = 0
        for context in contexts:
            self.assertEqual(used & context['pin_mask'], 0)
            used |= context['pin_mask']

class HostTests(unittest.TestCase):
    def test_load_frames_endianness_and_readback(self):
        frames = []
        def transfer(frame):
            frames.append(frame)
            return b'\0\x34\x12\xef\xbe' if frame == b'\x04\0\0\0\0' else bytes(len(frame))
        Engine(transfer).load([0x1234, 0xBEEF], entry=300)
        self.assertEqual(frames, [b'\x80\0', b'\x82\x58', b'\x83\x02',
                                 b'\x84\x34\x12\xef\xbe', b'\x82\x58',
                                 b'\x83\x02', b'\x04\0\0\0\0'])

    def test_bad_readback_and_short_transport(self):
        with self.assertRaises(IOError):
            Engine(lambda frame: bytes(len(frame))).load([0x1234])
        with self.assertRaises(IOError):
            Engine(lambda frame: b'').identify()

if __name__ == '__main__':
    unittest.main()
