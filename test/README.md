# Test workflow

From the repository root:

```text
python -m unittest discover -s test -p "test_*.py" -v
```

This runs the reference-model and host-driver tests plus eleven Icarus RTL
regressions. Icarus and vvp must be on PATH. Test programs, stimulus, simulator
executables, and traces are kept in temporary directories.

The existing cocotb workflow uses `test/tb.v` and `test/test.py`, and checks only
external pins so it can also run against a matching gate-level netlist. Install
the pinned dependencies in `requirements.txt`, then on a system with Make:

```text
cd test
make
python -m cocotb_tools.check_results results.xml
```

Without Make, run from the repository root using Python with the pinned test
dependencies installed:

```text
python -m tools.run_cocotb
```

The CI workflow runs both suites. See [verification details](../docs/VERIFICATION.md)
for coverage and limits.
