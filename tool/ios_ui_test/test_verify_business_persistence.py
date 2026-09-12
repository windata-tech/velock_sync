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


if __name__ == '__main__':
    unittest.main()
