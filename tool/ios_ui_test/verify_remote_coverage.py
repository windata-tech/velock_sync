"""Read-only integrity/coverage check of a retained, unpruned test remote.

Only public envelope metadata and the offline test DB are inspected. Operations
and blobs remain opaque; hashes/counts are not signature or decryption proof.
"""
import argparse
from contextlib import closing
import hashlib
import json
import pathlib
import sqlite3

if __package__:
    from .verify_business_persistence import checked_path
    from .verify_replica_convergence import selected_vault
else:
    from verify_business_persistence import checked_path
    from verify_replica_convergence import selected_vault


def identifier(value):
    if (not isinstance(value, str) or not value.strip() or value in {'.', '..'}
            or '/' in value or '\\' in value or '..' in value):
        raise ValueError('Invalid remote identifier')
    return value


def read_object(path):
    try:
        value = json.loads(path.read_bytes())
    except (OSError, ValueError):
        raise ValueError('Missing or invalid remote JSON artifact') from None
    if not isinstance(value, dict):
        raise ValueError('Invalid remote JSON object')
    return value


def check_artifact(path, descriptor):
    if not isinstance(descriptor, dict):
        raise ValueError('Invalid ciphertext descriptor')
    size, expected = descriptor.get('cipherSize'), descriptor.get('cipherSha256')
    if (type(size) is not int or size <= 0 or not isinstance(expected, str)
            or len(expected) != 64 or any(c not in '0123456789abcdef' for c in expected)):
        raise ValueError('Invalid ciphertext size/hash')
    if not path.is_file() or path.stat().st_size != size:
        raise ValueError('Remote ciphertext missing/empty or size mismatch')
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        raise ValueError('Remote ciphertext hash mismatch')


def verify(database, remote):
    with closing(sqlite3.connect(f'{database.resolve().as_uri()}?mode=ro', uri=True)) as db:
        db.execute('BEGIN')
        vault, device, sandbox = selected_vault(db, database)
        identifier(vault)
        identifier(device)
        rows = db.execute('''SELECT batch_id,sequence,state,previous_batch_id,previous_sequence
            FROM t_sync_outbound_batch WHERE sandbox_id=? ORDER BY sequence''', (sandbox,)).fetchall()
        # Include pending/unassigned operations, not just the successful join to
        # outbound batches. Otherwise an entire lost batch goes unnoticed.
        changes = db.execute('''SELECT c.batch_id,c.blob_refs_json,c.operation_type,e.entity_uuid FROM t_sync_change_log c
            LEFT JOIN t_sync_entity e ON c.entity_uuid=e.entity_uuid
            WHERE e.sandbox_id=? OR e.entity_uuid IS NULL''', (sandbox,)).fetchall()
    if not rows:
        raise ValueError('No source batches to verify')
    batch_ids = {row[0] for row in rows}
    if len(batch_ids) != len(rows):
        raise ValueError('Duplicate source batch identity')
    local = {batch: [] for batch in batch_ids}
    for batch, raw_refs, operation_type, entity in changes:
        if entity is None:
            raise ValueError('Source change has no sync entity')
        if operation_type not in {'upsert', 'delete', 'resolve-conflict'}:
            raise ValueError('Invalid local operation type')
        if batch not in local:
            raise ValueError('Source changes are unbatched or assigned to a missing batch')
        try:
            refs = json.loads(raw_refs)
        except (TypeError, ValueError):
            raise ValueError('Invalid local blob references') from None
        if not isinstance(refs, list):
            raise ValueError('Invalid local blob references')
        for ref in refs:
            identifier(ref)
        # Tombstones refer to historical blobs for retention, not new uploads.
        local[batch].append(set() if operation_type == 'delete' else set(refs))
    previous_batch = previous_sequence = None
    for ordinal, (batch, sequence, state, prior_batch, prior_sequence) in enumerate(rows, 1):
        identifier(batch)
        if type(sequence) is not int or sequence != ordinal:
            raise ValueError('Source batch sequence is incomplete or duplicated')
        if (prior_batch, prior_sequence) != (previous_batch, previous_sequence):
            raise ValueError('Source batch predecessor mismatch')
        base = f'velock-sync/v1/{vault}/devices/{device}'
        batch_key = f'{base}/batches/{sequence:020d}/{batch}'
        envelope_path = checked_path(remote, f'{batch_key}/envelope.json')
        commit = read_object(checked_path(remote, f'{base}/commits/{sequence:020d}-{batch}.commit'))
        envelope = read_object(envelope_path)
        expected_identity = {'vaultId': vault, 'sourceDeviceId': device, 'batchId': batch, 'sequence': sequence}
        for artifact in (commit, envelope):
            if (any(artifact.get(key) != value for key, value in expected_identity.items())
                    or type(artifact.get('sequence')) is not int):
                raise ValueError('Remote batch identity mismatch')
        if commit.get('envelopeSha256') != hashlib.sha256(envelope_path.read_bytes()).hexdigest():
            raise ValueError('Remote envelope hash mismatch')
        if (envelope.get('previousBatchId'), envelope.get('previousSequence')) != (prior_batch, prior_sequence):
            raise ValueError('Remote batch predecessor mismatch')
        operations = envelope.get('operations')
        check_artifact(checked_path(remote, f'{batch_key}/operations.enc'), operations)
        count = operations.get('operationCount')
        if type(count) is not int or count != len(local[batch]) or count == 0:
            raise ValueError('Remote operation count does not cover source batch')
        blobs = envelope.get('blobs')
        if not isinstance(blobs, list):
            raise ValueError('Invalid remote blob manifest')
        seen = set()
        for blob in blobs:
            if not isinstance(blob, dict):
                raise ValueError('Invalid remote blob descriptor')
            blob_id = identifier(blob.get('blobId'))
            if len(blob_id) < 2 or blob_id in seen:
                raise ValueError('Invalid or duplicate remote blob identity')
            seen.add(blob_id)
            key = f'velock-sync/v1/{vault}/blobs/{blob_id[:2]}/{blob_id}.blob'
            if blob.get('logicalKey') != key:
                raise ValueError('Remote blob logical key mismatch')
            check_artifact(checked_path(remote, key), blob)
        if not set().union(*local[batch]).issubset(seen):
            raise ValueError('Source attachments missing from remote manifest')
        previous_batch, previous_sequence = batch, sequence
    return {'verified_remote_batches': len(rows)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--database', type=pathlib.Path, required=True)
    parser.add_argument('--remote', type=pathlib.Path, required=True)
    args = parser.parse_args()
    print(json.dumps(verify(args.database, args.remote)))
