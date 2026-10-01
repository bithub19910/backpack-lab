"""Reproducible, isolated native integration runner (never launches the Steam install)."""
import argparse
import json
import subprocess
import time
from pathlib import Path
from native import ROOT, run_tool
from build_worker import OUTPUT

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--request')
    parser.add_argument('--output', default=str(OUTPUT / 'smoke.json'))
    args = parser.parse_args()
    args.output = str(Path(args.output).resolve())
    if args.request:
        args.request = str(Path(args.request).resolve())
    command = [OUTPUT / 'BackpackLabWorker.exe', '--no-window', '--audio-driver', 'Dummy',
               '--fixed-fps', '60', '--lab-output=' + args.output.replace('\\', '/')]
    command += ['--lab-request=' + args.request.replace('\\', '/')] if args.request else ['--lab-smoke']
    start = time.monotonic()
    try:
        result = run_tool(command, name='worker', timeout=60)
        code = result.returncode
    except subprocess.TimeoutExpired:
        code = -1
    log = (ROOT / 'data/local_runtime/worker/profile/BackpackLabWorker/logs/godot.log').read_text(encoding='utf-8', errors='replace')
    (OUTPUT / 'run.log').write_text(log, encoding='utf-8')
    print(log[-6500:])
    print('wall_seconds', round(time.monotonic() - start, 3), 'exit_code', code)
    if code or 'SCRIPT ERROR:' in log or 'LAB_TRIAL_DONE' not in log:
        raise SystemExit('Native integration failed; inspect run.log')
    data = json.loads(__import__('pathlib').Path(args.output).read_text(encoding='utf-8'))
    print(json.dumps({k: data[k] for k in ('status', 'count', 'wins', 'losses', 'unresolved', 'elapsed_ms')}, ensure_ascii=False))

if __name__ == '__main__':
    main()
