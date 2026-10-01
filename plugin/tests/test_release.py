import argparse
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('installer_backend',ROOT/'plugin/packaging/installer_backend.py')
backend=importlib.util.module_from_spec(spec);spec.loader.exec_module(backend)

class ReleaseGuards(unittest.TestCase):
    def test_reject_game_directory_and_children_without_writing(self):
        with tempfile.TemporaryDirectory() as folder:
            game=Path(folder)/'Game';game.mkdir()
            for dest in (game,game/'Mods',game.parent):
                with self.assertRaises(ValueError):
                    backend.install(argparse.Namespace(game=str(game),destination=str(dest),source=folder))
            self.assertEqual(list(game.iterdir()),[])

    def test_source_manifest_does_not_contain_machine_paths(self):
        import json
        spec=json.loads((ROOT/'plugin/mod.json').read_text(encoding='utf-8'))
        self.assertEqual(spec['entrypoint'],'BackpackLab.exe')
        self.assertEqual(spec['license'],'MIT')
        self.assertEqual(set(spec['supported_files']),{'BackpackBattles.exe','BackpackBattles.pck','steam_api64.dll','libgdsqlite.dll'})
        self.assertTrue(all(len(h)==64 for h in spec['supported_files'].values()))

    def test_historical_precision_fixture_is_not_live_accuracy(self):
        import json
        p=json.loads((ROOT/'plugin/precision.json').read_text(encoding='utf-8'))
        self.assertEqual(p['trial_count'],2400)
        self.assertEqual(len(p['cases']),12)
        self.assertGreaterEqual(p['mean_error_percent'],0)
        self.assertEqual(p['batch_size'],10)

    def test_random_transformer_is_in_public_build_sources(self):
        import ast
        source=(ROOT/'plugin/packaging/build_release.py').read_text(encoding='utf-8')
        tree=ast.parse(source)
        names=[node.value for node in ast.walk(tree) if isinstance(node,ast.Constant) and isinstance(node.value,str)]
        self.assertIn('common_random',names)
        self.assertIn('cosmetic_random',names)
        self.assertIn('presentation_free',names)
        self.assertIn('test_presentation',names)
        self.assertIn('test_common_random',names)
        builder=(ROOT/'plugin/packaging/build_worker.py').read_text(encoding='utf-8')
        self.assertIn('from common_random import patch_native',builder)

if __name__=='__main__':unittest.main()
