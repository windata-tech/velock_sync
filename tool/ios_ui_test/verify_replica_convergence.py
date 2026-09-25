"""Require every live source revision on the replica, including new fixtures.

Uses read-only databases. Does not expose vault keys or credential plaintext.
"""
import argparse
from contextlib import closing
import json
import pathlib
import plistlib
import sqlite3


if __package__:
    from .verify_business_persistence import (BUSINESS_TABLES, checked_path, encrypted_evidence,
                                              file_record_path, validate_business_links)
else:
    from verify_business_persistence import (BUSINESS_TABLES, checked_path, encrypted_evidence,
                                             file_record_path, validate_business_links)


# Only fields actually restored by the host upsert appliers. Local IDs, opaque
# filenames, cache flags and local timestamps are intentionally not comparable.
METADATA_FIELDS = {
    'password': ('title', 'account'),
    'card': ('is_pinned', 'title', 'card_number', 'card_type', 'name',
             'card_background_name', 'pinned_time'),
    'note': ('is_pinned', 'title', 'summary', 'name', 'pinned_time'),
    'document': ('is_pinned', 'summary', 'content', 'pinned_time'),
    'file': ('display_name', 'mime_type', 'ext', 'filesize', 'type',
             'info_json', 'original_time', 'live_photo_group_id'),
}


def shared_root(database):
    """Resolve only this simulator's AppGroup; exports must pass an explicit root."""
    for parent in database.resolve().parents:
        if parent.name == 'Containers' and parent.parent.name == 'data':
            roots = [path.parent for path in (parent / 'Shared/AppGroup').glob(
                '*/.com.apple.mobile_container_manager.metadata.plist')
                if plistlib.loads(path.read_bytes()).get('MCMMetadataIdentifier')
                == 'group.tech.windata.velock']
            if len(roots) == 1:
                return roots[0]
            break
    raise ValueError('Expected one Velock shared container; supply an explicit shared root for exports')


def business_snapshot(database, root):
    """Read host metadata and artifact evidence, never decrypt or emit field values.

    File/Media artifacts are copied byte-for-byte by SyncFileArtifactGateway.
    Credentials and documents are rewritten on restore, so their hashes must
    NOT be compared. Nonempty artifacts alone do not prove decryptability.
    """
    with closing(sqlite3.connect(f'{database.resolve().as_uri()}?mode=ro', uri=True)) as db:
        db.row_factory = sqlite3.Row
        db.execute('BEGIN')
        vault, device, sandbox = selected_vault(db, database)
        validate_business_links(db, sandbox)
        entities = db.execute('SELECT * FROM t_sync_entity WHERE deleted_at IS NULL '
                              'AND sandbox_id = ?', (sandbox,)).fetchall()
        result = {}
        for entity in entities:
            kind, ident = entity['entity_type'], entity['entity_uuid']
            if kind not in BUSINESS_TABLES:
                # Other protocol entities remain covered by revision comparison.
                continue
            if ident in result:
                raise ValueError('Duplicate sync entity identity')
            table = BUSINESS_TABLES[kind]
            row = dict(db.execute(f'SELECT * FROM {table} WHERE id = ? AND sandbox_id = ?',
                                  (entity['local_id'], sandbox)).fetchone())
            if not set(METADATA_FIELDS[kind]).issubset(row):
                raise ValueError(f'Incomplete {kind} business metadata schema')
            metadata = {key: row[key] for key in METADATA_FIELDS[kind]}
            directory = False
            if kind == 'file':
                categories = db.execute('SELECT name FROM t_category WHERE id = ?',
                                        (row['category_id'],)).fetchall()
                if len(categories) != 1 or categories[0][0] not in ('file', 'media'):
                    raise ValueError('Invalid file category')
                category = categories[0][0]
                metadata['category'] = category
                if row['type'] not in (0, 1):
                    raise ValueError('Unsupported file artifact type')
                directory = row['type'] == 1
                parent = row['parent_id']
                parents = [] if parent is None else db.execute(
                    "SELECT entity_uuid FROM t_sync_entity WHERE local_table = 't_file' "
                    'AND local_id = ? AND sandbox_id = ? AND deleted_at IS NULL',
                    (parent, sandbox)).fetchall()
                if parent is not None and len(parents) != 1:
                    raise ValueError('File parent has no unique live entity')
                metadata['parent_entity'] = parents[0][0] if parents else None
                if metadata['info_json'] is not None:
                    try:
                        metadata['info_json'] = json.loads(metadata['info_json'])
                    except (ValueError, TypeError):
                        raise ValueError('Invalid file metadata') from None
                if category == 'media' and not directory and not isinstance(metadata['info_json'], dict):
                    raise ValueError('Missing media metadata')
                # Host serializes originalTime in UTC during inbound application.
                if metadata['original_time'] is not None:
                    from datetime import datetime, timezone
                    value = datetime.fromisoformat(metadata['original_time'].replace('Z', '+00:00'))
                    # Dart parses offset-free local timestamps in the device's
                    # local zone. These host checks assume the same local zone.
                    metadata['original_time'] = value.astimezone(timezone.utc).isoformat()
                target = file_record_path(db, checked_path(root, category.title()), row)
            else:
                folder = 'Document' if kind == 'document' else 'Credential/' + kind.title()
                column = 'name' if kind == 'document' else 'encrypted_filename'
                target = checked_path(checked_path(root, folder), row[column])
            if directory:
                if not target.is_dir():
                    raise ValueError('Business directory missing')
                artifact = {'directory': True}
            else:
                evidence = encrypted_evidence(target, entity['local_id'])
                artifact = ({key: evidence[key] for key in ('encrypted_bytes', 'sha256')}
                            if kind == 'file' else {'nonempty_rewritten_artifact': True})
            result[ident] = (kind, entity['current_revision_id'], metadata, artifact)
        return (vault, device), result


def compare_business(source, replica):
    compare_identities(source[0], replica[0])
    if not source[1]:
        raise ValueError('Source has no comparable business records')
    counts = {}
    for ident, record in source[1].items():
        if replica[1].get(ident) != record:
            # Do not leak account/card values or metadata through diagnostics.
            raise ValueError('Source business metadata or encrypted file bytes differ on replica')
        kind, _, metadata, artifact = record
        category = metadata['category'] if kind == 'file' else kind
        if not artifact.get('directory'):
            counts[category] = counts.get(category, 0) + 1
    if not counts:
        raise ValueError('Source has only business directories')
    return counts


def selected_vault(connection, database):
    # Retained test exports may contain unrelated spaces. Never choose a vault
    # merely because its rows happen to satisfy the verification.
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
    if any(not isinstance(value, str) or not value.strip() for value in identities[0][:2]):
        raise ValueError('Vault and device identity must be nonempty')
    return identities[0]


def snapshot(database, identity_only=False):
    with closing(sqlite3.connect(f'{database.resolve().as_uri()}?mode=ro', uri=True)) as connection:
        connection.execute('BEGIN')
        vault_id, device_id, sandbox_id = selected_vault(connection, database)
        if identity_only:
            return (vault_id, device_id), {}
        validate_business_links(connection, sandbox_id)
        rows = connection.execute(
            'SELECT entity_uuid, entity_type, current_revision_id FROM t_sync_entity '
            'WHERE deleted_at IS NULL AND sandbox_id = ?', (sandbox_id,)).fetchall()
        entities = {}
        for ident, kind, revision in rows:
            if any(not isinstance(value, str) or not value.strip() for value in (ident, kind, revision)):
                raise ValueError('Live entity has an empty identity, type or revision')
            if ident in entities:
                raise ValueError('Duplicate sync entity identity')
            entities[ident] = (kind, revision)
        return (vault_id, device_id), entities


def compare_identities(source_identity, replica_identity):
    if any(len(identity) != 2 or any(not isinstance(value, str) or not value.strip() for value in identity)
           for identity in (source_identity, replica_identity)):
        raise ValueError('Vault and device identity must be nonempty')
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
    for entities in (source_entities, replica_entities):
        for ident, revision in entities.items():
            if (len(revision) != 2 or any(not isinstance(value, str) or not value.strip()
                                         for value in (ident, *revision))):
                raise ValueError('Live entity has an empty identity, type or revision')
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
    parser.add_argument('--source-root', type=pathlib.Path,
                        help='Source shared AppGroup root (required for offline exports)')
    parser.add_argument('--replica-root', type=pathlib.Path,
                        help='Replica shared AppGroup root (required for offline exports)')
    args = parser.parse_args()
    if args.identity_only:
        source, replica = snapshot(args.source_database, identity_only=True), snapshot(args.replica_database, identity_only=True)
        compare_identities(source[0], replica[0])
        print(json.dumps({'recovered_original_vault': True, 'distinct_device_identity': True}))
        raise SystemExit(0)
    revisions = compare(snapshot(args.source_database), snapshot(args.replica_database))
    business = compare_business(
        business_snapshot(args.source_database, args.source_root or shared_root(args.source_database)),
        business_snapshot(args.replica_database, args.replica_root or shared_root(args.replica_database)))
    print(json.dumps({'matching_source_revisions': revisions,
                      'matching_business_records': business,
                      'file_media_ciphertext_compared': True,
                      'credential_plaintext_compared': False}, indent=2))
