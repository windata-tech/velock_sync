import importlib.util
from pathlib import Path
import sys
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location('regression', Path(__file__).with_name('run_sync_regression.py'))
regression = importlib.util.module_from_spec(spec)
spec.loader.exec_module(regression)


class RegressionRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'project'
        self.root.mkdir()

    def test_creates_external_artifacts_and_stable_link(self):
        result = regression.evidence_root(self.root)
        self.assertTrue(result.is_symlink())
        self.assertFalse(result.resolve().is_relative_to(self.root))
        (result / 'proof').write_text('ok')
        self.assertEqual((result.resolve() / 'proof').read_text(), 'ok')
        self.assertEqual(regression.evidence_root(self.root), result)

    def test_refuses_existing_real_directory(self):
        (self.root / 'ui_test_results').mkdir()
        with self.assertRaises(ValueError):
            regression.evidence_root(self.root)

    def test_refuses_internal_symlink(self):
        target = self.root / 'generated'
        target.mkdir()
        (self.root / 'ui_test_results').symlink_to(target)
        with self.assertRaises(ValueError):
            regression.evidence_root(self.root)

    def test_nonzero_suite_is_not_reported_as_green(self):
        result = regression.run_suite('failure', [sys.executable, '-c', 'raise SystemExit(7)'],
                                      self.root, self.root, 5)
        self.assertEqual(result['exit_code'], 7)
        self.assertFalse(result['timed_out'])

    def test_timeout_terminates_only_owned_process_group(self):
        result = regression.run_suite('timeout', [sys.executable, '-c', 'import time; time.sleep(30)'],
                                      self.root, self.root, .1)
        self.assertEqual(result['exit_code'], 124)
        self.assertTrue(result['timed_out'])
        self.assertLess(result['elapsed_seconds'], 5)

    def test_expired_global_budget_does_not_start_command(self):
        marker = self.root / 'must-not-exist'
        result = regression.run_suite('expired', [sys.executable, '-c',
                                      f'open({str(marker)!r}, "w").close()'],
                                      self.root, self.root, 5, deadline=time.monotonic() - 1)
        self.assertEqual(result['exit_code'], 124)
        self.assertFalse(marker.exists())


if __name__ == '__main__':
    unittest.main()
