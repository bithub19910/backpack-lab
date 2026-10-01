"""Differential test of private worker object reuse against full reconstruction."""
import json
from native import ROOT, run_tool
from build_worker import OUTPUT
from pck import build_archive, project_entries, read_entry, encode_project, variant


def main():
    work = ROOT / 'data/local_runtime/reuse'
    work.mkdir(parents=True, exist_ok=True)
    cases = []
    prior = ROOT / 'data/local_runtime/precision/profile/BackpackLabPrecision'
    for session in sorted(prior.glob('session-*'), reverse=True):
        for path in sorted(session.glob('*.json')):
            data = json.loads(path.read_text(encoding='utf-8'))
            if 'trials' not in data or 'request' not in data:
                continue
            request = data['request']
            identity = (request['player']['class'], request['mode'])
            if any((r['player']['class'], r['mode']) == identity for r in cases):
                continue
            request['id'] = 'class%s-%s' % identity
            cases.append(request)
        if len(cases) >= 12:
            break
    if not cases:
        raise RuntimeError('Local historical precision fixtures are required')
    source = OUTPUT / 'BackpackLabWorker.pck'
    settings = project_entries(read_entry(source, 'res://project.binary'))
    settings['autoload/BackpackLab'] = variant('*res://BackpackLab/ReuseTest.gd')
    settings['application/config/custom_user_dir_name'] = variant('BackpackLabReuseTest')
    pack = work / 'reuse.pck'
    build_archive(source, pack, {'res://project.binary': encode_project(settings),
        'res://BackpackLab/ReuseTest.gd': (ROOT / 'plugin/tests/reuse.gd').read_bytes(),
        'res://BackpackLab/reuse-cases.json': json.dumps(cases).encode()})
    result = run_tool([OUTPUT / 'BackpackLabWorker.exe', '--no-window', '--audio-driver', 'Dummy',
                       '--main-pack', pack], name='reuse', timeout=600)
    profile = work / 'profile/BackpackLabReuseTest'
    log = (profile / 'logs/godot.log').read_text(encoding='utf-8', errors='replace')
    print(log[-6000:])
    report = json.loads((profile / 'report.json').read_text(encoding='utf-8'))
    (work / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    assert result.returncode == 0 and 'SCRIPT ERROR:' not in log
    assert len(report['checks']) == 4 * len(cases) + 1 and all(report['checks'].values()), report['checks']
    assert any(c['reused'] > 0 for c in report['cases'])
    print('Object reuse matches full reconstruction:', len(cases), 'conditions')


if __name__ == '__main__':
    main()
