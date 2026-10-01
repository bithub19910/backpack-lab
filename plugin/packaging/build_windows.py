"""Compile the Windows GUI with the operating system's .NET Framework compiler."""
import os
import subprocess
from pathlib import Path
from native import ROOT

def compile_launcher(target):
    compiler=Path(os.environ.get('WINDIR','C:/Windows'))/'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    target=Path(target);target.parent.mkdir(parents=True,exist_ok=True)
    subprocess.run([str(compiler),'/nologo','/target:winexe','/optimize+',
                    '/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll',
                    '/reference:System.Web.Extensions.dll','/reference:Microsoft.CSharp.dll',
                    '/out:'+str(target),str(ROOT/'plugin/windows/BackpackLab.cs')],check=True,
                   creationflags=0x08000000)
    return target

if __name__=='__main__':compile_launcher(ROOT/'outputs/backpack-lab/BackpackLab.exe')
