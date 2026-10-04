from tools.assembler import halt, mov
from tools.reference_model import Machine


def test_round_robin_and_halt():
    machine = Machine()
    machine.program[0] = mov(0x5A)
    machine.program[1] = halt()
    machine.start(1)
    machine.tick()
    assert machine.x[0] == 0x5A
    assert machine.slot == 1
    machine.tick()
    assert machine.halted[0]
