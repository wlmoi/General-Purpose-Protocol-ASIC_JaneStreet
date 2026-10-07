"""Run the pin-only RTL test using cocotb 2.0.1 without requiring Make."""
from pathlib import Path
import argparse
import sys
from xml.etree import ElementTree
from cocotb_tools.runner import get_runner

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--netlist', type=Path)
    parser.add_argument('--cell-models', type=Path, nargs='+')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if args.netlist and not args.cell_models:
        parser.error('--netlist requires --cell-models')
    build = root / 'build' / ('cocotb-mapped' if args.netlist else 'cocotb')
    sources = [root / 'test/tb.v']
    if args.netlist:
        sources += [args.netlist.resolve()] + [path.resolve() for path in args.cell_models]
    else:
        sources += [root / 'src/jane_top.v', root / 'src/program_host.v']
    runner = get_runner('icarus')
    runner.build(sources=sources, includes=[root / 'src'],
                 hdl_toplevel='tb', build_dir=build, build_args=['-g2012'])
    sys.path.insert(0, str(root / 'test'))
    results = runner.test(test_module='test', hdl_toplevel='tb', test_dir=build,
                          results_xml=str(build / 'results.xml'))
    tree = ElementTree.parse(results)
    tests = tree.findall('.//testcase')
    if not tests or any(t.find('failure') is not None or t.find('error') is not None for t in tests):
        raise SystemExit(f'Cocotb regression failed; inspect {build / "results.xml"}')
    print(f'Cocotb: {len(tests)} test passed')

if __name__ == '__main__':
    main()
