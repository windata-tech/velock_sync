"""Check that the retained test WebDAV contains every source batch, read-only."""
import argparse
import json
import pathlib
import sqlite3


def verify(database, remote):
    with sqlite3.connect(f'{database.resolve().as_uri()}?mode=ro', uri=True) as db:
        rows = db.execute('''SELECT v.vault_id,v.local_device_id,b.batch_id,b.sequence,b.state
            FROM t_sync_outbound_batch b JOIN t_sync_vault v ON b.sandbox_id=v.sandbox_id
            WHERE v.enabled=1''').fetchall()
    if not rows:
        raise ValueError('No source batches to verify')
    for vault, device, batch, sequence, state in rows:
        base = remote / 'velock-sync/v1' / vault / 'devices' / device
        batch_path = base / 'batches' / f'{sequence:020d}' / batch
        required = [batch_path / 'operations.enc', batch_path / 'envelope.json',
                    base / 'commits' / f'{sequence:020d}-{batch}.commit']
        if any(not path.is_file() or not path.stat().st_size for path in required):
            raise ValueError(f'Source batch {sequence} ({state}) missing from remote')
    return {'verified_remote_batches': len(rows)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--database', type=pathlib.Path, required=True)
    parser.add_argument('--remote', type=pathlib.Path, required=True)
    args = parser.parse_args()
    print(json.dumps(verify(args.database, args.remote)))
