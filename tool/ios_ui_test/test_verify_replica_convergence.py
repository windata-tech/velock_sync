import unittest
from verify_replica_convergence import compare, compare_identities, snapshot
import pathlib
import plistlib
import sqlite3
import tempfile


class ConvergenceTest(unittest.TestCase):
    def test_all_source_revisions_match(self):
        self.assertEqual(compare((('v', 'a'), {'e': ('media', 'r')}),
                                 (('v', 'b'), {'e': ('media', 'r')})), {'media': 1})

    def test_old_replica_rows_do_not_count(self):
        with self.assertRaisesRegex(ValueError, 'missing or stale'):
            compare((('v', 'a'), {'new': ('document', 'r')}),
                    (('v', 'b'), {'old': ('document', 'r')}))

    def test_wrong_vault_rejected(self):
        with self.assertRaisesRegex(ValueError, 'different vault'):
            compare((('v', 'a'), {'e': ('note', 'r')}), (('other', 'b'), {}))

    def test_cloned_device_identity_rejected(self):
        with self.assertRaisesRegex(ValueError, 'own device'):
            compare((('v', 'a'), {'e': ('note', 'r')}),
                    (('v', 'a'), {'e': ('note', 'r')}))

    def test_identity_gate_accepts_original_vault_before_data_download(self):
        compare_identities(('original', 'source'), ('original', 'replacement'))

    def test_identity_gate_rejects_empty_new_vault(self):
        with self.assertRaisesRegex(ValueError, 'different vault'):
            compare_identities(('original', 'source'), ('new-empty', 'replacement'))

    def test_snapshot_uses_selected_space_not_matching_inactive_vault(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            database = root / 'Documents/venyoreDb'
            database.parent.mkdir()
            with sqlite3.connect(database) as connection:
                connection.executescript("""
                    CREATE TABLE t_sync_vault(vault_id TEXT, local_device_id TEXT, sandbox_id INTEGER, enabled INTEGER);
                    CREATE TABLE t_sync_entity(entity_uuid TEXT, entity_type TEXT, current_revision_id TEXT, sandbox_id INTEGER, deleted_at TEXT);
                    INSERT INTO t_sync_vault VALUES ('inactive', 'a', 1, 1), ('selected', 'b', 2, 1);
                    INSERT INTO t_sync_entity VALUES ('old', 'note', 'r1', 1, NULL), ('current', 'file', 'r2', 2, NULL);
                """)
            preferences = root / 'Library/Preferences/tech.windata.velock.plist'
            preferences.parent.mkdir(parents=True)
            with preferences.open('wb') as stream:
                plistlib.dump({'current_sandbox_id': 2}, stream)
            self.assertEqual(snapshot(database), (('selected', 'b'), {'current': ('file', 'r2')}))
