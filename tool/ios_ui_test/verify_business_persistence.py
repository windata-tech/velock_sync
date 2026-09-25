"""Validate real encrypted persistence for each data class (not UI success alone).

This is a persistence check, NOT proof of content decryption or fresh recovery.
"""
from contextlib import closing
import argparse
import hashlib
import json
import pathlib
import plistlib
import sqlite3


# Fixed local test-database tables, not a parser for production business payloads.
BUSINESS_TABLES = {
    'password': 't_password', 'card': 't_card', 'note': 't_note',
    'document': 't_document', 'file': 't_file',
}


def validate_business_links(connection, sandbox_id, tables=None, after_id=0):
    """Reject partial indexing/restoration when the local mapping schema exists.

    Older metadata-only fixtures have no business tables or mapping columns.
    Keep those usable; actual business rows require the complete mapping schema.
    """
    columns = {row[1] for row in connection.execute('PRAGMA table_info(t_sync_entity)')}
    if not columns:
        return
    available = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if not columns.intersection({'local_table', 'local_id'}):
        if available.intersection(BUSINESS_TABLES.values()):
            raise ValueError('Incomplete business mapping schema')
        return
    if not {'local_table', 'local_id'}.issubset(columns):
        raise ValueError('Incomplete business mapping schema')
    selected = set(BUSINESS_TABLES.values()) if tables is None else set(tables)
    scope = ' AND sandbox_id = ?' if sandbox_id is not None else ''
    parameters = (sandbox_id,) if sandbox_id is not None else ()
    entities = connection.execute(
        'SELECT entity_type, local_table, local_id, sandbox_id, current_revision_id FROM t_sync_entity '
        'WHERE deleted_at IS NULL' + scope, parameters).fetchall()
    mappings = {}
    for kind, table, ident, sandbox, revision in entities:
        expected = BUSINESS_TABLES.get(kind)
        if expected not in selected and table not in selected:
            continue
        if expected != table or table not in available or not isinstance(ident, int) or ident < 1:
            raise ValueError('Invalid business mapping')
        if ident <= after_id:
            continue
        if not isinstance(revision, str) or not revision.strip():
            raise ValueError('Business mapping has no current revision')
        key = (table, ident, sandbox)
        if key in mappings:
            raise ValueError('Duplicate business mapping')
        mappings[key] = revision
        rows = connection.execute(f'SELECT id FROM {table} WHERE id = ? AND sandbox_id = ?',
                                  (ident, sandbox)).fetchall()
        if len(rows) != 1:
            raise ValueError('Live sync entity is missing its business record')
    for table in selected & available:
        rows = connection.execute(f'SELECT id, sandbox_id FROM {table} WHERE id > ?' + scope,
                                  (after_id, *parameters)).fetchall()
        for ident, sandbox in rows:
            if (table, ident, sandbox) not in mappings:
                raise ValueError('Business record is missing its live sync entity')


def checked_path(root, name):
    if (not isinstance(name, str) or not name or pathlib.Path(name).is_absolute()
            or '..' in pathlib.Path(name).parts or '\\' in name):
        raise ValueError('Encrypted file has an invalid path')
    target = (root / name).resolve()
    if not target.is_relative_to(root.resolve()):
        raise ValueError('Encrypted file has an invalid path')
    return target


def file_record_path(connection, root, row):
    """Resolve t_file parents instead of accepting a same-name root decoy."""
    names = [row['name']]
    seen = {row['id']}
    parent = row.get('parent_id')
    while parent is not None:
        if parent in seen:
            raise ValueError('File parent graph contains a cycle')
        seen.add(parent)
        parents = connection.execute('SELECT * FROM t_file WHERE id = ?', (parent,)).fetchall()
        if len(parents) != 1:
            raise ValueError('File parent is missing')
        ancestor = dict(parents[0])
        if (ancestor.get('sandbox_id') != row.get('sandbox_id')
                or ancestor['category_id'] != row['category_id'] or ancestor.get('type') != 1):
            raise ValueError('File parent belongs to a different scope or is not a directory')
        names.insert(0, ancestor['name'])
        parent = ancestor.get('parent_id')
    for name in names:
        checked_path(root, name)
    return checked_path(root, str(pathlib.Path(*names)))


def encrypted_evidence(target, ident):
    if not target.is_file() or target.stat().st_size == 0:
        raise ValueError(f'Record {ident} encrypted file missing/empty')
    digest = hashlib.sha256()
    size = 0
    with target.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            size += len(chunk)
            digest.update(chunk)
    if not size:
        raise ValueError(f'Record {ident} encrypted file missing/empty')
    return {'id': ident, 'encrypted_bytes': size, 'sha256': digest.hexdigest()}


def verify(database, root, kinds, after_id=0, sandbox_id=None):
    specifications = {
        'password': ('t_password', 'encrypted_filename', 'Credential/Password', ''),
        'card': ('t_card', 'encrypted_filename', 'Credential/Card', ''),
        'note': ('t_note', 'encrypted_filename', 'Credential/Note', ''),
        'document': ('t_document', 'name', 'Document', ''),
        'file': ('t_file', 'name', 'File', " AND category_id IN (SELECT id FROM t_category WHERE name = 'file')"),
        'media': ('t_file', 'name', 'Media', " AND category_id IN (SELECT id FROM t_category WHERE name = 'media')"),
    }
    kinds = list(kinds)
    if not kinds or any(kind not in specifications for kind in kinds):
        raise ValueError('Expected supported business kinds')
    result = {}
    with closing(sqlite3.connect(f'{database.resolve().as_uri()}?mode=ro', uri=True)) as connection:
        connection.row_factory = sqlite3.Row
        connection.execute('BEGIN')
        validate_business_links(connection, sandbox_id,
                                {specifications[kind][0] for kind in kinds}, after_id)
        for kind in kinds:
            table, column, folder, condition = specifications[kind]
            scope = ' AND sandbox_id = ?' if sandbox_id is not None else ''
            parameters = (after_id, sandbox_id) if sandbox_id is not None else (after_id,)
            rows = connection.execute(
                f'SELECT * FROM {table} WHERE id > ?{condition}{scope} ORDER BY id', parameters).fetchall()
            if not rows:
                raise ValueError(f'No {kind} records after id {after_id}')
            evidence = []
            base = checked_path(root, folder)
            for record in rows:
                row = dict(record)
                ident, name = row['id'], row[column]
                if not name:
                    raise ValueError(f'{kind} {ident} has no encrypted filename')
                if table == 't_file' and row.get('type', 0) not in (0, 1):
                    raise ValueError(f'{kind} {ident} has unsupported file artifact type')
                target = (file_record_path(connection, base, row) if table == 't_file'
                          else checked_path(base, name))
                if table == 't_file' and row.get('type') == 1:
                    if not target.is_dir():
                        raise ValueError(f'{kind} {ident} directory missing')
                    evidence.append({'id': ident, 'directory': True})
                    continue
                if kind == 'media':
                    try:
                        info = json.loads(row.get('info_json'))
                    except (ValueError, TypeError):
                        raise ValueError(f'Missing media metadata: {ident}') from None
                    if not isinstance(info, dict):
                        raise ValueError(f'Missing media metadata: {ident}')
                evidence.append(encrypted_evidence(target, ident))
            if not any('encrypted_bytes' in item for item in evidence):
                raise ValueError(f'No newly persisted {kind} records (only directories)')
            result[kind] = evidence
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--simulator-id', required=True)
    parser.add_argument('--database', type=pathlib.Path, required=True)
    parser.add_argument('--kinds', nargs='+', default=['password', 'card', 'note', 'document', 'file', 'media'])
    parser.add_argument('--after-id', type=int, default=0)
    parser.add_argument('--sandbox-id', type=int, required=True,
                        help='Recovered sandbox to verify; never count other retained spaces')
    args = parser.parse_args()
    groups = pathlib.Path.home() / 'Library/Developer/CoreSimulator/Devices' / args.simulator_id / 'data/Containers/Shared/AppGroup'
    roots = [metadata.parent for metadata in groups.glob('*/.com.apple.mobile_container_manager.metadata.plist')
             if plistlib.loads(metadata.read_bytes()).get('MCMMetadataIdentifier') == 'group.tech.windata.velock']
    if len(roots) != 1:
        raise ValueError('Expected one Velock shared container')
    print(json.dumps(verify(args.database, roots[0], args.kinds, args.after_id, args.sandbox_id), indent=2))


if __name__ == '__main__':
    main()
