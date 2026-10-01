"""Capture current scripts using an isolated, autoload-free native engine copy.

Only captured plaintext whose embedded MD5 matches is accepted. No game scene,
Steam integration, networking singleton or actual user profile is loaded.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import struct
import sys
import threading
import time
from pathlib import Path

import frida

from native import GAME, ROOT, gdre, isolated_environment
from pck import archive_index, build_archive, encode_project, project_entries, read_entry, variant


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--timeout', type=float, default=60)
    parser.add_argument('--decrypt-rva', type=lambda n: int(n, 0), default=0x164F250)
    args = parser.parse_args()
    supported = json.loads((ROOT / 'plugin/mod.json').read_text(encoding='utf-8'))['supported_files']
    for name, expected in supported.items():
        if not (GAME / name).is_file() or hashlib.sha256((GAME / name).read_bytes()).hexdigest() != expected:
            raise ValueError('Unsupported game file; capture hook will not run: ' + name)
    base = ROOT / 'data/local_runtime/rules-capture'
    base.mkdir(parents=True, exist_ok=True)
    source = GAME / 'BackpackBattles.pck'
    exe = base / 'BackpackLabCapture.exe'
    shutil.copy2(GAME / 'BackpackBattles.exe', exe)
    # The Windows loader requires steam_api64 even though this harness never
    # initializes Steam. Keep native dependencies beside the copied executable.
    for dependency in ('steam_api64.dll', 'libgdsqlite.dll'):
        shutil.copy2(GAME / dependency, base / dependency)
    _, entries = archive_index(source)
    targets = {}
    wanted, pending = [], []
    results, failures = {}, []
    out = ROOT / 'data/local_rules/current'
    plain_dir = out / 'bytecode'
    plain_dir.mkdir(parents=True, exist_ok=True)
    verified_candidates = {}
    for folder in (ROOT / 'data/staging/shop_rule_audit/bulk', plain_dir):
        for candidate in folder.glob('*.gdc'):
            verified_candidates[hashlib.md5(candidate.read_bytes()).hexdigest()] = candidate
    with source.open('rb') as stream:
        for name, (offset, length, _) in entries.items():
            if not name.endswith('.gde') and name != 'res://Sheets/CSV/ItemData_e.csv':
                continue
            stream.seek(offset)
            value = stream.read(length)
            if value[:4] != b'GDEC':
                continue
            plain_size, = struct.unpack_from('<Q', value, 24)
            info = {'path': name, 'length': plain_size, 'md5': value[8:24].hex()}
            wanted.append(name)
            file_name = name.removeprefix('res://').replace('/', '__')
            file_name = file_name[:-4] + '.gdc' if file_name.endswith('.gde') else file_name
            previous = verified_candidates.get(info['md5'])
            if previous is not None and previous.stat().st_size == plain_size:
                if previous.resolve() != (plain_dir / file_name).resolve():
                    shutil.copy2(previous, plain_dir / file_name)
                results[name] = {**info, 'file': file_name, 'capture': 'verified MD5 reuse'}
            else:
                targets.setdefault(value[32:48].hex(), []).append(info)
                pending.append(name)
    # Keep original class registration for dependency resolution, remove every autoload.
    project = project_entries(read_entry(source, 'res://project.binary'))
    project = {k: v for k, v in project.items() if not k.startswith('autoload/')}
    project['application/config/name'] = variant('BackpackLabCapture')
    project['application/run/main_scene'] = variant('')
    project['_custom_features'] = variant('full_version,disable_steam_integration')
    project['debug/file_logging/enable_file_logging'] = variant(False)
    capture = 'extends SceneTree\n\nfunc _init():\n'
    capture += '\tfor path in ' + json.dumps(pending) + ':\n'
    capture += '\t\tif path.ends_with(".gde"):\n\t\t\tload(path)\n'
    capture += '\t\telse:\n\t\t\tvar key = PoolByteArray()\n\t\t\tfor i in 32:\n\t\t\t\tkey.append(i)\n\t\t\tvar file = File.new()\n\t\t\tfile.open_encrypted(path, File.READ, key)\n\t\t\tfile.get_buffer(file.get_len())\n\t\t\tfile.close()\n'
    capture += '\tprint("LAB_CAPTURE_FINISHED")\n\tquit()\n'
    pack = base / 'capture.pck'
    build_archive(source, pack, {'res://project.binary': encode_project(project),
                               'res://LabCapture.gd': capture.encode()})
    print(f'Reusing {len(results)} verified resources; capturing {len(pending)} changed or missing resources.', flush=True)
    finished = threading.Event()
    log = (base / 'capture.log').open('wb')
    device = frida.get_local_device()
    argv = [str(exe), '--no-window', '--audio-driver', 'Dummy', '--main-pack', str(pack),
            '--script', 'res://LabCapture.gd']
    pid = device.spawn(str(exe), argv=argv, cwd=str(base),
                       env=isolated_environment('rules-capture'), stdio='pipe')
    print(f'Isolated capture process created: {pid}', flush=True)
    try:
        session = device.attach(pid)
    except Exception:
        try:
            device.kill(pid)
        except frida.InvalidOperationError:
            pass
        log.close()
        raise
    session.on('detached', lambda *_: finished.set())
    log_lock = threading.Lock()
    def output(proc, fd, data):
        with log_lock:
            if proc == pid and not log.closed:
                log.write(data)
    device.on('output', output)
    script = session.create_script('''
const specs = SPECS;
let states = {};
function hex(p) { return Array.from(new Uint8Array(p.readByteArray(16)), x => x.toString(16).padStart(2, '0')).join(''); }
const hook = Process.mainModule.base.add(RVA);
Interceptor.attach(hook, {
 onEnter(args) {
  this.out = args[2]; this.tid = Process.getCurrentThreadId();
  const key = hex(args[1]);
  if (specs[key]) states[this.tid] = {key: key, chunks: [], lengths: specs[key].map(v => Math.ceil(v.length / 16))};
  this.state = states[this.tid];
 },
 onLeave() {
  const s = this.state; if (!s) return;
  s.chunks.push(new Uint8Array(this.out.readByteArray(16)));
  const count = s.chunks.length;
  if (s.lengths.includes(count)) {
   const data = new Uint8Array(count * 16);
   s.chunks.forEach((v,i) => data.set(v, i * 16));
   send({key:s.key}, data.buffer);
  }
  if (count >= Math.max(...s.lengths)) delete states[this.tid];
 }
});
'''.replace('SPECS', json.dumps(targets)).replace('RVA', str(args.decrypt_rva)))

    def message(msg, data):
        if msg['type'] != 'send':
            failures.append(msg)
            return
        for spec in targets[msg['payload']['key']]:
            if len(data) != (spec['length'] + 15) // 16 * 16:
                continue
            value = bytes(data)[:spec['length']]
            if hashlib.md5(value).hexdigest() != spec['md5']:
                continue
            name = spec['path'].removeprefix('res://').replace('/', '__')
            name = name[:-4] + '.gdc' if name.endswith('.gde') else name
            (plain_dir / name).write_bytes(value)
            results[spec['path']] = {**spec, 'file': name}

    script.on('message', message)
    script.load()
    print('Capture hook attached; loading resources without autoloads.', flush=True)
    device.resume(pid)
    started = time.monotonic()
    try:
        finished.wait(args.timeout)
    finally:
        try:
            device.kill(pid)
        except frida.InvalidOperationError:
            pass
        device.off('output', output)
        with log_lock:
            log.close()
    report = {'source_pck_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
              'source_exe_sha256': hashlib.sha256(exe.read_bytes()).hexdigest(),
              'captured': list(results.values()), 'missing': sorted(set(wanted) - set(results)),
              'errors': failures, 'seconds': time.monotonic() - started,
              'isolation': 'autoloads removed; workspace APPDATA; original game untouched'}
    (out / 'capture_manifest.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'captured': len(results), 'wanted': len(wanted), 'errors': len(failures),
                      'missing': report['missing'], 'seconds': report['seconds']}, ensure_ascii=False))
    if failures or len(results) != len(wanted):
        sys.exit(1)
    output, errors = gdre([f'--decompile={plain_dir / "*.gdc"}', '--bytecode=3.6',
                          f'--output={out / "decompiled"}'])
    (out / 'decompile.log').write_text(output + errors, encoding='utf-8')


if __name__ == '__main__':
    main()
