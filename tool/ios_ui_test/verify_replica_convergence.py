"""Require every live source revision on the replica, including new fixtures.

Uses read-only databases. Does not expose vault keys or credential plaintext.
"""
import argparse
from contextlib import closing
import json
import pathlib
import plistlib
import sqlite3


def snapshot(database):
    with closing(sqlite3.connect(f'{database.resolve().as_uri()}?mode=ro', uri=True)) as connection:
        # Retained simulators can contain unrelated spaces. Verify the selected
        # space, never choose whichever vault happens to match the source.
        preferences = database.parent.parent / 'Library/Preferences/tech.windata.velock.plist'
        sandbox_id = None
        if preferences.exists():
            with preferences.open('rb') as stream:
                values = plistlib.load(stream)
            sandbox_id = values.get('current_sandbox_id')
        condition, parameters = (' AND sandbox_id = ?', (sandbox_id,)) if sandbox_id is not None else ('', ())
        identities = connection.execute(
            'SELECT vault_id, local_device_id, sandbox_id FROM t_sync_vault WHERE enabled = 1' + condition,
            parameters).fetchall()
        if len(identities) != 1:
            raise ValueError('Expected one enabled selected test vault')
        vault_id, device_id, selected_sandbox = identities[0]
        rows = connection.execute(
            'SELECT entity_uuid, entity_type, current_revision_id FROM t_sync_entity '
            'WHERE deleted_at IS NULL AND sandbox_id = ?', (selected_sandbox,)).fetchall()
        return (vault_id, device_id), {row[0]: (row[1], row[2]) for row in rows}



def compare_identities(source_identity, replica_identity):
    if source_identity[0] != replica_identity[0]:
        raise ValueError('Replica recovered a different vault')
    if source_identity[1] == replica_identity[1]:
        raise ValueError('Replica must have its own device identity')


def compare(source, replica):
    source_identity, source_entities = source
    replica_identity, replica_entities = replica
    compare_identities(source_identity, replica_identity)
    if not source_entities:
        raise ValueError('Source has no live sync entities')
    missing = sum(replica_entities.get(ident) != revision for ident, revision in source_entities.items())
    if missing:
        raise ValueError(f'{missing} source revisions missing or stale on replica')
    counts = {}
    for kind, _ in source_entities.values():
        counts[kind] = counts.get(kind, 0) + 1
    return counts


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-database', type=pathlib.Path, required=True)
    parser.add_argument('--replica-database', type=pathlib.Path, required=True)
    parser.add_argument('--identity-only', action='store_true')
    args = parser.parse_args()
    if args.identity_only:
        source, replica = snapshot(args.source_database), snapshot(args.replica_database)
        compare_identities(source[0], replica[0])
        print(json.dumps({'recovered_original_vault': True, 'distinct_device_identity': True}))
        raise SystemExit(0)
    print(json.dumps({'matching_source_revisions': compare(snapshot(args.source_database), snapshot(args.replica_database))}, indent=2))
