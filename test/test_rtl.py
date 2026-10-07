"""Run meaningful RTL regressions with Python stdlib + Icarus (no pip needed).

Run from the repository root: python -m unittest discover -s test -p "test_*.py"
"""
from __future__ import annotations
import random
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.assembler import alu, branch, halt, inp, ldi, mov, out, receive, sample, wait, wait_pin
from tools.protocols import i2c_write, spi_transfer, uart_rx, uart_tx
from tools.reference_model import Machine

ROOT = Path(__file__).resolve().parents[1]

class RTLTests(unittest.TestCase):
    def simulate(self, programs, cycles, drives=None, enables=None, extra_setup="", after="", monitor=""):
        if not shutil.which("iverilog") or not shutil.which("vvp"):
            self.fail("iverilog and vvp must be on PATH")
        image = [halt()] * 512
        setup = []
        model = Machine()
        for tid, entry, mask, words in programs:
            self.assertLessEqual(entry + len(words), 512)
            image[entry:entry + len(words)] = words
            setup.append(f"select_thread(2'd{tid}, 9'd{entry}, 8'd{mask});")
            model.masks[tid] = mask
            model.start(1 << tid, entry)
        model.program = image
        drives = drives or [0] * cycles
        enables = enables or [1] * cycles
        self.assertEqual(len(drives), cycles)
        self.assertEqual(len(enables), cycles)
        vector = [((e & 1) << 8) | d for e, d in zip(enables, drives)]
        body = "\n".join(setup) + "\n" + extra_setup + """
        wr(0, 1);
        $display("INITIAL %0d %0d", dut.gpio_meta, dut.gpio_sync);
        begin : run_case
          reg [8:0] stimulus [0:NUM_CYCLES-1];
          reg [7:0] before_gpio;
          integer cycle;
          $readmemh("stimulus.hex", stimulus);
          for(cycle=0; cycle<NUM_CYCLES; cycle=cycle+1) begin
            @(negedge clk);
            ena = stimulus[cycle][8]; gpio_drive = stimulus[cycle][7:0];
            MONITOR
            #1; before_gpio = uio_in;
            @(posedge clk); #1; trace_state(cycle, before_gpio);
          end
        end
        @(negedge clk); ena = 0;
        AFTER
        """
        body = body.replace("NUM_CYCLES", str(cycles)).replace("MONITOR", monitor).replace("AFTER", after)
        with tempfile.TemporaryDirectory(prefix="protocol-rtl-") as directory:
            path = Path(directory)
            (path / "program.hex").write_text("\n".join(f"{w:04x}" for w in image))
            (path / "stimulus.hex").write_text("\n".join(f"{w:03x}" for w in vector))
            (path / "case_body.vh").write_text(body)
            compile_result = subprocess.run([
                "iverilog", "-g2012", "-s", "integration_tb", f"-I{ROOT / 'src'}", f"-I{path}",
                "-o", str(path / "sim.out"), str(ROOT / "src/jane_top.v"),
                str(ROOT / "src/program_host.v"), str(ROOT / "test/integration_tb.v")
            ], capture_output=True, text=True, timeout=30)
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            result = subprocess.run(["vvp", str(path / "sim.out")], cwd=path,
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout[-4000:] + result.stderr)
            self.assertIn("PASS", result.stdout)
            initial = next(list(map(int, line.split()[1:])) for line in result.stdout.splitlines() if line.startswith("INITIAL "))
            rows = [list(map(int, line.split()[1:])) for line in result.stdout.splitlines() if line.startswith("TRACE ")]
        self.assertEqual(len(rows), cycles)
        # GPIO was zero throughout SPI setup unless extra_setup changes it.
        model.gpio_meta, model.gpio_sync = initial
        for row in rows:
            cycle, gpio, enabled, slot, output, oe, halted, errors, *state = row
            model.tick(gpio, bool(enabled))
            expected = [model.slot, model.output, model.output_oe if enabled else 0,
                        sum(int(h) << t for t, h in enumerate(model.halted)),
                        sum(int(e) << t for t, e in enumerate(model.errors))]
            expected_state = []
            for t in range(4):
                expected_state += [model.pc[t], model.x[t], model.y[t], model.received[t], model.wait[t]]
            self.assertEqual([slot, output, oe, halted, errors, *state], expected + expected_state,
                             f"RTL/model mismatch at clock {cycle}")
        return rows, model

    def test_randomized_execution_and_ena(self):
        rng = random.Random(20261007)
        programs = []
        for tid in range(4):
            words = [mov(1 << tid, "y")]
            choices = [lambda: mov(rng.randrange(256)), lambda: mov(rng.randrange(256), "y"),
                       lambda: alu(rng.randrange(8)), lambda: out(), lambda: out(True),
                       lambda: inp(), lambda: sample(rng.randrange(8)),
                       lambda: sample(rng.randrange(8), True), lambda: receive(),
                       lambda: wait(rng.randrange(5)), lambda: 0xF000]
            for _ in range(90):
                if rng.randrange(8) == 0:
                    words.extend(ldi(rng.randrange(65536), rng.choice(["x", "y"])))
                else:
                    words.append(rng.choice(choices)())
            words.append(halt())
            programs.append((tid, tid * 128, 1 << tid, words))
        cycles = 1200
        _, model = self.simulate(programs, cycles,
                                 [rng.randrange(256) for _ in range(cycles)],
                                 [int(rng.randrange(8) != 0) for _ in range(cycles)])
        self.assertTrue(all(model.halted))
        self.assertTrue(all(model.errors))

    def test_branches_literal_wrap_and_pin_wait(self):
        # Negative offset -2 decrements to zero, then conditional exit.
        words = [mov(4), mov(1, "y"), alu(1), branch(-2, 6),
                 wait_pin(0, 1), *ldi(0xCAFE, "y"), halt()]
        rows, model = self.simulate([(0, 0, 1, words), (1, 511, 2, [0x9000])],
                                 160, [0] * 100 + [1] * 60)
        self.assertEqual(rows[1][13:15], [1, words[0]])
        self.assertTrue(model.halted[0])
        self.assertEqual(model.y[0], 0xCAFE)
        self.assertEqual(model.y[1], 0xCAFE)
        self.assertFalse(model.errors[0])

    def test_uart_tx_wire_frame(self):
        bit_grants = 16
        rows, model = self.simulate([(0, 0, 2, uart_tx(0xA5, bit_grants=bit_grants))], 850)
        wire = [(r[4] >> 1) & 1 for r in rows]
        start = next(i for i in range(1, len(rows)) if wire[i-1] == 1 and wire[i] == 0)
        decoded = [wire[start + bit_grants * 4 * n + bit_grants * 2] for n in range(10)]
        self.assertEqual(decoded, [0] + [(0xA5 >> n) & 1 for n in range(8)] + [1])
        self.assertEqual(model.output_oe, 2)
        self.assertTrue(model.halted[0])
        self.assertFalse(any(model.errors))

    def test_uart_rx_wire_frame(self):
        period, cycles, start = 64, 850, 80
        drives = [1] * cycles
        bits = [0] + [(0x69 >> n) & 1 for n in range(8)] + [1]
        for n, bit in enumerate(bits):
            drives[start + n * period:start + (n + 1) * period] = [bit] * period
        _, model = self.simulate([(0, 0, 0, uart_rx())], cycles, drives, extra_setup="gpio_drive = 1; clocks(4);")
        self.assertEqual(model.received[0], 0x69)
        self.assertTrue(model.halted[0])

    def test_spi_mode0_wire_transfer(self):
        monitor = """
        begin : slave
          integer bit_index;
          reg last_sck;
          if(cycle == 0) begin bit_index = 0; last_sck = 0; end
          // Peer responds to physical CS/SCK, without inspecting instructions.
          if(uio_out[7] || !uio_oe[7]) bit_index = 0;
          else if(last_sck && !uio_out[4]) bit_index = bit_index + 1;
          if(bit_index > 7) bit_index = 7;
          gpio_drive[6] = (8'h3C >> (7-bit_index)) & 1;
          last_sck = uio_out[4];
        end
        """
        rows, model = self.simulate([(0, 0, 0xB0, spi_transfer(0xA6))], 900, monitor=monitor)
        samples = []
        last_clock = 0
        for row in rows:
            pins = row[4]
            clock = (pins >> 4) & 1
            if not (pins & 128) and clock and not last_clock:
                samples.append((pins >> 5) & 1)
            last_clock = clock
        self.assertEqual(samples, [(0xA6 >> n) & 1 for n in range(7, -1, -1)])
        self.assertEqual(model.received[0], 0x3C)
        self.assertTrue(model.output & 128)
        self.assertTrue(model.halted[0])

    def test_i2c_open_drain_ack_and_stretch(self):
        words = i2c_write(0x52, 0xA7)
        # Derive peer ACK windows from rising-edge counts, independently of PC.
        monitor = """
        begin : bus_peer
          // Static variables persist across invocations of this block.
          reg last_scl, stretch_done, ack_active;
          integer edges, stretch;
          if(cycle == 0) begin last_scl = 1; edges = 0; stretch = 0; stretch_done = 0; ack_active = 0; end
          gpio_drive = 8'hFF;
          // Stretch the first requested data rising edge, independent of PC.
          if(edges == 0 && !last_scl && !dut.output_oe_q[3] && !stretch_done) begin
            stretch = 30; stretch_done = 1;
          end
          if(stretch > 0) begin gpio_drive[3] = 0; stretch = stretch - 1; end
          // Change ACK only while SCL is low; release on its trailing edge.
          #1;
          if(!uio_in[3] && last_scl && (edges == 9 || edges == 18)) ack_active = 0;
          if(!uio_in[3] && (edges == 8 || edges == 17)) ack_active = 1;
          gpio_drive[2] = !ack_active;
          #1;
          if (^uio_in === 1'bx) $fatal(1,"unknown bus");
          if(uio_in[3] && !last_scl) edges = edges + 1;
          last_scl = uio_in[3];
        end
        """
        rows, model = self.simulate([(0, 0, 12, words)], 5000, [255] * 5000, monitor=monitor)
        self.assertTrue(model.halted[0])
        self.assertEqual(model.received[0], 0)
        self.assertEqual(model.output_oe & 12, 0)
        self.assertFalse(any(model.errors))
        self.assertGreaterEqual(sum(not (r[1] & 8) and not (r[5] & 8) for r in rows), 25)
        # Every output-enable on an I2C line drives zero, never one.
        for row in rows:
            self.assertEqual(row[4] & row[5] & 12, 0)
        # Decode data on physical SCL rising edges, discarding idle/STOP.
        bus = [row[1] & 12 for row in rows]
        rising = []
        for a, b in zip(bus, bus[1:]):
            if not a & 8 and b & 8:
                rising.append(int(bool(b & 4)))
        self.assertEqual(rising[:18], [(0xA4 >> n) & 1 for n in range(7,-1,-1)] + [0] +
                         [(0xA7 >> n) & 1 for n in range(7,-1,-1)] + [0])

    def test_i2c_nack_stops_before_data(self):
        rows, model = self.simulate([(0, 0, 12, i2c_write(0x52, 0xA7))], 3000, [255] * 3000)
        self.assertEqual(model.received[0], 1)
        self.assertTrue(model.halted[0])
        self.assertEqual(model.output_oe & 12, 0)
        # Nine address/ACK clocks and one SCL rise used to generate STOP.
        bus = [row[1] for row in rows]
        self.assertEqual(sum(not (a & 8) and bool(b & 8) for a, b in zip(bus, bus[1:])), 10)

    def test_four_protocol_contexts_concurrently(self):
        from tools.build_demo import build_demo
        image, contexts = build_demo()
        programs = [(c['tid'], c['entry'], c['pin_mask'], image[c['entry']:c['entry'] + c['words']])
                    for c in contexts]
        drives = [255] * 5000  # I2C peer NACKs; SPI peer returns all ones.
        frame = [0] + [(0x69 >> bit) & 1 for bit in range(8)] + [1]
        for n, bit in enumerate(frame):
            for cycle in range(80 + n * 64, 80 + (n + 1) * 64):
                drives[cycle] = (drives[cycle] & ~1) | bit
        rows, model = self.simulate(programs, 5000, drives,
                                    extra_setup="gpio_drive = 8'hFF; clocks(4);")
        self.assertTrue(all(model.halted))
        self.assertFalse(any(model.errors))
        self.assertEqual(model.received, [0x69, 0, 1, 255])
        self.assertEqual(model.output_oe, 0xB2)
        # Concurrent I2C and SPI updates must preserve UART's driven idle high.
        self.assertTrue(all(row[4] & 2 for row in rows[850:]))

    def test_pin_ownership_rejects_overlap_and_releases_old_mask(self):
        after = """
          wr(0, 0); wr(5, 1); wr(10, 1);
          rd(10, value); if(value !== 2) $fatal(1,"overlap accepted");
          rd(1, value); if(!value[5]) $fatal(1,"overlap error missing");
          wr(5, 0); wr(10, 4);
          if(dut.output_oe_q[0]) $fatal(1,"old ownership still driving");
          rd(10, value); if(value !== 4) $fatal(1,"new mask missing");
        """
        self.simulate([(0, 0, 1, [mov(1), mov(1, "y"), out(), halt()]),
                       (1, 16, 2, [halt()])], 60, after=after)

    def test_host_protection_stop_restart_and_reset(self):
        after = """
          // Live memory writes must be rejected without advancing the address.
          wr(5, 0); wr(2, 0); wr(3, 0); wr(4, 8'hEF);
          rd(1, value); if(!value[4]) $fatal(1,"missing write protection error");
          rd(2, value); if(value !== 0) $fatal(1,"rejected write advanced address");
          rd(4, value); if(value !== 8'h01) $fatal(1,"live memory changed");
          wr(11, 1); rd(1, value); if(value[4]) $fatal(1,"error clear");
          wr(9, 1); if(dut.output_oe_q !== 0) $fatal(1,"stop did not release pins");
          wr(0, 0); wr(6, 0); wr(7, 0); wr(8, 1);
          if(dut.pc[0] !== 0 || dut.x[0] !== 0 || dut.received[0] !== 0) $fatal(1,"restart state");
          @(negedge clk); rst_n = 0; clocks(3);
          if(uio_oe !== 0 || uio_out !== 0 || uo_out !== 0) $fatal(1,"reset safety");
          @(negedge clk); rst_n = 1; clocks(5);
          rd(4, value); if(value !== 8'h01) $fatal(1,"reset destroyed program");
        """
        self.simulate([(0, 0, 1, [mov(1), mov(1, "y"), out(), halt()])], 60, after=after)

if __name__ == "__main__":
    unittest.main()
