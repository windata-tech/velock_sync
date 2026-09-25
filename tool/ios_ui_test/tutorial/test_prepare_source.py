"""Offline-only preparation guard and adapter tests; no simulators touched."""
import contextlib
import io
import json
from pathlib import Path
import plistlib
import re
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import prepare_source as prep


class PreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.device = self.root / 'new-source'
        self.device.mkdir()
        self.config = {'devices': {'source': 'new-source', 'replica': 'new-replica'}}

    def container(self, identifier):
        path = self.device / 'data/Containers/Data/Application' / identifier
        path.mkdir(parents=True)
        (path / '.com.apple.mobile_container_manager.metadata.plist').write_bytes(
            plistlib.dumps({'MCMMetadataIdentifier': identifier}))
        return path

    def test_new_source_initialization_allowed(self):
        self.assertEqual(prep.preflight(self.config, 'new-source', 'initialize', self.root), self.device)

    def test_source_mismatch_and_replica_only_rejected(self):
        with self.assertRaises(ValueError):
            prep.preflight(self.config, 'old-source', 'initialize', self.root)
        with self.assertRaises(ValueError):
            prep.preflight(dict(self.config, replica_only=True), 'new-source', 'initialize', self.root)

    def test_missing_device_rejected(self):
        self.device.rmdir()
        with self.assertRaises(ValueError):
            prep.preflight(self.config, 'new-source', 'initialize', self.root)

    def test_existing_database_preserved_and_rejected(self):
        app = self.container('tech.windata.velock')
        (app / 'Documents').mkdir()
        database = app / 'Documents/venyoreDb'
        database.write_bytes(b'preserve-existing-vault')
        with self.assertRaises(ValueError):
            prep.preflight(self.config, 'new-source', 'initialize', self.root)
        self.assertEqual(database.read_bytes(), b'preserve-existing-vault')

    def test_all_continuation_phases_use_history_gate(self):
        for phase in ('document', 'text', 'photo', 'verify'):
            with self.subTest(phase=phase), patch.object(prep, 'verify_recording_history', side_effect=ValueError('published')) as gate:
                with self.assertRaises(ValueError):
                    prep.preflight(self.config, 'new-source', phase, self.root)
                gate.assert_called_once_with(self.config, devices_root=self.root)

    def test_generated_png_dimensions_required(self):
        app = self.container('tech.windata.velock.crossapp.uitest.host')
        folder = app / 'Documents/VelockSync-E2E-Source'
        folder.mkdir(parents=True)
        image = folder / 'velock-sync-e2e-proof.png'
        for dimensions in ((1, 1), (960, 640)):
            image.write_bytes(b'\x89PNG\r\n\x1a\n' + struct.pack('>I', 13) + b'IHDR' + struct.pack('>II', *dimensions))
            if dimensions == (1, 1):
                with self.assertRaises(ValueError):
                    prep.photo_fixture(self.device)
            else:
                self.assertEqual(prep.photo_fixture(self.device), image)
        image.write_bytes(b'not-an-image')
        with self.assertRaises(ValueError):
            prep.photo_fixture(self.device)

    def test_adapter_extension_is_temporary_even_on_failure(self):
        old_argv, old_tests = sys.argv, prep.probe.TESTS
        def run():
            self.assertIn('testSeedVelockBusinessData', prep.probe.TESTS)
            self.assertIn('testProbeVelockMediaImport', prep.probe.TESTS)
            self.assertIn('--test', sys.argv)
            raise RuntimeError('test failure')
        with patch.object(prep.probe, 'main', side_effect=run), self.assertRaises(RuntimeError):
            prep.run_probe(['--take', 'fresh'], 'testSeedVelockBusinessData')
        self.assertIs(sys.argv, old_argv)
        self.assertIs(prep.probe.TESTS, old_tests)

    def test_check_has_no_device_calls(self):
        config = dict(self.config, artifact_root=str(self.root), velock_app=str(self.root / 'production.app'))
        path = self.root / 'config.json'
        path.write_text(json.dumps(config))
        app = self.root / 'fixture.app'
        app.mkdir()
        (app / 'Info.plist').write_bytes(b'fixture')
        with patch.object(prep, 'validate'), patch.object(prep, 'preflight'), patch.object(prep, 'run_probe') as run, patch.object(prep.subprocess, 'run') as command, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(prep.main(['--config', str(path), '--source', 'new-source', '--phase', 'initialize', '--take', 'new-take', '--app', str(app), '--check']), 0)
            run.assert_not_called()
            command.assert_not_called()
        self.assertFalse((self.root / 'new-take').exists())


class FreshPickerStaticTests(unittest.TestCase):
    """Source-contract regression only; not a substitute for native UI tests."""

    @classmethod
    def setUpClass(cls):
        path = Path(__file__).resolve().parents[3] / 'ui_test_harness/CrossAppUITests/CrossAppUITests.swift'
        # Ignore comments so an obsolete selector mentioned in prose cannot
        # satisfy the guard. Bound checks to this test, not unrelated helpers.
        cls.source = re.sub(r'//[^\n]*|/\*.*?\*/', '', path.read_text(), flags=re.S)
        match = re.search(r'func testTutorialImportText\(\).*?(?=\n    (?:private )?func |\Z)', cls.source, re.S)
        if match is None:
            raise AssertionError('Tutorial TXT preparation entry missing')
        cls.body = match.group()

    def test_add_uses_exact_button_helper_not_empty_state_contains(self):
        declaration = re.search(r'let add\s*=\s*(.*?)\n\s*if ', self.body, re.S)
        self.assertIsNotNone(declaration)
        selector = declaration.group(1)
        self.assertRegex(selector, r'tutorialNode\(velockApp,\s*\[')
        self.assertIn('"tkBtn_files_add"', selector)
        self.assertIn('"添加"', selector)
        self.assertIn('"Add"', selector)
        self.assertRegex(selector, r'buttons:\s*true\s*\)')
        self.assertNotIn('tutorialContains', selector)
        self.assertNotIn('CONTAINS', selector)
        helper = re.search(r'private func tutorialNode\(.*?(?=\n    private func )', self.source, re.S)
        self.assertIsNotNone(helper)
        self.assertIn('label IN %@ OR identifier IN %@', helper.group())
        self.assertIn('buttons ? app.buttons', helper.group())

    def test_recents_switches_to_browse_before_native_root_wait(self):
        self.assertRegex(self.body, r'let browseTab\s*=\s*velockApp\.tabBars\["DOC\.browsingModeTabBar"\]\.buttons\.matching')
        self.assertRegex(self.body, r'if browseTab\.exists && browseTab\.isHittable\s*\{\s*browseTab\.tap\(\)')
        browse = self.body.index('browseTab.tap()')
        local = self.body.index('localStorage.tap()')
        root_wait = self.body.index('tutorialReady(browser, "native-picker-root")')
        self.assertLess(browse, local)
        self.assertLess(local, root_wait)
        self.assertIn('"On My iPhone"', self.body)
        self.assertIn('"我的 iPhone"', self.body)

    def test_native_root_supports_fresh_and_retained_picker(self):
        root = self.body.split('let browser =', 1)[1].split('tutorialReady(browser,', 1)[0]
        self.assertIn("identifier == 'Browse View (Picker)'", root)
        self.assertIn("identifier BEGINSWITH 'DOC.browsingRoot'", root)
        self.assertIn(' OR ', root)

    def test_host_folder_and_file_are_scoped_to_native_cells(self):
        for name in ('host', 'folder', 'textFile'):
            with self.subTest(name=name):
                self.assertRegex(self.body, rf'let {name}\s*=\s*browser\.cells\.matching\(')
        self.assertLess(self.body.index('tutorialReady(browser,'), self.body.index('let host ='))
        self.assertLess(self.body.index('host.tap()'), self.body.index('folder.tap()'))
        self.assertLess(self.body.index('folder.tap()'), self.body.index('tutorialTap(textFile,'))
        self.assertIn("identifier BEGINSWITH 'file-item-'", self.body)
        self.assertIn("label == 'velock-sync-e2e-proof.txt'", self.body)


if __name__ == '__main__':
    unittest.main()
