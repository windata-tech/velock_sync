"""Six-kind tutorial acceptance cannot regress to a single-password demo."""
import json
import tempfile
import pathlib
import sys
import unittest
import sqlite3
from unittest.mock import patch
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import tutorial_coverage as coverage

class CoverageTests(unittest.TestCase):
    def test_default_is_six_distinct_business_categories(self):
        self.assertEqual(set(coverage.require_full_coverage(dict(prepared=True,keep_source=True))),
                         {'file','media','password','card','note','document'})

    def test_any_missing_category_or_duplicate_is_rejected(self):
        for omitted in coverage.REQUIRED_KINDS:
            with self.subTest(omitted=omitted), self.assertRaises(ValueError):
                coverage.require_full_coverage(dict(prepared=True,keep_source=True,
                    required_kinds=[k for k in coverage.REQUIRED_KINDS if k!=omitted]))
        with self.assertRaises(ValueError):
            coverage.require_full_coverage(dict(prepared=True,keep_source=True,
                required_kinds=list(coverage.REQUIRED_KINDS)+['file']))

    def test_unprepared_or_erased_source_is_rejected(self):
        for config in ({},dict(prepared=True),dict(keep_source=True)):
            with self.assertRaises(ValueError):coverage.require_full_coverage(config)

    def test_recorder_forwards_full_gate_and_never_password_only(self):
        source=pathlib.Path(__file__).with_name('record.py').read_text()
        self.assertIn("E2E_REQUIRED_KINDS=','.join(REQUIRED_KINDS)",source)
        self.assertNotIn("E2E_REQUIRED_KINDS='password'",source)
        self.assertIn('verify_source(config)',source)

    def test_ui_password_only_and_missing_album_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            report=pathlib.Path(tmp)/'replica-ui-coverage.json'
            for kinds in [['password'], ['file','password','card','note'], list(coverage.UI_KINDS)+['note']]:
                report.write_text(json.dumps(dict(verified_ui_kinds=kinds)))
                with self.assertRaises(ValueError):coverage.verify_ui_evidence(tmp,replica_only=True)
            report.write_text(json.dumps(dict(verified_ui_kinds=sorted(coverage.UI_KINDS))))
            coverage.verify_ui_evidence(tmp,replica_only=True)
            with self.assertRaises(FileNotFoundError):coverage.verify_ui_evidence(tmp)

class RecordingHistoryTests(unittest.TestCase):
    def test_published_history_cannot_be_silently_moved_to_empty_remote(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / 'test.db'
            with sqlite3.connect(path) as db:
                db.execute('CREATE TABLE t_sync_outbound_batch (sandbox_id INTEGER, state TEXT)')
                db.executemany('INSERT INTO t_sync_outbound_batch VALUES (?,?)', [(1,'ready'), (2,'published')])
            coverage.require_fresh_remote_source(path, 1)
            for state in ('published', 'acknowledged'):
                with sqlite3.connect(path) as db:
                    db.execute('UPDATE t_sync_outbound_batch SET state=? WHERE sandbox_id=1', (state,))
                with self.subTest(state=state), self.assertRaisesRegex(ValueError, 'Progress checkpoints contain no business data'):
                    coverage.require_fresh_remote_source(path, 1)

    def test_history_gate_is_before_recording_and_check(self):
        source=pathlib.Path(__file__).with_name('record.py').read_text()
        self.assertEqual(source.count('verify_recording_history(config)'), 2)
        self.assertLess(source.index('verify_recording_history(config)'), source.index('for ident in IDS.values()'))

if __name__=='__main__':unittest.main()
