"""Exercise the production adapter with original game flow in an offline test profile."""
import json
from native import ROOT, run_tool
from build_worker import OUTPUT
from pck import build_archive, read_entry, project_entries, encode_project, variant

DRIVER = (ROOT / 'plugin/tests/frontend_v2.gd').read_text(encoding='utf-8')


def main():
    source = OUTPUT.parent / 'BackpackLab.pck'
    path = ROOT / 'data/local_runtime/frontend'
    path.mkdir(parents=True, exist_ok=True)
    settings = project_entries(read_entry(source, 'res://project.binary'))
    settings['_custom_features'] = variant('full_version,disable_steam_integration')
    settings['application/config/use_custom_user_dir'] = variant(True)
    settings['application/config/custom_user_dir_name'] = variant('BackpackLabFrontendTest')
    settings['autoload/LabUiTestDriver'] = variant('*res://BackpackLab/TestDriver.gd')
    database = read_entry(OUTPUT / 'BackpackLabWorker.pck', 'res://BackpackLab/RunDatabase.gdc')
    build_archive(source, path / 'frontend.pck', {'res://project.binary': encode_project(settings),
        'res://BackpackLab/TestDriver.gd': DRIVER.encode(),
        'res://BackpackLab/RunDatabase.gdc': database,
        'res://Core/RunDatabase.gd.remap': b'[remap]\npath="res://BackpackLab/RunDatabase.gdc"\n'})
    result = run_tool([OUTPUT / 'BackpackLabWorker.exe', '--no-window', '--audio-driver', 'Dummy',
        '--main-pack', path / 'frontend.pck', '--lab-worker=' + str(OUTPUT / 'BackpackLabWorker.exe')],
        name='frontend', timeout=240)
    profile = ROOT / 'data/local_runtime/frontend/profile/BackpackLabFrontendTest'
    log = (profile / 'logs/godot.log').read_text(encoding='utf-8', errors='replace')
    print(log[-6500:])
    report = json.loads((profile / 'report.json').read_text(encoding='utf-8'))
    print(json.dumps(report, ensure_ascii=False))
    assert result.returncode == 0 and 'SCRIPT ERROR:' not in log
    assert all(report.values()), report
    print('Frontend integration passed')

if __name__ == '__main__':
    main()
