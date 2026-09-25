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


class BusinessConvergenceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.database = pathlib.Path(self.temp.name) / 'Documents/database'
        self.database.parent.mkdir()
        self.execute('''
            CREATE TABLE t_sync_vault(vault_id TEXT, local_device_id TEXT, sandbox_id INTEGER, enabled INTEGER);
            CREATE TABLE t_sync_entity(entity_uuid TEXT, entity_type TEXT, current_revision_id TEXT,
                sandbox_id INTEGER, deleted_at TEXT, local_table TEXT, local_id INTEGER);
            CREATE TABLE t_document(id INTEGER, sandbox_id INTEGER, name TEXT);
            INSERT INTO t_sync_vault VALUES ('vault', 'source', 1, 1);
            INSERT INTO t_sync_entity VALUES ('entity', 'document', 'revision', 1, NULL, 't_document', 1);
            INSERT INTO t_document VALUES (1, 1, 'doc.enc');
        ''')

    def execute(self, sql):
        from contextlib import closing
        with closing(sqlite3.connect(self.database)) as db, db:
            db.executescript(sql)

    def test_complete_business_mapping_passes(self):
        self.assertEqual(snapshot(self.database)[1], {'entity': ('document', 'revision')})

    def test_unindexed_source_record_rejected(self):
        self.execute("INSERT INTO t_document VALUES (2, 1, 'not-exported.enc')")
        with self.assertRaises(ValueError):
            snapshot(self.database)

    def test_replica_metadata_without_business_row_rejected(self):
        self.execute('DELETE FROM t_document')
        with self.assertRaises(ValueError):
            snapshot(self.database)

    def test_mapping_to_other_sandbox_rejected(self):
        self.execute('UPDATE t_document SET sandbox_id=2')
        with self.assertRaises(ValueError):
            snapshot(self.database)

    def test_null_revision_rejected(self):
        self.execute('UPDATE t_sync_entity SET current_revision_id=NULL')
        with self.assertRaises(ValueError):
            snapshot(self.database)

    def test_duplicate_entity_cannot_be_collapsed(self):
        self.execute('INSERT INTO t_sync_entity SELECT * FROM t_sync_entity')
        with self.assertRaises(ValueError):
            snapshot(self.database)

    def test_wrong_business_table_rejected(self):
        self.execute("UPDATE t_sync_entity SET local_table='t_note'")
        with self.assertRaises(ValueError):
            snapshot(self.database)

    def test_unrelated_sandbox_record_ignored(self):
        self.execute("INSERT INTO t_document VALUES (2, 2, 'other.enc')")
        self.assertEqual(len(snapshot(self.database)[1]), 1)

    def test_blank_identity_rejected(self):
        with self.assertRaises(ValueError):
            compare_identities(('', 'source'), ('', 'replica'))

    def test_null_revision_in_direct_compare_rejected(self):
        with self.assertRaises(ValueError):
            compare((('v', 's'), {'e': ('note', None)}),
                    (('v', 'r'), {'e': ('note', None)}))

    def test_identity_only_does_not_require_business_download(self):
        self.execute('DELETE FROM t_document')
        self.assertEqual(snapshot(self.database, identity_only=True), (('vault', 'source'), {}))

    def test_identity_only_cli_output_is_compatible(self):
        import json
        import os
        import subprocess
        import sys
        replica = self.database.with_name('replica')
        replica.write_bytes(self.database.read_bytes())
        from contextlib import closing
        with closing(sqlite3.connect(replica)) as db, db:
            db.execute("UPDATE t_sync_vault SET local_device_id='replica'")
            db.execute('DELETE FROM t_document')
        script = pathlib.Path(__file__).with_name('verify_replica_convergence.py')
        result = subprocess.run([sys.executable, str(script), '--source-database', str(self.database),
                                 '--replica-database', str(replica), '--identity-only'],
                                capture_output=True, text=True,
                                env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'), timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'recovered_original_vault': True, 'distinct_device_identity': True})

    def test_snapshot_does_not_write_database(self):
        before = self.database.read_bytes()
        snapshot(self.database)
        self.assertEqual(self.database.read_bytes(), before)

    def test_supported_business_kinds_are_all_indexed(self):
        self.execute('''
            CREATE TABLE t_password(id INTEGER, sandbox_id INTEGER);
            CREATE TABLE t_card(id INTEGER, sandbox_id INTEGER);
            CREATE TABLE t_note(id INTEGER, sandbox_id INTEGER);
            CREATE TABLE t_file(id INTEGER, sandbox_id INTEGER);
            INSERT INTO t_password VALUES (1, 1);
            INSERT INTO t_card VALUES (1, 1);
            INSERT INTO t_note VALUES (1, 1);
            INSERT INTO t_file VALUES (1, 1), (2, 1);
            INSERT INTO t_sync_entity VALUES
                ('password', 'password', 'r', 1, NULL, 't_password', 1),
                ('card', 'card', 'r', 1, NULL, 't_card', 1),
                ('note', 'note', 'r', 1, NULL, 't_note', 1),
                ('file', 'file', 'r', 1, NULL, 't_file', 1),
                ('media', 'file', 'r', 1, NULL, 't_file', 2);
        ''')
        self.assertEqual(len(snapshot(self.database)[1]), 6)

    def test_missing_mapping_columns_cannot_hide_business_rows(self):
        self.execute('ALTER TABLE t_sync_entity DROP COLUMN local_table; '
                     'ALTER TABLE t_sync_entity DROP COLUMN local_id')
        with self.assertRaises(ValueError):
            snapshot(self.database)

    def test_namespace_import_remains_supported(self):
        import os
        import subprocess
        import sys
        root = pathlib.Path(__file__).resolve().parents[2]
        result = subprocess.run([sys.executable, '-c',
            'from tool.ios_ui_test.verify_replica_convergence import snapshot; '
            'from tool.ios_ui_test.verify_remote_coverage import verify; '
            'from tool.ios_ui_test.verify_media_persistence import verify'],
            cwd=root, capture_output=True, text=True,
            env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'), timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)


class ContentConvergenceTest(unittest.TestCase):
    def setUp(self):
        from contextlib import closing
        from verify_replica_convergence import METADATA_FIELDS
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.databases = []
        self.roots = []
        for index, device in enumerate(('source', 'replica')):
            root = self.root / device
            root.mkdir()
            database = root / 'database'
            self.databases.append(database)
            self.roots.append(root)
            with closing(sqlite3.connect(database)) as db, db:
                db.executescript("""
                    CREATE TABLE t_sync_vault(vault_id TEXT, local_device_id TEXT, sandbox_id INTEGER, enabled INTEGER);
                    CREATE TABLE t_sync_entity(entity_uuid TEXT, entity_type TEXT, current_revision_id TEXT,
                        sandbox_id INTEGER, deleted_at TEXT, local_table TEXT, local_id INTEGER);
                    CREATE TABLE t_category(id INTEGER, name TEXT);
                    INSERT INTO t_category VALUES (1, 'file'), (2, 'media');
                """)
                db.execute('INSERT INTO t_sync_vault VALUES (?, ?, ?, 1)', ('vault', device, index + 1))
                for kind in ('password', 'card', 'note', 'file'):
                    fields = METADATA_FIELDS[kind]
                    extra = ('name TEXT, category_id INTEGER, parent_id INTEGER' if kind == 'file'
                             else 'encrypted_filename TEXT')
                    db.execute(f'CREATE TABLE t_{kind}(id INTEGER, sandbox_id INTEGER, '
                               + ', '.join(fields) + ', ' + extra + ')')
                    for category in (('file', 'media') if kind == 'file' else (kind,)):
                        ident = (2 if category == 'media' else 1) + index * 10
                        metadata = {key: None for key in fields}
                        if kind == 'file':
                            metadata.update(display_name='sample', type=0, filesize=7,
                                            info_json='{"width": 1}', original_time='2026-09-19T00:00:00Z')
                            metadata.update(name=device + category + '.enc',
                                            category_id=2 if category == 'media' else 1, parent_id=None)
                            folder = category.title()
                            payload = b'copied-ciphertext'
                        else:
                            metadata.update(title='synthetic', encrypted_filename=device + '.enc')
                            folder = 'Credential/' + kind.title()
                            payload = (device + '-rewritten-ciphertext').encode()
                        values = dict(id=ident, sandbox_id=index + 1, **metadata)
                        db.execute(f'INSERT INTO t_{kind} (' + ','.join(values) + ') VALUES ('
                                   + ','.join('?' for _ in values) + ')', tuple(values.values()))
                        db.execute('INSERT INTO t_sync_entity VALUES (?, ?, ?, ?, NULL, ?, ?)',
                                   (category, kind, 'revision', index + 1, 't_' + kind, ident))
                        target = root / folder / metadata.get('encrypted_filename', metadata.get('name'))
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_bytes(payload)

    def snapshots(self):
        from verify_replica_convergence import business_snapshot
        return [business_snapshot(db, root) for db, root in zip(self.databases, self.roots)]

    def compare(self):
        from verify_replica_convergence import compare_business
        return compare_business(*self.snapshots())

    def mutate(self, sql):
        from contextlib import closing
        with closing(sqlite3.connect(self.databases[1])) as db, db:
            db.executescript(sql)

    def test_all_five_kinds_with_remapped_ids_and_rewritten_credentials(self):
        self.assertEqual(self.compare(), dict(password=1, card=1, note=1, file=1, media=1))

    def test_same_revision_different_ciphertext_rejected_for_file_and_media(self):
        for category in ('file', 'media'):
            target = self.roots[1] / category.title() / ('replica' + category + '.enc')
            before = target.read_bytes()
            target.write_bytes(b'X' * len(before))
            with self.subTest(category=category), self.assertRaisesRegex(ValueError, 'bytes differ'):
                self.compare()
            target.write_bytes(before)

    def test_metadata_drift_with_matching_revisions_rejected(self):
        for table, field in [('t_password', 'account'), ('t_card', 'card_number'),
                             ('t_note', 'summary'), ('t_file', 'display_name')]:
            with self.subTest(table=table):
                self.mutate(f"UPDATE {table} SET {field}='CHANGED'")
                with self.assertRaisesRegex(ValueError, 'metadata or encrypted') as raised:
                    self.compare()
                self.assertNotIn('CHANGED', str(raised.exception))
                self.mutate(f"UPDATE {table} SET {field}=" + ("'sample'" if table == 't_file' else 'NULL'))

    def test_missing_or_empty_rewritten_artifact_rejected(self):
        for kind in ('Password', 'Card', 'Note'):
            target = self.roots[1] / 'Credential' / kind / 'replica.enc'
            before = target.read_bytes()
            for payload in (None, b''):
                if payload is None:
                    target.unlink()
                else:
                    target.write_bytes(payload)
                with self.subTest(kind=kind, payload=payload), self.assertRaisesRegex(ValueError, 'missing/empty'):
                    self.compare()
            target.write_bytes(before)

    def test_json_format_and_equivalent_time_are_not_drift(self):
        self.mutate("""UPDATE t_file SET info_json=' { "width" : 1 } ',
                    original_time='2026-09-19T08:00:00+08:00'""")
        self.assertEqual(self.compare()['media'], 1)

    def test_media_metadata_drift_rejected(self):
        self.mutate("""UPDATE t_file SET info_json='{"width": 2}' WHERE category_id=2""")
        with self.assertRaises(ValueError):
            self.compare()

    def test_missing_metadata_column_fails_closed(self):
        self.mutate('ALTER TABLE t_card DROP COLUMN card_number')
        with self.assertRaisesRegex(ValueError, 'schema'):
            self.compare()

    def test_export_cli_requires_roots_and_compares_content(self):
        import os
        import subprocess
        import sys
        import json
        script = pathlib.Path(__file__).with_name('verify_replica_convergence.py')
        args = [sys.executable, '-O', str(script), '--source-database', str(self.databases[0]),
                '--replica-database', str(self.databases[1])]
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
        self.assertNotEqual(subprocess.run(args, capture_output=True, env=env).returncode, 0)
        args += ['--source-root', str(self.roots[0]), '--replica-root', str(self.roots[1])]
        result = subprocess.run(args, capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(len(report['matching_business_records']), 5)
        self.assertFalse(report['credential_plaintext_compared'])
        self.mutate("UPDATE t_note SET summary='different'")
        self.assertNotEqual(subprocess.run(args, capture_output=True, env=env).returncode, 0)

    def test_parent_mapping_uses_entity_uuid_not_local_id(self):
        from contextlib import closing
        for index, database in enumerate(self.databases):
            root = self.roots[index]
            with closing(sqlite3.connect(database)) as db, db:
                parent = 100 + index
                db.execute("INSERT INTO t_file (id, sandbox_id, name, category_id, type, display_name) "
                           "VALUES (?, ?, 'folder', 1, 1, 'Folder')", (parent, index + 1))
                db.execute("INSERT INTO t_sync_entity VALUES ('parent', 'file', 'r', ?, NULL, 't_file', ?)",
                           (index + 1, parent))
                db.execute('UPDATE t_file SET parent_id=? WHERE type=0 AND category_id=1', (parent,))
                (root / 'File/folder').mkdir()
                child = root / 'File' / (('source' if index == 0 else 'replica') + 'file.enc')
                child.rename(root / 'File/folder' / child.name)
        self.assertEqual(self.compare()['file'], 1)
        self.mutate("UPDATE t_sync_entity SET entity_uuid='different-parent' WHERE entity_uuid='parent'")
        with self.assertRaises(ValueError):
            self.compare()

    def test_shared_root_resolution_is_scoped_to_database_device(self):
        from verify_replica_convergence import shared_root
        containers = self.root / 'Devices/test/data/Containers'
        database = containers / 'Data/Application/app/Documents/database'
        group = containers / 'Shared/AppGroup/group'
        group.mkdir(parents=True)
        (group / '.com.apple.mobile_container_manager.metadata.plist').write_bytes(
            plistlib.dumps({'MCMMetadataIdentifier': 'group.tech.windata.velock'}))
        self.assertEqual(shared_root(database), group.resolve())
        second = group.with_name('ambiguous')
        second.mkdir()
        (second / '.com.apple.mobile_container_manager.metadata.plist').write_bytes(
            plistlib.dumps({'MCMMetadataIdentifier': 'group.tech.windata.velock'}))
        with self.assertRaises(ValueError):
            shared_root(database)

    def test_content_checks_do_not_write(self):
        before = {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        self.compare()
        self.assertEqual(before, {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()})


if __name__ == '__main__':
    unittest.main()
