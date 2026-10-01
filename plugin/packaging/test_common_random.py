"""Metamorphic checks: inert pig moves and +15 armor must not reshuffle attacks."""
import json
from native import ROOT, run_tool
from build_worker import OUTPUT
from pck import build_archive, read_entry, project_entries, encode_project, variant

def main():
    source = OUTPUT / 'BackpackLabWorker.pck'
    work = ROOT / 'data/local_runtime/common-random'
    work.mkdir(parents=True, exist_ok=True)
    settings = project_entries(read_entry(source, 'res://project.binary'))
    settings['autoload/BackpackLab'] = variant('*res://BackpackLab/CommonRandomTest.gd')
    settings['application/config/custom_user_dir_name'] = variant('BackpackLabCommonRandomTest')
    pack = work / 'test.pck'
    # Test-only worker overlay: add ambient presentation calls on every frame.
    # The shipping worker has no test switch or noise injection.
    noisy_pack = work / 'noise-worker.pck'
    worker = read_entry(source, 'res://BackpackLab/Worker.gd').decode()
    worker = worker.replace('func _process(_delta):', '''func _process(_delta):
	if running and not finishing and request.get("test_cosmetic_noise", false):
		for _i in 12:
			Util.lab_visual_rng.randf()
			Game.shopKeeper.randNum(7)
			Util.randBuffLabelDir()
		Game.classResources[Game.Classes.Ranger].getBuySound()
''')
    build_archive(source, noisy_pack, {'res://BackpackLab/Worker.gd': worker.encode()})
    pool = read_entry(source, 'res://BackpackLab/Pool.gd').decode()
    pool = pool.replace('if prewarm:', 'arguments += ["--main-pack", ' + json.dumps(noisy_pack.as_posix()) + ']\n\t\tif prewarm:')
    build_archive(source, pack, {'res://project.binary': encode_project(settings),
        'res://BackpackLab/Pool.gd': pool.encode(),
        'res://BackpackLab/CommonRandomTest.gd': (ROOT / 'plugin/tests/common_random.gd').read_bytes()})
    run = run_tool([OUTPUT / 'BackpackLabWorker.exe', '--no-window', '--audio-driver', 'Dummy', '--main-pack', pack], name='common-random', timeout=180)
    profile = work / 'profile/BackpackLabCommonRandomTest'
    log = (profile / 'logs/godot.log').read_text(encoding='utf-8', errors='replace')
    print(log[-6000:])
    report = json.loads((profile / 'report.json').read_text(encoding='utf-8'))
    assert run.returncode == 0 and 'SCRIPT ERROR:' not in log and all(report.values()), report
    print('Common random regression passed', len(report))

if __name__ == '__main__': main()
