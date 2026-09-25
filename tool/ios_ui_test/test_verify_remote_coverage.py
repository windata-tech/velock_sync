from contextlib import closing
import hashlib
import json
import pathlib
import plistlib
import sqlite3
import tempfile
import unittest

from verify_remote_coverage import verify


class RemoteCoverageTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.database = self.root / 'Documents/database'
        self.database.parent.mkdir()
        self.remote = self.root / 'remote'
        self.execute('''
            CREATE TABLE t_sync_vault(vault_id TEXT, local_device_id TEXT, sandbox_id INTEGER, enabled INTEGER);
            CREATE TABLE t_sync_outbound_batch(sandbox_id INTEGER, batch_id TEXT, sequence INTEGER,
                state TEXT, previous_batch_id TEXT, previous_sequence INTEGER);
            CREATE TABLE t_sync_entity(entity_uuid TEXT, sandbox_id INTEGER);
            CREATE TABLE t_sync_change_log(entity_uuid TEXT, batch_id TEXT, blob_refs_json TEXT, export_state TEXT, operation_type TEXT DEFAULT 'upsert');
            INSERT INTO t_sync_vault VALUES ('vault', 'device', 1, 1);
            INSERT INTO t_sync_outbound_batch VALUES (1, 'batch', 1, 'published', NULL, NULL);
            INSERT INTO t_sync_entity VALUES ('entity', 1);
            INSERT INTO t_sync_change_log(entity_uuid,batch_id,blob_refs_json,export_state) VALUES ('entity', 'batch', '["blob-1"]', 'published');
        ''')
        self.base = self.remote / 'velock-sync/v1/vault/devices/device'
        self.batch = self.base / 'batches/00000000000000000001/batch'
        self.batch.mkdir(parents=True)
        (self.base / 'commits').mkdir()
        self.operations = b'opaque-test-operations'
        (self.batch / 'operations.enc').write_bytes(self.operations)
        self.blob = self.remote / 'velock-sync/v1/vault/blobs/bl/blob-1.blob'
        self.blob.parent.mkdir(parents=True)
        self.blob.write_bytes(b'opaque-attachment')
        self.envelope = {
            'vaultId': 'vault', 'sourceDeviceId': 'device', 'batchId': 'batch', 'sequence': 1,
            'previousSequence': None, 'previousBatchId': None,
            'operations': dict(self.descriptor(self.operations), operationCount=1),
            'blobs': [dict(self.descriptor(self.blob.read_bytes()), blobId='blob-1',
                           logicalKey='velock-sync/v1/vault/blobs/bl/blob-1.blob')],
        }
        self.commit = {key: self.envelope[key] for key in ('vaultId', 'sourceDeviceId', 'batchId', 'sequence')}
        self.save_envelope()

    def execute(self, sql):
        with closing(sqlite3.connect(self.database)) as db, db:
            db.executescript(sql)

    @staticmethod
    def descriptor(content):
        return {'cipherSize': len(content), 'cipherSha256': hashlib.sha256(content).hexdigest()}

    def save_envelope(self):
        content = json.dumps(self.envelope).encode()
        (self.batch / 'envelope.json').write_bytes(content)
        self.commit['envelopeSha256'] = hashlib.sha256(content).hexdigest()
        self.save_commit()

    def save_commit(self):
        (self.base / 'commits/00000000000000000001-batch.commit').write_text(json.dumps(self.commit))

    def reject(self):
        with self.assertRaises(ValueError):
            verify(self.database, self.remote)

    def test_complete_batch_passes(self):
        self.assertEqual(verify(self.database, self.remote), {'verified_remote_batches': 1})

    def test_missing_blob_rejected(self):
        self.blob.unlink()
        self.reject()

    def test_corrupt_blob_rejected(self):
        self.blob.write_bytes(b'x' * len(b'opaque-attachment'))
        self.reject()

    def test_corrupt_operations_rejected(self):
        (self.batch / 'operations.enc').write_bytes(b'x' * len(self.operations))
        self.reject()

    def test_commit_hash_mismatch_rejected(self):
        self.commit['envelopeSha256'] = '0' * 64
        self.save_commit()
        self.reject()

    def test_wrong_commit_identity_rejected(self):
        self.commit['vaultId'] = 'wrong'
        self.save_commit()
        self.reject()

    def test_wrong_envelope_identity_rejected(self):
        self.envelope['sourceDeviceId'] = 'wrong'
        self.save_envelope()
        self.reject()

    def test_omitted_attachment_descriptor_rejected(self):
        self.envelope['blobs'] = []
        self.save_envelope()
        self.reject()

    def test_partial_operation_count_rejected(self):
        self.execute("INSERT INTO t_sync_change_log(entity_uuid,batch_id,blob_refs_json,export_state) VALUES ('entity', 'batch', '[]', 'published')")
        self.reject()

    def test_unbatched_change_rejected(self):
        self.execute("INSERT INTO t_sync_change_log(entity_uuid,batch_id,blob_refs_json,export_state) VALUES ('entity', NULL, '[]', 'pending')")
        self.reject()

    def test_unknown_batch_assignment_rejected(self):
        self.execute("INSERT INTO t_sync_change_log(entity_uuid,batch_id,blob_refs_json,export_state) VALUES ('entity', 'missing', '[]', 'packaged')")
        self.reject()

    def test_missing_first_sequence_rejected(self):
        self.execute('UPDATE t_sync_outbound_batch SET sequence=2')
        new = self.base / 'batches/00000000000000000002/batch'
        new.parent.mkdir()
        self.batch.rename(new)
        self.batch = new
        self.envelope['sequence'] = self.commit['sequence'] = 2
        self.save_envelope()
        old = self.base / 'commits/00000000000000000001-batch.commit'
        old.rename(self.base / 'commits/00000000000000000002-batch.commit')
        self.reject()

    def test_invalid_predecessor_rejected(self):
        self.envelope['previousSequence'] = 9
        self.envelope['previousBatchId'] = 'nonexistent'
        self.save_envelope()
        self.reject()

    def test_duplicate_blob_descriptor_rejected(self):
        self.envelope['blobs'] *= 2
        self.save_envelope()
        self.reject()

    def test_wrong_blob_logical_key_rejected(self):
        self.envelope['blobs'][0]['logicalKey'] = '../outside'
        self.save_envelope()
        self.reject()

    def test_selected_empty_vault_not_masked_by_retained_vault(self):
        self.execute("INSERT INTO t_sync_vault VALUES ('empty', 'other', 2, 1)")
        preferences = self.root / 'Library/Preferences/tech.windata.velock.plist'
        preferences.parent.mkdir(parents=True)
        preferences.write_bytes(plistlib.dumps({'current_sandbox_id': 2}))
        self.reject()

    def test_non_json_envelope_rejected(self):
        (self.batch / 'envelope.json').write_bytes(b'not-json')
        self.reject()

    def test_symlink_outside_remote_rejected(self):
        outside = self.root / 'outside.blob'
        self.blob.rename(outside)
        self.blob.symlink_to(outside)
        self.reject()

    def test_delete_references_do_not_require_reuploading_old_blob(self):
        self.execute("UPDATE t_sync_change_log SET operation_type='delete'")
        self.envelope['blobs'] = []
        self.save_envelope()
        self.assertEqual(verify(self.database, self.remote)['verified_remote_batches'], 1)

    def test_orphan_change_is_not_hidden_by_join(self):
        self.execute("INSERT INTO t_sync_change_log(entity_uuid,batch_id,blob_refs_json,export_state) "
                     "VALUES ('orphan', 'batch', '[]', 'published')")
        self.reject()

    def test_selected_vault_ignores_other_vault_batches(self):
        self.execute("INSERT INTO t_sync_vault VALUES ('other', 'other-device', 2, 1); "
                     "INSERT INTO t_sync_outbound_batch VALUES (2, 'other-batch', 1, 'ready', NULL, NULL)")
        preferences = self.root / 'Library/Preferences/tech.windata.velock.plist'
        preferences.parent.mkdir(parents=True)
        preferences.write_bytes(plistlib.dumps({'current_sandbox_id': 1}))
        self.assertEqual(verify(self.database, self.remote)['verified_remote_batches'], 1)

    def test_complete_two_batch_chain_passes(self):
        self.execute("INSERT INTO t_sync_outbound_batch VALUES (1, 'second', 2, 'ready', 'batch', 1); "
                     "INSERT INTO t_sync_change_log(entity_uuid,batch_id,blob_refs_json,export_state) "
                     "VALUES ('entity', 'second', '[\"blob-1\"]', 'packaged')")
        self.batch = self.base / 'batches/00000000000000000002/second'
        self.batch.mkdir(parents=True)
        (self.batch / 'operations.enc').write_bytes(self.operations)
        self.envelope.update(batchId='second', sequence=2, previousBatchId='batch', previousSequence=1)
        content = json.dumps(self.envelope).encode()
        (self.batch / 'envelope.json').write_bytes(content)
        commit = dict(self.commit, batchId='second', sequence=2, envelopeSha256=hashlib.sha256(content).hexdigest())
        (self.base / 'commits/00000000000000000002-second.commit').write_text(json.dumps(commit))
        self.assertEqual(verify(self.database, self.remote)['verified_remote_batches'], 2)

    def test_boolean_count_cannot_satisfy_one_operation(self):
        self.envelope['operations']['operationCount'] = True
        self.save_envelope()
        self.reject()

    def test_read_only_database_and_remote(self):
        before = {path: path.read_bytes() for path in self.root.rglob('*') if path.is_file()}
        verify(self.database, self.remote)
        after = {path: path.read_bytes() for path in self.root.rglob('*') if path.is_file()}
        self.assertEqual(before, after)

    def test_cli_output_is_compatible(self):
        import os
        import subprocess
        import sys
        script = pathlib.Path(__file__).with_name('verify_remote_coverage.py')
        result = subprocess.run([sys.executable, str(script), '--database', str(self.database),
                                 '--remote', str(self.remote)], capture_output=True, text=True,
                                env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'), timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {'verified_remote_batches': 1})


if __name__ == '__main__':
    unittest.main()
