"""Read-only check of newly imported media, not the obsolete t_media_info table."""
import argparse
import json
import pathlib
import plistlib

if __package__:
    from .verify_business_persistence import verify as verify_business
else:
    from verify_business_persistence import verify as verify_business


def verify(database, root, after_id=0, sandbox_id=None):
    evidence = verify_business(database, root, ['media'], after_id, sandbox_id)['media']
    # A newly created folder is not evidence of a successfully imported asset.
    if not any('encrypted_bytes' in item for item in evidence):
        raise ValueError('No newly persisted media records')
    return {'verified_media': evidence}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--simulator-id', required=True)
    parser.add_argument('--database', type=pathlib.Path, required=True)
    parser.add_argument('--after-id', type=int, default=0)
    parser.add_argument('--sandbox-id', type=int, required=True)
    args = parser.parse_args()
    groups = pathlib.Path.home() / 'Library/Developer/CoreSimulator/Devices' / args.simulator_id / 'data/Containers/Shared/AppGroup'
    roots = [metadata.parent for metadata in groups.glob('*/.com.apple.mobile_container_manager.metadata.plist')
             if plistlib.loads(metadata.read_bytes()).get('MCMMetadataIdentifier') == 'group.tech.windata.velock']
    if len(roots) != 1:
        raise ValueError('Expected one Velock media container')
    print(json.dumps(verify(args.database, roots[0], args.after_id, args.sandbox_id), indent=2))


if __name__ == '__main__':
    main()
