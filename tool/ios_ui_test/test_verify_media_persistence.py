from contextlib import closing
import json
import os
import pathlib
import plistlib
import sqlite3
import subprocess
import sys
import tempfile
import unittest


class MediaPersistenceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.database = self.root / 'database'
        self.container = self.root / 'Library/Developer/CoreSimulator/Devices/fixture/data/Containers/Shared/AppGroup/test'
        self.container.mkdir(parents=True)
        (self.container / '.com.apple.mobile_container_manager.metadata.plist').write_bytes(
            plistlib.dumps({'MCMMetadataIdentifier': 'group.tech.windata.velock'}))
        (self.container / 'Media').mkdir()
        (self.container / 'Media/photo.enc').write_bytes(b'encrypted-media')
        self.execute('''
            CREATE TABLE t_category(id INTEGER, name TEXT);
            CREATE TABLE t_file(id INTEGER, name TEXT, info_json TEXT, category_id INTEGER, sandbox_id INTEGER);
            INSERT INTO t_category VALUES (1, 'media');
            INSERT INTO t_file VALUES (1, 'photo.enc', '{"width": 1}', 1, 1);
        ''')

    def execute(self, sql):
        with closing(sqlite3.connect(self.database)) as db, db:
            db.executescript(sql)

    def run_cli(self, optimized=False):
        script = pathlib.Path(__file__).with_name('verify_media_persistence.py')
        return subprocess.run([sys.executable, *(['-O'] if optimized else []), str(script),
            '--simulator-id', 'fixture', '--database', str(self.database), '--sandbox-id', '1'],
            env=dict(os.environ, HOME=str(self.root), PYTHONDONTWRITEBYTECODE='1'),
            capture_output=True, text=True, timeout=10)

    def test_valid_media_cli_preserves_output(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['verified_media'][0]['encrypted_bytes'], 15)

    def test_optimized_python_rejects_empty_selection(self):
        self.execute('DELETE FROM t_file')
        self.assertNotEqual(self.run_cli(optimized=True).returncode, 0)

    def test_optimized_python_rejects_empty_file(self):
        (self.container / 'Media/photo.enc').write_bytes(b'')
        self.assertNotEqual(self.run_cli(optimized=True).returncode, 0)

    def test_optimized_python_rejects_invalid_metadata(self):
        self.execute("UPDATE t_file SET info_json='[]'")
        self.assertNotEqual(self.run_cli(optimized=True).returncode, 0)

    def test_other_space_does_not_count(self):
        self.execute('UPDATE t_file SET sandbox_id=2')
        self.assertNotEqual(self.run_cli().returncode, 0)

    def test_optimized_python_rejects_missing_metadata(self):
        self.execute('UPDATE t_file SET info_json=NULL')
        self.assertNotEqual(self.run_cli(optimized=True).returncode, 0)

    def test_optimized_python_rejects_escaped_path(self):
        outside = self.root / 'outside.enc'
        outside.write_bytes(b'ciphertext')
        with closing(sqlite3.connect(self.database)) as db, db:
            db.execute('UPDATE t_file SET name=?', (str(outside),))
        self.assertNotEqual(self.run_cli(optimized=True).returncode, 0)

    def test_missing_one_of_two_assets_rejected(self):
        self.execute("INSERT INTO t_file VALUES (2, 'missing.enc', '{}', 1, 1)")
        self.assertNotEqual(self.run_cli().returncode, 0)

    def test_valid_media_is_read_only(self):
        before = {path: path.read_bytes() for path in self.root.rglob('*') if path.is_file()}
        self.assertEqual(self.run_cli().returncode, 0)
        after = {path: path.read_bytes() for path in self.root.rglob('*') if path.is_file()}
        self.assertEqual(before, after)


if __name__ == '__main__':
    unittest.main()
