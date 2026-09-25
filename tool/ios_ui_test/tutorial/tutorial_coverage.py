"""Fail-closed tutorial coverage. No simulator launch, writes or secret decoding."""
import json
import pathlib
import plistlib
import sys
import sqlite3
from contextlib import closing

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from verify_business_persistence import verify

# media is a t_file category, NOT a distinct sync entity_type.
REQUIRED_KINDS = ('file', 'media', 'password', 'card', 'note', 'document')


def require_full_coverage(config):
    kinds = config.get('required_kinds', list(REQUIRED_KINDS))
    if not isinstance(kinds, list) or len(kinds) != len(set(kinds)) or set(kinds) != set(REQUIRED_KINDS):
        raise ValueError('Full tutorial requires file, media, password, card, note, document; subsets are not publication coverage')
    if config.get('prepared') is not True or config.get('keep_source') is not True:
        raise ValueError('Prepare all six source kinds before recording; prepared=true and keep_source=true are required')
    return list(REQUIRED_KINDS)


def container_for(simulator_root, group, identifier):
    containers = simulator_root / ('data/Containers/Shared/AppGroup' if group else 'data/Containers/Data/Application')
    matches = []
    for metadata in containers.glob('*/.com.apple.mobile_container_manager.metadata.plist'):
        with metadata.open('rb') as stream:
            if plistlib.load(stream).get('MCMMetadataIdentifier') == identifier:
                matches.append(metadata.parent)
    if len(matches) != 1:
        raise ValueError('Expected exactly one source container: ' + identifier)
    return matches[0]


def verify_source(config, devices_root=None):
    kinds = require_full_coverage(config)
    devices_root = devices_root or pathlib.Path.home() / 'Library/Developer/CoreSimulator/Devices'
    simulator_root = devices_root / config['devices']['source']
    app = container_for(simulator_root, False, 'tech.windata.velock')
    group = container_for(simulator_root, True, 'group.tech.windata.velock')
    with (app / 'Library/Preferences/tech.windata.velock.plist').open('rb') as stream:
        sandbox = plistlib.load(stream).get('current_sandbox_id')
    if isinstance(sandbox, bool) or not str(sandbox).isdigit() or int(sandbox) < 1:
        raise ValueError('No valid selected source sandbox')
    evidence = verify(app / 'Documents/venyoreDb', group, kinds, sandbox_id=int(sandbox))
    # A directory-only album or files tree is not content evidence.
    for kind in kinds:
        if not any(row.get('encrypted_bytes', 0) > 0 for row in evidence.get(kind, [])):
            raise ValueError('Missing real source payload: ' + kind)
    return evidence


UI_KINDS = frozenset(('file', 'media', 'password', 'card', 'note'))


def verify_ui_evidence(take, replica_only=False):
    """Every published flow must open the five requested types; no title-only tour."""
    for phase in (('replica',) if replica_only else ('source', 'replica')):
        report = json.loads((pathlib.Path(take) / (phase + '-ui-coverage.json')).read_text())
        kinds = report.get('verified_ui_kinds', [])
        if not isinstance(kinds, list) or len(kinds) != len(UI_KINDS) or set(kinds) != UI_KINDS:
            raise ValueError('Incomplete decrypted UI coverage: ' + phase)


def require_fresh_remote_source(database, sandbox_id):
    """An empty tutorial remote cannot recover already-consumed old outboxes.

    Progress-only checkpoints are not business snapshots. This is a recording
    precondition, not a workaround or a claim that remote migration is fixed.
    """
    with closing(sqlite3.connect(f'{pathlib.Path(database).resolve().as_uri()}?mode=ro', uri=True)) as db:
        published = db.execute(
            "SELECT COUNT(*) FROM t_sync_outbound_batch WHERE sandbox_id=? AND state IN ('published','acknowledged')",
            (sandbox_id,),
        ).fetchone()[0]
    if published:
        raise ValueError('Source has previously published batches; a fresh empty remote cannot stand in for its existing backup. Prepare a genuinely unsynced source or use replica-only with its complete retained remote. Progress checkpoints contain no business data.')


def verify_recording_history(config, devices_root=None):
    # Replica-only reuses an explicit retained backup; the normal recording
    # path always creates a new empty root and therefore needs this guard.
    if config.get('replica_only'):
        return
    devices_root = devices_root or pathlib.Path.home() / 'Library/Developer/CoreSimulator/Devices'
    app = container_for(devices_root / config['devices']['source'], False, 'tech.windata.velock')
    with (app / 'Library/Preferences/tech.windata.velock.plist').open('rb') as stream:
        sandbox = plistlib.load(stream).get('current_sandbox_id')
    if isinstance(sandbox, bool) or not str(sandbox).isdigit() or int(sandbox) < 1:
        raise ValueError('No valid selected source sandbox')
    require_fresh_remote_source(app / 'Documents/venyoreDb', int(sandbox))
