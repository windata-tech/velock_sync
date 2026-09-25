#!/usr/bin/env python3
"""Opt-in preparation of a NEW isolated tutorial source; never erases/uninstalls.

Run initialize, document, text, photo with a separately saved fixture app.
The caller owns simulator creation/boot and production builds. Reinstall the
production app over the same bundle using probe.py's production navigation probe,
then run verify and record.py --check. Preparation is not video acceptance.
"""
import argparse
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys

import probe
from record import validate
from tutorial_coverage import container_for, verify_recording_history, verify_source

PHASES = {
    'initialize': 'testSeedVelockBusinessData',
    'document': 'testSeedVelockDocumentOnly',
    'text': 'testTutorialImportText',
    'photo': 'testProbeVelockMediaImport',
}


def preflight(config, source, phase, devices_root=None):
    """Read-only guard; initial seeding may not reuse ANY existing vault DB."""
    if source != config['devices']['source']:
        raise ValueError('Explicit source does not match disposable config source')
    if config.get('replica_only'):
        raise ValueError('Fresh preparation must not use replica-only config')
    root = (devices_root or Path.home() / 'Library/Developer/CoreSimulator/Devices') / source
    if not root.is_dir():
        raise ValueError('Caller must create the new dedicated simulator first')
    if phase == 'initialize':
        for metadata in (root / 'data/Containers/Data/Application').glob('*/.com.apple.mobile_container_manager.metadata.plist'):
            with metadata.open('rb') as stream:
                identifier = plistlib.load(stream).get('MCMMetadataIdentifier')
            if identifier == 'tech.windata.velock' and (metadata.parent / 'Documents/venyoreDb').exists():
                raise ValueError('Initialize refuses existing source database; preserve it and use a NEW source')
    else:
        verify_recording_history(config, devices_root=devices_root)
    return root


def photo_fixture(root):
    """Use HostApp's generated proof, not a user photo or recovery card."""
    host = container_for(root, False, 'tech.windata.velock.crossapp.uitest.host')
    path = host / 'Documents/VelockSync-E2E-Source/velock-sync-e2e-proof.png'
    with path.open('rb') as stream:
        header = stream.read(24)
    if len(header) != 24 or header[:8] != b'\x89PNG\r\n\x1a\n' or header[12:16] != b'IHDR' or struct.unpack('>II', header[16:24]) != (960, 640):
        raise ValueError('Expected the 960x640 HostApp synthetic proof PNG')
    return path


def run_probe(argv, test):
    # Reuse the existing adapter, private logs, timeouts, clone/sign/install and
    # source-only scope. Extend its CLI allowlist IN MEMORY, never edit probe.py.
    previous_argv, previous_tests = sys.argv, probe.TESTS
    try:
        probe.TESTS = tuple(dict.fromkeys((*previous_tests, *PHASES.values())))
        sys.argv = ['probe.py', *argv, '--test', test]
        return probe.main()
    finally:
        sys.argv, probe.TESTS = previous_argv, previous_tests


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--source', required=True, help='Explicit NEW disposable source UDID')
    parser.add_argument('--phase', choices=(*PHASES, 'verify'), required=True)
    parser.add_argument('--take', help='New private preparation take name')
    parser.add_argument('--app', type=Path, help='Separate fixture app; never recording production path')
    parser.add_argument('--check', action='store_true', help='Read-only phase preflight, no device calls')
    args = parser.parse_args(argv)
    try:
        config = json.loads(args.config.read_text())
        validate(config)  # Reuse full-kind, private-secret and disposable guards.
        root = preflight(config, args.source, args.phase)
        if args.phase == 'verify':
            verify_source(config)
            print('Six-kind encrypted persistence and unpublished history verified; UI QA still required.')
            return 0
        if not args.take or Path(args.take).name != args.take or args.take in ('.', '..'):
            raise ValueError('A fresh single-component take is required')
        if (Path(config['artifact_root']) / args.take).exists():
            raise ValueError('Preparation take already exists')
        if not args.app or not (args.app / 'Info.plist').is_file():
            raise ValueError('Explicit separately saved fixture app required')
        if args.app.resolve() == Path(config['velock_app']).resolve():
            raise ValueError('Fixture app must differ from recording production app')
        image = photo_fixture(root) if args.phase == 'photo' else None
        if args.check:
            print('Preparation preflight OK; no device calls or file writes.')
            return 0
        if image is not None:
            # Existing runner uses simctl specifically for Photos fixture handoff.
            # Caller boots the source; do not start or touch other devices here.
            subprocess.run(['xcrun', 'simctl', 'addmedia', args.source, str(image)],
                           check=True, capture_output=True, timeout=60)
        code = run_probe(['--config', str(args.config), '--take', args.take,
                          '--app', str(args.app)], PHASES[args.phase])
        if code:
            return code
        verify_recording_history(config)
        print('Preparation phase passed; source remains unpublished. Not recording acceptance.')
        return 0
    except (ValueError, OSError, subprocess.SubprocessError):
        # Do not interpolate private config, secrets or subprocess output.
        print('Preparation refused or failed; inspect phase inputs/private probe log. No history gate bypass.', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
