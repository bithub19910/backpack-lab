"""Allowlist original sources and redistributable tools; never package a local game build."""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
PUBLIC=ROOT/'outputs/github-source'
VERSION=json.loads((ROOT/'plugin/mod.json').read_text(encoding='utf-8'))['version']
RELEASE=ROOT/f'outputs/release/BackpackLab-{VERSION}-windows-x64'

def source_files():
    files=[]
    for pattern in ('plugin/godot/*.gd','plugin/windows/*.cs','plugin/docs/*.md','plugin/tests/*.gd','plugin/tests/test_*.py'):
        files += list(ROOT.glob(pattern))
    for name in ('native','pck','capture_rules','common_random','cosmetic_random','presentation_free','build_worker','build_plugin','build_windows','installer_backend','build_release','benchmark_precision','test_frontend','test_common_random','test_presentation','test_reuse','run_native'):
        files.append(ROOT/f'plugin/packaging/{name}.py')
    files += [ROOT/'plugin/mod.json',ROOT/'plugin/precision.json']
    return files

def prepare_source():
    PUBLIC.mkdir(parents=True,exist_ok=True)
    for source in source_files():
        dest=PUBLIC/source.relative_to(ROOT);dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(source,dest)
    for source in (ROOT/'plugin/release-template').rglob('*'):
        if source.is_file():
            dest=PUBLIC/source.relative_to(ROOT/'plugin/release-template');dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,dest)
    audit=[]
    for path in PUBLIC.rglob('*'):
        if not path.is_file() or '.git' in path.parts:continue
        if path.suffix.lower() in ('.exe','.dll','.pck','.gdc','.gde','.log','.pyc'):
            raise ValueError('Forbidden public file: '+str(path))
        data=path.read_bytes()
        if (b'gh'+b'p_') in data or (b'github_'+b'pat_') in data:
            raise ValueError('Potential private value in public file: '+str(path))
        audit.append({'path':path.relative_to(PUBLIC).as_posix(),'sha256':hashlib.sha256(data).hexdigest()})
    (ROOT/'outputs/release').mkdir(parents=True,exist_ok=True)
    (ROOT/'outputs/release/source-audit.json').write_text(json.dumps(audit,indent=2),encoding='utf-8')
    return audit

def package():
    from build_windows import compile_launcher
    audit=prepare_source()
    RELEASE.mkdir(parents=True,exist_ok=True)
    compile_launcher(RELEASE/'BackpackLab.exe')
    tools=RELEASE/'tools';tools.mkdir(exist_ok=True)
    gdre=Path(os.environ.get('BACKPACK_LAB_GDRE',str(ROOT/'data/staging/GDRE_tools-v2.6.4-windows/gdre_tools.exe')))
    for name in ('gdre_tools.exe','gdre_tools.pck','GodotMonoDecompNativeAOT.dll'):shutil.copy2(gdre.parent/name,tools/name)
    for row in audit:
        source=PUBLIC/row['path'];dest=RELEASE/'source'/row['path'];dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,dest)
    for name in ('README.md','LICENSE','THIRD_PARTY_NOTICES.md'):shutil.copy2(PUBLIC/name,RELEASE/name)
    shutil.copytree(PUBLIC/'licenses',RELEASE/'licenses',dirs_exist_ok=True)
    env=os.environ.copy()
    local=ROOT/'.tmp/release-tools'
    if local.exists() and sys.prefix==sys.base_prefix:env['PYTHONPATH']=str(local)+os.pathsep+env.get('PYTHONPATH','')
    subprocess.run([sys.executable,'-m','PyInstaller','--noconfirm','--clean','--onedir','--console',
        '--name','BackpackLabBuild','--distpath',str(ROOT/'outputs/release/backend-dist'),
        '--workpath',str(ROOT/'.tmp/pyinstaller'),'--specpath',str(ROOT/'.tmp'),
        '--paths',str(ROOT/'plugin/packaging'),'--collect-all','frida',str(ROOT/'plugin/packaging/installer_backend.py')],env=env,check=True)
    shutil.copytree(ROOT/'outputs/release/backend-dist/BackpackLabBuild',RELEASE/'backend',dirs_exist_ok=True)
    zip_path=Path(str(RELEASE)+'.zip')
    with zipfile.ZipFile(zip_path,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for p in RELEASE.rglob('*'):
            if p.is_file():z.write(p,p.relative_to(RELEASE.parent))
    source_zip=RELEASE.parent/f'BackpackLab-{VERSION}-source.zip'
    with zipfile.ZipFile(source_zip,'w',zipfile.ZIP_DEFLATED) as z:
        for row in audit:z.write(PUBLIC/row['path'],row['path'])
    (RELEASE.parent/'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in (zip_path,source_zip)),encoding='utf-8')
    print('Release ready:',zip_path,flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--source-only',action='store_true');args=parser.parse_args()
    if args.source_only:print('Audited source files:',len(prepare_source()))
    else:package()
