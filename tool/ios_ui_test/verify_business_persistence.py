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


def verify(database, root, kinds, after_id=0, sandbox_id=None):
    specifications = {
        'password': ('t_password', 'encrypted_filename', 'Credential/Password', ''),
        'card': ('t_card', 'encrypted_filename', 'Credential/Card', ''),
        'note': ('t_note', 'encrypted_filename', 'Credential/Note', ''),
        'document': ('t_document', 'name', 'Document', ''),
        'file': ('t_file', 'name', 'File', ' AND category_id IN (SELECT id FROM t_category WHERE name = \'file\')'),
        'media': ('t_file', 'name', 'Media', ' AND category_id IN (SELECT id FROM t_category WHERE name = \'media\')'),
    }
    result = {}
    with closing(sqlite3.connect(f'{database.resolve().as_uri()}?mode=ro', uri=True)) as connection:
        for kind in kinds:
            table, column, folder, condition = specifications[kind]
            scope = ' AND sandbox_id = ?' if sandbox_id is not None else ''
            parameters = (after_id, sandbox_id) if sandbox_id is not None else (after_id,)
            rows = connection.execute(
                f'SELECT id, {column} FROM {table} WHERE id > ?{condition}{scope}',
                parameters,
            ).fetchall()
            if not rows:
                raise ValueError(f'No {kind} records after id {after_id}')
            evidence = []
            for ident, name in rows:
                if not name:
                    raise ValueError(f'{kind} {ident} has no encrypted filename')
                target = (root / folder / name).resolve()
                if not target.is_relative_to((root / folder).resolve()):
                    raise ValueError(f'{kind} {ident} has an invalid path')
                if not target.is_file() or target.stat().st_size == 0:
                    raise ValueError(f'{kind} {ident} encrypted file missing/empty')
                evidence.append({'id': ident, 'encrypted_bytes': target.stat().st_size,
                                 'sha256': hashlib.sha256(target.read_bytes()).hexdigest()})
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
