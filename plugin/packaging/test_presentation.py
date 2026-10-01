"""Local native audit and cross-version checks for worker presentation gates."""
import argparse
import json
from pathlib import Path

from native import ROOT, run_tool
from build_worker import OUTPUT, RULES
from pck import build_archive, read_entry, project_entries, encode_project, variant


def compare(reference, current):
    fields = ('seed', 'outcome', 'duration', 'sides', 'remaining_health')
    rows = []
    for old_file in sorted(reference.glob('class*.json')):
        old = json.loads(old_file.read_text(encoding='utf-8'))
        new_file = current / old_file.name
        if not new_file.exists():
            raise AssertionError('Missing new result: ' + old_file.name)
        new = json.loads(new_file.read_text(encoding='utf-8'))
        assert old['status'] == new['status'] == 'ok'
        for key in ('mode', 'player', 'opponent', 'context', 'seed', 'runs', 'horizon', 'reuse_objects'):
            assert old['request'].get(key) == new['request'].get(key), (old_file.name, 'different input', key)
        assert old['count'] == new['count']
        assert len(old['trials']) == len(new['trials']) == new['count']
        for index, (a, b) in enumerate(zip(old['trials'], new['trials'])):
            for field in fields:
                assert a[field] == b[field], (old_file.name, index, field)
        rows.append({'case': old_file.name, 'trials': new['count'], 'exact': True,
                     'before_ms': old['elapsed_ms'], 'after_ms': new['elapsed_ms']})
    assert len(rows) == 72, 'Expected all six professions, both modes and six reuse conditions'
    return rows


def probe(reference):
    source = OUTPUT / 'BackpackLabWorker.pck'
    work = ROOT / 'data/local_runtime/presentation'
    work.mkdir(parents=True, exist_ok=True)
    settings = project_entries(read_entry(source, 'res://project.binary'))
    settings['autoload/BackpackLab'] = variant('*res://BackpackLab/AuditPresentation.gd')
    settings['application/config/custom_user_dir_name'] = variant('BackpackLabPresentationAudit')
    pack = work / 'audit.pck'
    build_archive(source, pack, {'res://project.binary': encode_project(settings),
        'res://BackpackLab/AuditPresentation.gd': (ROOT / 'plugin/tests/audit_presentation.gd').read_bytes()})
    run = run_tool([OUTPUT / 'BackpackLabWorker.exe', '--no-window', '--audio-driver', 'Dummy', '--main-pack', pack], name='presentation', timeout=120)
    log = (work / 'profile/BackpackLabPresentationAudit/logs/godot.log').read_text(encoding='utf-8', errors='replace')
    assert run.returncode == 0 and 'LAB_ANIMATION_AUDIT ' in log and 'SCRIPT ERROR:' not in log, log[-3000:]
    audit = json.loads((work / 'profile/BackpackLabPresentationAudit/animation-audit.json').read_text(encoding='utf-8'))

    # Instrument only this test PCK. Count actual pool entry calls during combat;
    # electrical charges must remain, pure display nodes must not be allocated.
    pool = (RULES / 'decompiled/Utility__ObjectPool.gd').read_text(encoding='utf-8')
    pool = pool.replace('func instance(scene: PackedScene):', 'func instance(scene: PackedScene):\n\tlab_counts[scene.resource_path] = lab_counts.get(scene.resource_path, 0) + 1')
    pool += '\nvar lab_counts = {}\n'
    worker = read_entry(source, 'res://BackpackLab/Worker.gd').decode()
    worker = worker.replace('func activate_trial():', 'func activate_trial():\n\tObjectPool.lab_counts.clear()')
    worker = worker.replace('func finish_trial():', 'func finish_trial():\n\tprint("LAB_VISUAL_POOL ", JSON.print(ObjectPool.lab_counts))')
    instrumented = work / 'instrumented.pck'
    build_archive(source, instrumented, {
        'res://BackpackLab/Worker.gd': worker.encode(),
        'res://BackpackLab/ProbeObjectPool.gd': pool.encode(),
        'res://Utility/ObjectPool.gd.remap': b'[remap]\npath="res://BackpackLab/ProbeObjectPool.gd"\n'})
    baseline = json.loads((reference / 'class6-opponent-cold.json').read_text(encoding='utf-8'))
    request = baseline['request']
    request['rules'] = json.loads(read_entry(source, 'res://BackpackLab/rules.json'))
    request['runs'] = 2
    input_path = work / 'input.json'
    output = work / 'result.json'
    input_path.write_text(json.dumps(request), encoding='utf-8')
    run = run_tool([OUTPUT / 'BackpackLabWorker.exe', '--no-window', '--audio-driver', 'Dummy', '--fixed-fps', '60',
                    '--main-pack', instrumented, '--lab-request=' + str(input_path), '--lab-output=' + str(output)], name='presentation-probe', timeout=120)
    log = (ROOT / 'data/local_runtime/presentation-probe/profile/BackpackLabWorker/logs/godot.log').read_text(encoding='utf-8', errors='replace')
    assert run.returncode == 0 and 'SCRIPT ERROR:' not in log, log[-4000:]
    counts = [json.loads(line.split('LAB_VISUAL_POOL ', 1)[1]) for line in log.splitlines() if 'LAB_VISUAL_POOL ' in line]
    assert len(counts) == 2, log[-4000:]
    for row in counts:
        assert row and all(path == 'res://Items/ElectricalCharge.tscn' for path in row), row
    result = json.loads(output.read_text(encoding='utf-8'))
    assert result['status'] == 'ok' and result['count'] == 2
    for i, trial in enumerate(result['trials']):
        for key in ('seed', 'outcome', 'duration', 'sides', 'remaining_health'):
            assert trial[key] == baseline['trials'][i][key], ('instrumented', i, key)
    report = {'native_animation_method_tracks': audit['calls'], 'combat_pool_calls': counts,
              'only_rule_charges_allocated': True, 'instrumented_results_equal': True}
    (work / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--reference-results', required=True, type=Path)
    parser.add_argument('--current-results', type=Path)
    args = parser.parse_args()
    if args.current_results:
        rows = compare(args.reference_results, args.current_results)
        out = ROOT / 'data/local_runtime/presentation/comparison.json'
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(rows, indent=2), encoding='utf-8')
        print('Exact native reference comparisons:', sum(row['trials'] for row in rows))
    probe(args.reference_results)


if __name__ == '__main__':
    main()
