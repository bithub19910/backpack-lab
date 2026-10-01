"""Build a mod from the user's installation. Never ship or upload captured game files."""
import argparse
import hashlib
import json
import os
import shutil
import sys
import traceback
from pathlib import Path

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def install(args):
    game=Path(args.game).resolve();dest=Path(args.destination).resolve();source=Path(args.source).resolve()
    if dest==game or game in dest.parents or dest in game.parents:
        raise ValueError('Mod 安装目录必须位于游戏目录之外。')
    if dest==Path(dest.anchor) or len(dest.parts)<3:
        raise ValueError('请选择独立的 Mod 文件夹。')
    spec=json.loads((source/'plugin/mod.json').read_text(encoding='utf-8'))
    for name,expected in spec['supported_files'].items():
        if not (game/name).is_file() or sha(game/name)!=expected:
            raise ValueError('仅支持指定版本的原版游戏，版本或文件不匹配：'+name)
    dest.mkdir(parents=True,exist_ok=True)
    marker=dest/'.backpack-lab-install'
    if any(dest.iterdir()) and not marker.exists():
        raise ValueError('安装目录不是空目录，也不是已有背包实验室安装。请选择新的空文件夹。')
    marker.write_text('BackpackLab installation v1\n',encoding='utf-8')
    buildroot=dest/'.build';buildroot.mkdir(exist_ok=True)
    # Only the allowlisted, original project source is bundled in a download.
    shutil.copytree(source/'plugin',buildroot/'plugin',dirs_exist_ok=True)
    stage=dest/'runtime.next'
    os.environ.update(BACKPACK_LAB_ROOT=str(buildroot),BACKPACK_LAB_GAME=str(game),
                      BACKPACK_LAB_GDRE=str(Path(args.gdre).resolve()),BACKPACK_LAB_OUTPUT=str(stage))
    print('正在读取并校验本机游戏资源…',flush=True)
    import capture_rules
    old_argv=sys.argv;sys.argv=['capture_rules','--timeout','180']
    try:capture_rules.main()
    finally:sys.argv=old_argv
    print('正在生成本地 Mod 与计算组件…',flush=True)
    import build_plugin
    build_plugin.main()
    manifest=json.loads((stage/'installed-source.json').read_text(encoding='utf-8'))
    assert sha(stage/'BackpackLab.pck')==manifest['plugin_sha256']
    for name,expected in manifest['worker_hashes'].items():assert sha(stage/'worker'/name)==expected
    runtime=dest/'runtime'
    # Preserve a recoverable previous version. Never alter the installed Steam files.
    if runtime.exists():
        import time
        runtime.rename(dest/('runtime.backup-'+str(time.time_ns())))
    stage.rename(runtime)
    launcher=dest/'BackpackLab.exe'
    if Path(args.launcher).resolve()!=launcher:shutil.copy2(args.launcher,launcher)
    (dest/'launcher-settings.json').write_text(json.dumps({'destination':str(dest)},ensure_ascii=False),encoding='utf-8')
    print('安装完成；原版游戏文件未改动。',flush=True)

def main():
    # The Windows GUI decodes redirected progress as UTF-8 on every locale.
    for stream in (sys.stdout, sys.stderr):
        if stream is not None and hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8')
    parser=argparse.ArgumentParser()
    for name in ('game','destination','source','gdre','launcher'):parser.add_argument('--'+name,required=True)
    args=parser.parse_args()
    logdir=Path(args.destination)
    try:install(args)
    except BaseException as exc:
        if (logdir/'.backpack-lab-install').is_file():
            (logdir/'install.log').write_text(traceback.format_exc(),encoding='utf-8')
        print('安装失败：'+str(exc),flush=True)
        raise

if __name__=='__main__':main()
