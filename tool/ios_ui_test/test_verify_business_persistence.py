from contextlib import closing
import pathlib
import sqlite3
import tempfile
import unittest

from verify_business_persistence import verify


class PersistenceVerificationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.db = self.root / 'database'
        with closing(sqlite3.connect(self.db)) as connection, connection:
            connection.executescript('''
                CREATE TABLE t_document(id INTEGER, name TEXT);
                CREATE TABLE t_file(id INTEGER, name TEXT, category_id INTEGER);
                CREATE TABLE t_category(id INTEGER, name TEXT);
                INSERT INTO t_category VALUES (1, 'file'), (2, 'media');
            ''')

    def insert_document(self, name):
        with closing(sqlite3.connect(self.db)) as connection, connection:
            connection.execute('INSERT INTO t_document VALUES (1, ?)', (name,))

    def test_record_without_ciphertext_fails(self):
        self.insert_document('missing.enc')
        with self.assertRaisesRegex(ValueError, 'missing/empty'):
            verify(self.db, self.root, ['document'])

    def test_existing_document_does_not_prove_new_import(self):
        self.insert_document('existing.enc')
        with self.assertRaisesRegex(ValueError, 'No document'):
            verify(self.db, self.root, ['document'], after_id=1)

    def test_nonempty_ciphertext_passes(self):
        self.insert_document('valid.enc')
        (self.root / 'Document').mkdir()
        (self.root / 'Document/valid.enc').write_bytes(b'ciphertext-fixture')
        self.assertEqual(verify(self.db, self.root, ['document'])['document'][0]['encrypted_bytes'], 18)

    def test_media_cannot_satisfy_file_requirement(self):
        with closing(sqlite3.connect(self.db)) as connection, connection:
            connection.execute('INSERT INTO t_file VALUES (1, ?, 2)', ('photo.enc',))
        with self.assertRaisesRegex(ValueError, 'No file'):
            verify(self.db, self.root, ['file'])

    def test_other_space_cannot_satisfy_recovery(self):
        with closing(sqlite3.connect(self.db)) as connection, connection:
            connection.execute('ALTER TABLE t_document ADD COLUMN sandbox_id INTEGER')
            connection.execute("INSERT INTO t_document VALUES (1, 'old.enc', 1)")
        (self.root / 'Document').mkdir()
        (self.root / 'Document/old.enc').write_bytes(b'old ciphertext')
        with self.assertRaisesRegex(ValueError, 'No document'):
            verify(self.db, self.root, ['document'], sandbox_id=2)

    def test_only_requested_space_is_verified(self):
        with closing(sqlite3.connect(self.db)) as connection, connection:
            connection.execute('ALTER TABLE t_document ADD COLUMN sandbox_id INTEGER')
            connection.execute("INSERT INTO t_document VALUES (1, 'missing.enc', 1)")
            connection.execute("INSERT INTO t_document VALUES (2, 'recovered.enc', 2)")
        (self.root / 'Document').mkdir()
        (self.root / 'Document/recovered.enc').write_bytes(b'recovered ciphertext')
        result = verify(self.db, self.root, ['document'], sandbox_id=2)
        self.assertEqual([row['id'] for row in result['document']], [2])

    def test_path_escape_rejected(self):
        self.insert_document('../database')
        with self.assertRaisesRegex(ValueError, 'invalid path'):
            verify(self.db, self.root, ['document'])


class PersistenceAccuracyTest(unittest.TestCase):
    setUp = PersistenceVerificationTest.setUp
    insert_document = PersistenceVerificationTest.insert_document

    def test_empty_kind_list_rejected(self):
        with self.assertRaises(ValueError):
            verify(self.db, self.root, [])

    def test_partial_business_restore_rejected(self):
        self.insert_document('valid.enc')
        (self.root / 'Document').mkdir()
        (self.root / 'Document/valid.enc').write_bytes(b'ciphertext')
        with closing(sqlite3.connect(self.db)) as db, db:
            db.executescript('''
                ALTER TABLE t_document ADD COLUMN sandbox_id INTEGER DEFAULT 1;
                CREATE TABLE t_sync_entity(entity_uuid TEXT, entity_type TEXT, current_revision_id TEXT,
                    sandbox_id INTEGER, deleted_at TEXT, local_table TEXT, local_id INTEGER);
                INSERT INTO t_sync_entity VALUES ('one', 'document', 'r1', 1, NULL, 't_document', 1),
                    ('two', 'document', 'r2', 1, NULL, 't_document', 2);
            ''')
        with self.assertRaises(ValueError):
            verify(self.db, self.root, ['document'], sandbox_id=1)

    def test_absolute_filename_rejected_even_inside_root(self):
        (self.root / 'Document').mkdir()
        target = self.root / 'Document/valid.enc'
        target.write_bytes(b'ciphertext')
        self.insert_document(str(target))
        with self.assertRaises(ValueError):
            verify(self.db, self.root, ['document'])

    def nested_file(self):
        with closing(sqlite3.connect(self.db)) as db, db:
            db.executescript('''
                ALTER TABLE t_file ADD COLUMN parent_id INTEGER;
                ALTER TABLE t_file ADD COLUMN type INTEGER DEFAULT 0;
                ALTER TABLE t_file ADD COLUMN sandbox_id INTEGER DEFAULT 1;
                INSERT INTO t_file VALUES (1, 'folder', 1, NULL, 1, 1);
                INSERT INTO t_file VALUES (2, 'child.enc', 1, 1, 0, 1);
            ''')
        (self.root / 'File/folder').mkdir(parents=True)

    def test_nested_file_is_checked_at_its_real_path(self):
        self.nested_file()
        (self.root / 'File/folder/child.enc').write_bytes(b'actual-child')
        result = verify(self.db, self.root, ['file'], after_id=1, sandbox_id=1)
        self.assertEqual(result['file'][0]['encrypted_bytes'], 12)

    def test_root_decoy_cannot_replace_missing_nested_file(self):
        self.nested_file()
        (self.root / 'File/child.enc').write_bytes(b'decoy')
        with self.assertRaises(ValueError):
            verify(self.db, self.root, ['file'], after_id=1, sandbox_id=1)

    def test_parent_cycle_rejected(self):
        self.nested_file()
        with closing(sqlite3.connect(self.db)) as db, db:
            db.execute('UPDATE t_file SET parent_id=1 WHERE id=1')
        (self.root / 'File/child.enc').write_bytes(b'decoy')
        with self.assertRaises(ValueError):
            verify(self.db, self.root, ['file'], after_id=1, sandbox_id=1)

    def test_directory_is_not_encrypted_file_evidence(self):
        self.nested_file()
        (self.root / 'File/folder/child.enc').write_bytes(b'child')
        result = verify(self.db, self.root, ['file'], sandbox_id=1)
        self.assertEqual(result['file'][0], {'id': 1, 'directory': True})

    def test_directories_alone_cannot_satisfy_file_or_media(self):
        self.nested_file()
        with closing(sqlite3.connect(self.db)) as db, db:
            db.execute('DELETE FROM t_file WHERE id=2')
        for kind, category in [('file', 1), ('media', 2)]:
            with self.subTest(kind=kind):
                with closing(sqlite3.connect(self.db)) as db, db:
                    db.execute('UPDATE t_file SET category_id=?', (category,))
                (self.root / kind.title() / 'folder').mkdir(parents=True, exist_ok=True)
                with self.assertRaisesRegex(ValueError, 'only directories'):
                    verify(self.db, self.root, [kind], sandbox_id=1)

    def test_media_schema_without_metadata_rejected(self):
        self.nested_file()
        with closing(sqlite3.connect(self.db)) as db, db:
            db.execute('UPDATE t_file SET category_id=2')
        (self.root / 'Media/folder').mkdir(parents=True)
        (self.root / 'Media/folder/child.enc').write_bytes(b'ciphertext')
        with self.assertRaisesRegex(ValueError, 'Missing media metadata'):
            verify(self.db, self.root, ['media'], sandbox_id=1)

    def test_after_id_does_not_validate_old_missing_mapping(self):
        self.insert_document('valid.enc')
        (self.root / 'Document').mkdir()
        (self.root / 'Document/valid.enc').write_bytes(b'ciphertext')
        with closing(sqlite3.connect(self.db)) as db, db:
            db.executescript("""
                ALTER TABLE t_document ADD COLUMN sandbox_id INTEGER DEFAULT 1;
                UPDATE t_document SET id=2;
                CREATE TABLE t_sync_entity(entity_uuid TEXT, entity_type TEXT, current_revision_id TEXT,
                    sandbox_id INTEGER, deleted_at TEXT, local_table TEXT, local_id INTEGER);
                INSERT INTO t_sync_entity VALUES ('old', 'document', 'r1', 1, NULL, 't_document', 1),
                    ('new', 'document', 'r2', 1, NULL, 't_document', 2);
            """)
        self.assertEqual(len(verify(self.db, self.root, ['document'], after_id=1, sandbox_id=1)['document']), 1)

    def test_parent_in_other_sandbox_rejected(self):
        self.nested_file()
        with closing(sqlite3.connect(self.db)) as db, db:
            db.execute('UPDATE t_file SET sandbox_id=2 WHERE id=1')
        (self.root / 'File/folder/child.enc').write_bytes(b'child')
        with self.assertRaises(ValueError):
            verify(self.db, self.root, ['file'], after_id=1, sandbox_id=1)

    def test_external_symlink_cannot_supply_encrypted_content(self):
        self.insert_document('external.enc')
        (self.root / 'Document').mkdir()
        (self.root / 'Document/external.enc').symlink_to(self.db)
        with self.assertRaises(ValueError):
            verify(self.db, self.root, ['document'])

    def test_empty_ciphertext_rejected(self):
        self.insert_document('empty.enc')
        (self.root / 'Document').mkdir()
        (self.root / 'Document/empty.enc').touch()
        with self.assertRaises(ValueError):
            verify(self.db, self.root, ['document'])

    def test_verification_is_read_only(self):
        self.insert_document('valid.enc')
        (self.root / 'Document').mkdir()
        artifact = self.root / 'Document/valid.enc'
        artifact.write_bytes(b'ciphertext')
        before = self.db.read_bytes(), artifact.read_bytes()
        verify(self.db, self.root, ['document'])
        self.assertEqual((self.db.read_bytes(), artifact.read_bytes()), before)


if __name__ == '__main__':
    unittest.main()
