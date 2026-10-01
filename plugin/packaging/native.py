"""Run development helpers with writable state confined to this workspace."""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ROOT = Path(os.environ.get('BACKPACK_LAB_ROOT', str(ROOT)))
def find_game():
    if os.environ.get('BACKPACK_LAB_GAME'):
        return Path(os.environ['BACKPACK_LAB_GAME'])
    installed = ROOT / 'outputs/backpack-lab/installed-source.json'
    if installed.is_file():
        import json
        return Path(json.loads(installed.read_text(encoding='utf-8'))['game_directory'])
    import re
    import winreg
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Software\Valve\Steam') as key:
        steam = Path(winreg.QueryValueEx(key, 'SteamPath')[0])
    roots = [steam]
    libraries = steam / 'steamapps/libraryfolders.vdf'
    if libraries.exists():
        roots += [Path(p.replace('\\\\', '\\')) for p in re.findall(r'"path"\s*"([^"]+)"', libraries.read_text(encoding='utf-8'))]
    for root in roots:
        game = root / 'steamapps/common/Backpack Battles'
        if (game / 'BackpackBattles.exe').is_file(): return game
    raise FileNotFoundError('Set BACKPACK_LAB_GAME to the installed Backpack Battles directory')

GAME = find_game()
GDRE = Path(os.environ.get('BACKPACK_LAB_GDRE', str(ROOT / 'data/staging/GDRE_tools-v2.6.4-windows/gdre_tools.exe')))


def isolated_environment(name='tools') -> dict[str, str]:
    env = os.environ.copy()
    profile = ROOT / 'data/local_runtime' / name / 'profile'
    profile.mkdir(parents=True, exist_ok=True)
    env['APPDATA'] = str(profile)
    env['LOCALAPPDATA'] = str(profile)
    return env


def run_tool(arguments, name='tools', timeout=60):
    return subprocess.run([str(a) for a in arguments], env=isolated_environment(name),
                          capture_output=True, timeout=timeout, creationflags=0x08000000)


def gdre(arguments, timeout=120):
    result = run_tool([GDRE, '--headless', *[str(a).replace('\\', '/') for a in arguments]], timeout=timeout)
    output = result.stdout.decode('utf-8', errors='replace')
    errors = result.stderr.decode('utf-8', errors='replace')
    if result.returncode:
        raise RuntimeError(f'GDRE exited {result.returncode}: {output}\n{errors}')
    return output, errors
