# Build

Requires Windows x64, Python 3.11, Frida 17.17.0, GDRE Tools 2.6.4, and the supported original Steam game. Source contains no captured game resources.

Set `BACKPACK_LAB_GAME` to the installed game directory, `BACKPACK_LAB_GDRE` to the official GDRE executable, and optionally `BACKPACK_LAB_OUTPUT` to a separate output directory. The game can also be located via Steam's Windows registry/library folders.

```powershell
python -m pip install frida==17.17.0 pyinstaller==6.16.0
python plugin/packaging/capture_rules.py
python plugin/packaging/build_plugin.py
python plugin/packaging/test_frontend.py
```

The capture runs an isolated, autoload-free engine copy under workspace APPDATA. Resource MD5s and the original game SHA-256 are checked before building. Game engine updates require a new verified capture and compatibility review, including the capture hook RVA; never guess a new RVA for a different EXE.

`build_windows.py` uses Windows .NET Framework's C# compiler. `build_release.py` packages only original source and redistributable tools, then builds an offline installer backend. A source ZIP can be made without the game. Do not upload `data/`, `outputs/backpack-lab/`, worker binaries, local captures, logs or player/opponent data.

Native integration: `test_frontend.py` exercises the game scene, manual requests, keyboard focus, native slots, shop preview, cancellation and postbattle behavior. `benchmark_precision.py` expects anonymized build codes in `data/local_runtime/precision/cases.json`; its measurement summary is published, its underlying opponent pool is not. Test packs/results are local-only.
