"""Read-only check of newly imported media, not the obsolete t_media_info table."""
from contextlib import closing
import argparse
import hashlib
import json
import pathlib
import plistlib
import sqlite3

parser = argparse.ArgumentParser()
parser.add_argument('--simulator-id', required=True)
parser.add_argument('--database', type=pathlib.Path, required=True)
parser.add_argument('--after-id', type=int, default=0)
parser.add_argument('--sandbox-id', type=int, required=True)
args = parser.parse_args()
groups = pathlib.Path.home() / 'Library/Developer/CoreSimulator/Devices' / args.simulator_id / 'data/Containers/Shared/AppGroup'
roots = []
for metadata in groups.glob('*/.com.apple.mobile_container_manager.metadata.plist'):
    if plistlib.loads(metadata.read_bytes()).get('MCMMetadataIdentifier') == 'group.tech.windata.velock':
        roots.append(metadata.parent / 'Media')
assert len(roots) == 1, 'Expected one Velock media container'
with closing(sqlite3.connect(f'{args.database.as_uri()}?mode=ro', uri=True)) as connection:
    rows = connection.execute("select id, name, info_json from t_file where category_id IN (SELECT id FROM t_category WHERE name = 'media') and id > ? and sandbox_id = ?", (args.after_id, args.sandbox_id)).fetchall()
assert rows, 'No newly persisted media records'
evidence = []
for ident, name, info in rows:
    target = (roots[0] / name).resolve()
    assert target.is_relative_to(roots[0].resolve()), 'Invalid media path'
    assert target.is_file() and target.stat().st_size > 0, f'Missing encrypted media: {ident}'
    assert isinstance(json.loads(info), dict), f'Missing media metadata: {ident}'
    evidence.append({'id': ident, 'encrypted_bytes': target.stat().st_size,
                     'sha256': hashlib.sha256(target.read_bytes()).hexdigest()})
print(json.dumps({'verified_media': evidence}, indent=2))
