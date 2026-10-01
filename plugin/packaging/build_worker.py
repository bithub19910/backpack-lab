"""Build a local-only worker from the user's verified installed resources."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

from native import GAME, ROOT, gdre, run_tool
from pck import build_archive, encode_project, project_entries, read_entry, variant

RULES = ROOT / 'data/local_rules/current'
OUTPUT = Path(os.environ.get('BACKPACK_LAB_OUTPUT', str(ROOT / 'outputs/backpack-lab'))) / 'worker'


def replace_function(source: str, name: str, body: str) -> str:
    pattern = rf'(?m)^func {re.escape(name)}\([^\n]*\n(?:[\t ].*\n|\n)*'
    match = re.search(pattern, source)
    if match is None:
        raise ValueError(f'Missing native method: {name}')
    header = match.group().splitlines()[0]
    return source[:match.start()] + header + '\n' + body.rstrip() + '\n\n' + source[match.end():]


def build():
    manifest = json.loads((RULES / 'capture_manifest.json').read_text(encoding='utf-8'))
    source = GAME / 'BackpackBattles.pck'
    actual = hashlib.sha256(source.read_bytes()).hexdigest()
    if actual != manifest['source_pck_sha256'] or manifest['missing'] or manifest['errors']:
        raise ValueError('Installed rules differ from the completely verified capture')
    OUTPUT.mkdir(parents=True, exist_ok=True)
    patched = ROOT / 'data/local_runtime/worker-build'
    patched.mkdir(parents=True, exist_ok=True)
    game = (RULES / 'decompiled/Core__Game.gd').read_text(encoding='utf-8')
    game = replace_function(game, 'ready_deferred', '\tget_node("/root/BackpackLab").call_deferred("boot")')
    game = replace_function(game, 'endCombat', '\tif fightEnded:\n\t\treturn\n\tfightEnded = true\n\tget_node("/root/BackpackLab").native_end(OPPONENT.curHealth <= 0)')
    game = replace_function(game, 'isBelowLeague', '\treturn int(lab_context.get("league", Leagues.Master)) < league')
    game = replace_function(game, 'isAtLeastInLeague', '\treturn not isBelowLeague(league)')
    for method in ('saveGame', 'saveRunState'):
        game = replace_function(game, method, '\tpass')
    game += '\nvar lab_context = {}\n'
    (patched / 'Game.gd').write_text(game, encoding='utf-8')
    database = (RULES / 'decompiled/Core__RunDatabase.gd').read_text(encoding='utf-8')
    database = replace_function(database, '_ready', '\tpause_mode = Node.PAUSE_MODE_PROCESS\n\tcall_deferred("ready_deferred")')
    database = replace_function(database, 'ready_deferred', '\tlobbies = load("res://Utility/Lobbies.gd").new()\n\tadd_child(lobbies)')
    for method in ('sendRunRequest', 'pushRun', 'actuallyPersistRun'):
        database = replace_function(database, method, '\tpass')
    (patched / 'RunDatabase.gd').write_text(database, encoding='utf-8')
    # A trial ends early, unlike the game's animated transition. Global timers
    # (notably pooled-particle returns) can still hold nodes from that trial.
    utility = (RULES / 'decompiled/Utility__Util.gd').read_text(encoding='utf-8')
    utility, tracked = re.subn(r'(?m)^(\tvar timer = get_tree\(\)\.create_timer\([^\n]+\))$',
                              r'\1\n\tlab_delayed_timers.append(timer)', utility)
    if tracked != 4:
        raise ValueError('Native delayed-call helpers changed')
    utility += '''
var lab_delayed_timers = []

func lab_clear_delayed_calls():
	var cancelled = {}
	for timer in lab_delayed_timers:
		if not is_instance_valid(timer):
			continue
		for connection in timer.get_signal_connection_list("timeout"):
			if is_instance_valid(connection.target):
				cancelled[connection.method] = cancelled.get(connection.method, 0) + 1
				timer.disconnect("timeout", connection.target, connection.method)
	lab_delayed_timers.clear()
	return cancelled
'''
    (patched / 'Util.gd').write_text(utility, encoding='utf-8')
    # Native options reapply fullscreen after --no-window and expose the worker.
    settings = (RULES / 'decompiled/Utility__Settings.gd').read_text(encoding='utf-8')
    for method in ('setWindowMode', 'clipToScreen'):
        settings = replace_function(settings, method, '\tpass')
    (patched / 'Settings.gd').write_text(settings, encoding='utf-8')
    # Dragging/shadows and shader cooldown fills have no combat state effects.
    item = (RULES / 'decompiled/Items__Item.gd').read_text(encoding='utf-8')
    for method in ('_process', 'showCooldown'):
        item = replace_function(item, method, '\tpass')
    (patched / 'Item.gd').write_text(item, encoding='utf-8')
    combat_timer = (RULES / 'decompiled/Interface__CombatTimer__CombatTimer.gd').read_text(encoding='utf-8')
    combat_timer = replace_function(combat_timer, 'updateTimer', '\tpass')
    (patched / 'CombatTimer.gd').write_text(combat_timer, encoding='utf-8')
    # Pure cosmetic flicker schedules random idle callbacks on newly built items.
    # Removing it in BOTH execution paths isolates combat RNG from node age.
    flicker = (RULES / 'decompiled/Items__Animations__FlickerAnimation.gd').read_text(encoding='utf-8')
    for method in ('_ready', 'onAnimationEnded', 'playAni'):
        flicker = replace_function(flicker, method, '\tpass')
    (patched / 'FlickerAnimation.gd').write_text(flicker, encoding='utf-8')
    character = (RULES / 'decompiled/Core__Character.gd').read_text(encoding='utf-8')
    # Idle animation timers consume the shared RNG depending on object age.
    # They have no combat effect; disable them in cold and reused workers alike.
    character = replace_function(character, 'randAnimationSpeed', '\tpass')
    (patched / 'Character.gd').write_text(character, encoding='utf-8')
    from common_random import patch_native
    random_overrides = patch_native(RULES, patched, item, character)
    compiler = (RULES / 'decompiled/Utility__MaterialCompiler.gd').read_text(encoding='utf-8')
    compiler = replace_function(compiler, '_ready', '\tcall_deferred("lab_finish")')
    compiler += '\nfunc lab_finish():\n\temit_signal("finished_loading_materials")\n\tqueue_free()\n'
    (patched / 'MaterialCompiler.gd').write_text(compiler, encoding='utf-8')
    output, errors = gdre(['--compile=' + str(patched / '*.gd'), '--bytecode=3.6',
                          '--output=' + str(patched)])
    (patched / 'compile.log').write_text(output + errors, encoding='utf-8')
    project = project_entries(read_entry(source, 'res://project.binary'))
    project['application/config/name'] = variant('Backpack Lab Worker')
    project['application/config/use_custom_user_dir'] = variant(True)
    project['application/config/custom_user_dir_name'] = variant('BackpackLabWorker')
    project['_custom_features'] = variant('full_version,disable_steam_integration')
    project['display/window/vsync/use_vsync'] = variant(False)
    project['display/window/size/fullscreen'] = variant(False)
    project['display/window/size/borderless'] = variant(False)
    project['application/run/low_processor_mode_sleep_usec'] = variant(0)
    project['autoload/BackpackLab'] = variant('*res://BackpackLab/Worker.gd')
    overrides = {'res://project.binary': encode_project(project)}
    for name, folder in (('Game', 'Core'), ('RunDatabase', 'Core'), ('Util', 'Utility'), ('Settings', 'Utility'), ('Item', 'Items'), ('CombatTimer', 'Interface/CombatTimer'), ('MaterialCompiler', 'Utility'), ('FlickerAnimation', 'Items/Animations'), ('Character', 'Core')):
        overrides[f'res://BackpackLab/{name}.gdc'] = (patched / f'{name}.gdc').read_bytes()
        overrides[f'res://{folder}/{name}.gd.remap'] = f'[remap]\npath="res://BackpackLab/{name}.gdc"\n'.encode()
    for path in (ROOT / 'plugin/godot').glob('*.gd'):
        overrides[f'res://BackpackLab/{path.name}'] = path.read_bytes()
    for original, name in random_overrides.items():
        overrides[f'res://BackpackLab/{name}.gdc'] = (patched / f'{name}.gdc').read_bytes()
        overrides[original + '.remap'] = f'[remap]\npath="res://BackpackLab/{name}.gdc"\n'.encode()
    preview = OUTPUT / 'smoke.json'
    if preview.exists():
        overrides['res://BackpackLab/preview.json'] = preview.read_bytes()
    overrides['res://BackpackLab/rules.json'] = json.dumps({
        'schema': 1, 'game_version': '1.1.9b', 'source_pck_sha256': actual,
        'engine_sha256': manifest['source_exe_sha256'], 'worker_version': json.loads((ROOT / 'plugin/mod.json').read_text(encoding='utf-8'))['version'],
        'implementation_sha256': hashlib.sha256(b''.join(path.read_bytes() for path in sorted((ROOT / 'plugin/godot').glob('*.gd'))) + b''.join((ROOT / ('plugin/packaging/' + name + '.py')).read_bytes() for name in ['build_worker', 'common_random', 'cosmetic_random', 'presentation_free'])).hexdigest(),
    }).encode()
    build_archive(source, OUTPUT / 'BackpackLabWorker.pck', overrides)
    shutil.copy2(GAME / 'BackpackBattles.exe', OUTPUT / 'BackpackLabWorker.exe')
    for name in ('steam_api64.dll', 'libgdsqlite.dll'):
        shutil.copy2(GAME / name, OUTPUT / name)
    print('Worker built:', OUTPUT, flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--probe', action='store_true')
    args = parser.parse_args()
    build()
    if args.probe:
        native_log = ROOT / 'data/local_runtime/worker/profile/BackpackLabWorker/logs/godot.log'
        if native_log.exists():
            native_log.unlink()
        timed_out = False
        try:
            result = run_tool([OUTPUT / 'BackpackLabWorker.exe', '--no-window', '--audio-driver', 'Dummy',
                               '--fixed-fps', '60', '--lab-probe'], name='worker', timeout=25)
        except subprocess.TimeoutExpired as exc:
            timed_out = True
        text = native_log.read_text(encoding='utf-8', errors='replace') if native_log.exists() else ''
        (OUTPUT / 'probe.log').write_text(text, encoding='utf-8')
        print(text[-9000:])
        if timed_out or result.returncode or 'LAB_NATIVE_READY ' not in text or 'SCRIPT ERROR:' in text:
            raise SystemExit('Native worker probe failed; inspect probe.log')


if __name__ == '__main__':
    main()
