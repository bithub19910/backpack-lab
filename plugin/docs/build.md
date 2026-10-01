# Build

Requires Windows x64, Python 3.11, Frida 17.17.0, GDRE Tools 2.6.4, and the supported original Steam game. Source contains no captured game resources.

Set `BACKPACK_LAB_GAME` to the installed game directory, `BACKPACK_LAB_GDRE` to the official GDRE executable, and optionally `BACKPACK_LAB_OUTPUT` to a separate output directory. The game can also be located via Steam's Windows registry/library folders.

```powershell
python -m venv .venv
.venv\Scripts\python -m pip install frida==17.17.0 pyinstaller==6.16.0
.venv\Scripts\python plugin/packaging/capture_rules.py
.venv\Scripts\python plugin/packaging/build_plugin.py
.venv\Scripts\python plugin/packaging/test_frontend.py
.venv\Scripts\python plugin/packaging/test_common_random.py
```

Use the same isolated environment for `build_release.py`. Obsolete global backports such as `pathlib` can make PyInstaller reject an otherwise valid build; do not uninstall unrelated user dependencies to work around that.

The capture runs an isolated, autoload-free engine copy under workspace APPDATA. Resource MD5s and the original game SHA-256 are checked before building. Game engine updates require a new verified capture and compatibility review, including the capture hook RVA; never guess a new RVA for a different EXE.

`build_windows.py` uses Windows .NET Framework's C# compiler. `build_release.py` packages only original source and redistributable tools, then builds an offline installer backend. A source ZIP can be made without the game. Do not upload `data/`, `outputs/backpack-lab/`, worker binaries, local captures, logs or player/opponent data.

Native integration: `test_frontend.py` exercises the game scene, manual requests, keyboard focus, native slots, shop preview, cancellation and postbattle behavior. `benchmark_precision.py` expects anonymized build codes in `data/local_runtime/precision/cases.json`; its measurement summary is published, its underlying opponent pool is not. Test packs/results are local-only.

`test_reuse.py` compares object reuse with full reconstruction using the same fixed sample sequence. It requires private historical fixtures from the earlier local precision run, covers six classes and two modes, and checks removal/addition, repeated execution and startup prewarming. This is deterministic regression testing, not independent-seed resampling. Public CI does not have these game resources or fixtures.

See [common random samples](common-random.md) for stable identities, native RNG patch boundaries and regression acceptance criteria. `common_random.py` transforms locally captured scripts during installation; its original transformation code is shipped, the resulting game scripts are not.

For 1.0 presentation gates, preserve a previous verified `test_reuse.py` session directory before rebuilding. After running the new reuse suite, use `test_presentation.py --reference-results <old-session> --current-results <new-session>` to compare all 720 trials exactly and run the test-only pool-allocation probe. These paths contain private local fixtures. Run performance suites sequentially; concurrent engine runs distort timings. See [presentation boundaries](presentation.md).
