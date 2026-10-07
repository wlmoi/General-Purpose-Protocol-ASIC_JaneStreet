"""Map the RTL to a supplied Liberty library and check a placement area budget.

This is a synthesis estimate, not placement, routing, STA, DRC, or LVS.
Use the same tool/library/options when comparing revisions.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

def quoted(path: Path) -> str:
    return json.dumps(path.as_posix())

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--liberty', type=Path, required=True)
    parser.add_argument('--source-directory', type=Path, default=Path('src'))
    parser.add_argument('--output', type=Path, default=Path('build/area/compact'))
    parser.add_argument('--core-area', type=float, default=902417.242)
    parser.add_argument('--max-utilization', type=float, default=60.0)
    parser.add_argument('--max-read-ports', type=int, default=1)
    parser.add_argument('--yosys')
    args = parser.parse_args()
    if args.core_area <= 0 or not 0 < args.max_utilization <= 100:
        parser.error('invalid core area or utilization budget')
    tool = args.yosys or shutil.which('yosys')
    if not tool:
        sibling = Path(sys.executable).parent / ('yowasp-yosys.exe' if sys.platform == 'win32' else 'yowasp-yosys')
        if sibling.is_file():
            tool = str(sibling)
        else:
            tool = shutil.which('yowasp-yosys')
    if not tool:
        parser.error('install Yosys or yowasp-yosys in the current Python environment')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    prefix = args.output.as_posix()
    script = Path(prefix + '.ys')
    script.write_text('\n'.join([
        f'read_verilog -I{quoted(args.source_directory)} {quoted(args.source_directory / "jane_top.v")} {quoted(args.source_directory / "program_host.v")}',
        'hierarchy -check -top tt_um_janestreet_protocol_engine',
        'proc; opt; memory_collect',
        f'write_json {quoted(Path(prefix + "-memory.json"))}',
        'synth -top tt_um_janestreet_protocol_engine -flatten -noabc',
        f'dfflibmap -liberty {quoted(args.liberty)}',
        f'abc -liberty {quoted(args.liberty)}',
        f'read_liberty -lib {quoted(args.liberty)}',
        'clean; check -assert',
        f'stat -liberty {quoted(args.liberty)}',
        f'write_json {quoted(Path(prefix + ".json"))}',
        f'write_verilog -noattr {quoted(Path(prefix + ".v"))}',
        'design -reset',
        f'read_liberty -ignore_miss_func {quoted(args.liberty)}',
        f'write_verilog -noattr {quoted(Path(prefix + "-cells-functional.v"))}',
    ]) + '\n')
    with Path(prefix + '-console.log').open('w') as output:
        result = subprocess.run([tool, '-Q', '-T', '-l', prefix + '.log', '-s', str(script)],
                                stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        raise SystemExit(f'Synthesis failed; see {prefix}-console.log')
    log = Path(prefix + '.log').read_text()
    match = re.search(r'Chip area for module .*?:\s*([\d.]+)', log)
    if not match:
        raise SystemExit('Mapped area was not reported')
    area = float(match[1])
    memory_netlist = json.loads(Path(prefix + '-memory.json').read_text())
    memories = [cell for module in memory_netlist['modules'].values()
                for name, cell in module['cells'].items() if name.endswith('prog_mem_q')]
    if len(memories) != 1:
        raise SystemExit('Expected exactly one integrated program memory')
    parameters = memories[0]['parameters']
    memory = {key: int(parameters[key], 2) for key in ('SIZE', 'WIDTH', 'RD_PORTS')}
    metrics = dict(mapped_area_um2=area, core_area_um2=args.core_area,
                   estimated_utilization_pct=100 * area / args.core_area,
                   max_utilization_pct=args.max_utilization, program_memory=memory,
                   liberty_sha256=hashlib.sha256(args.liberty.read_bytes()).hexdigest())
    Path(prefix + '-metrics.json').write_text(json.dumps(metrics, indent=2) + '\n')
    print(json.dumps(metrics, indent=2))
    if memory['RD_PORTS'] > args.max_read_ports:
        raise SystemExit('Program memory has more read ports than the configured budget')
    if metrics['estimated_utilization_pct'] > args.max_utilization:
        raise SystemExit('Mapped cell area exceeds the placement target budget')

if __name__ == '__main__':
    main()
