"""Run the pin-only RTL test using cocotb 2.0.1 without requiring Make."""
from pathlib import Path
import sys
from xml.etree import ElementTree
from cocotb_tools.runner import get_runner

def main() -> None:
    root = Path(__file__).resolve().parents[1]
    build = root / 'build' / 'cocotb'
    runner = get_runner('icarus')
    runner.build(sources=[root / 'src/jane_top.v', root / 'src/program_host.v',
                          root / 'test/tb.v'], includes=[root / 'src'],
                 hdl_toplevel='tb', build_dir=build, build_args=['-g2012'])
    sys.path.insert(0, str(root / 'test'))
    results = runner.test(test_module='test', hdl_toplevel='tb', test_dir=build,
                          results_xml=str(build / 'results.xml'))
    tree = ElementTree.parse(results)
    tests = tree.findall('.//testcase')
    if not tests or any(t.find('failure') is not None or t.find('error') is not None for t in tests):
        raise SystemExit('Cocotb regression failed; inspect build/cocotb/results.xml')
    print(f'Cocotb: {len(tests)} test passed')

if __name__ == '__main__':
    main()
