#!/usr/bin/env python3
"""Isolated runner regression: no Xcode, simulator, or WebDAV service is used.

All fixtures/cache/results live in a temporary directory outside the repository.
The codesign stub stops each build-path run before any installation/UI test.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import tempfile
import unittest

RUNNER = Path(__file__).with_name('run_cross_app_ui_test.sh')
SOURCE = '11111111-1111-1111-1111-111111111111'
REPLICA = '22222222-2222-2222-2222-222222222222'


class RunnerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='velock-runner-test-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'sync project'
        self.velock = self.base / 'velock project'
        self.runner = self.root / 'tool/ios_ui_test/run_cross_app_ui_test.sh'
        self.runner.parent.mkdir(parents=True)
        shutil.copy2(RUNNER, self.runner)
        for root in (self.root, self.velock):
            (root / 'ios/Runner.xcworkspace').mkdir(parents=True)
        project = self.root / 'ui_test_harness/CrossAppUITests.xcodeproj'
        project.mkdir(parents=True)
        (project / 'project.pbxproj').touch()
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        self.log = self.base / 'calls.jsonl'
        self.stub('mcp', '''#!/usr/bin/python3
import json, os, pathlib, plistlib, sys
args = sys.argv[1:]
with open(os.environ['CALL_LOG'], 'a') as out:
    out.write(json.dumps(args) + '\\n')
if args[:2] == ['simulator', 'list']:
    text = '\\n'.join('- iPhone (' + os.environ[key] + ')' for key in ('E2E_SOURCE_SIMULATOR_UDID', 'E2E_REPLICA_SIMULATOR_UDID'))
    if os.environ.get('BAD_INVENTORY'): text = 'Hint: ' + text.replace('- iPhone ', '')
    print(json.dumps({'content': [{'type': 'text', 'text': text}]}))
elif args[:2] == ['simulator', 'build']:
    if os.environ.get('BUILD_FAIL'): sys.exit(31)
    if os.environ.get('BUILD_FALSE_SUCCESS'):
        print('Build failed')
        sys.exit(0)
    dd = pathlib.Path(args[args.index('--derived-data-path') + 1])
    app = dd / 'Build/Products/Debug-iphonesimulator/Runner.app'
    app.mkdir(parents=True, exist_ok=True)
    bundle = 'tech.windata.velock.sync' if dd.name.startswith('sync') else 'tech.windata.velock'
    with (app / 'Info.plist').open('wb') as out:
        plistlib.dump({'CFBundleIdentifier': bundle, 'CFBundleSupportedPlatforms': ['iPhoneSimulator'], 'CFBundleExecutable': 'Runner'}, out)
    (app / 'Runner').touch()
    (app / 'Runner').chmod(0o755)
    print('✅ iOS Simulator Build build succeeded for scheme Runner.')
else:
    raise SystemExit('Unexpected device/test command: ' + str(args))
''')
        self.stub('xcodebuild', '#!/bin/bash\nprintf "%s\\n" "${MOCK_XCODE:-Xcode test build 1}"\n')
        # A sleeping process, not a network service. cleanup must terminate it.
        self.stub('webdav', '#!/bin/bash\necho started >> "$SERVER_MARKER"\nexec /bin/sleep 60\n')
        self.stub('curl', '#!/bin/bash\n[[ "${CURL_FAIL:-0}" != 1 ]]\n')
        self.stub('codesign', '#!/bin/bash\necho reached >> "$SIGN_MARKER"\nexit 42\n')
        self.stub('sleep', '#!/bin/bash\nexit 0\n')
        for command in ('sqlite3', 'xcrun'):
            self.stub(command, '#!/bin/bash\nexit 99\n')
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('E2E_', 'VELOCK_', 'XCODEBUILDMCP_'))}
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        self.env.update(
            PATH=str(self.bin) + ':' + os.environ['PATH'],
            VELOCK_ROOT=str(self.velock), XCODEBUILDMCP_BIN=str(self.bin / 'mcp'),
            E2E_WEBDAV_BIN=str(self.bin / 'webdav'), E2E_WEBDAV_PORT=str(port),
            E2E_SOURCE_SIMULATOR_UDID=SOURCE, E2E_REPLICA_SIMULATOR_UDID=REPLICA,
            E2E_BUILD_CACHE_DIR=str(self.base / 'cache'), CALL_LOG=str(self.log),
            SERVER_MARKER=str(self.base / 'server'), SIGN_MARKER=str(self.base / 'sign'),
            VELOCK_RUNTIME_PASSWORD='mock-password', E2E_RECOVERY_PASSPHRASE='mock-recovery')

    def stub(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)

    def run_runner(self, expected, **updates):
        self.log.write_text('')
        result = subprocess.run(['/bin/bash', str(self.runner)],
                                env=dict(self.env, **updates), text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=15)
        self.assertEqual(result.returncode, expected, result.stdout)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertTrue(all(c[:2] in (['simulator', 'list'], ['simulator', 'build']) for c in calls))
        return result.stdout, calls

    def builds(self, calls):
        return [c[c.index('--derived-data-path') + 1] for c in calls if c[:2] == ['simulator', 'build']]

    def test_reuses_cache_but_always_builds_both(self):
        out, first = self.run_runner(1)
        _, second = self.run_runner(1)
        self.assertEqual(len(self.builds(first)), 2)
        self.assertEqual(self.builds(first), self.builds(second))
        self.assertEqual(sum(c[:2] == ['simulator', 'list'] for c in first), 1)
        self.assertIn('TIMING build-sync', out)
        self.assertIn('TIMING build-velock', out)
        self.assertTrue((self.base / 'sign').exists())
        self.assertFalse(list((self.base / 'cache').glob('*/.runner-lock')))

    def test_xcode_change_isolates_cache(self):
        _, first = self.run_runner(1)
        _, second = self.run_runner(1, MOCK_XCODE='Xcode test build 2')
        self.assertNotEqual(self.builds(first), self.builds(second))

    def test_cache_lock_is_not_stolen(self):
        _, calls = self.run_runner(1)
        lock = Path(self.builds(calls)[0]).parent / '.runner-lock'
        lock.mkdir()
        _, calls = self.run_runner(8)
        self.assertFalse(self.builds(calls))
        self.assertTrue(lock.exists())

    def test_failed_build_never_falls_back_to_cached_app(self):
        self.run_runner(1)
        out, calls = self.run_runner(31, BUILD_FAIL='1')
        self.assertEqual(len(self.builds(calls)), 1)
        self.assertNotIn('TIMING sign-and-install', out)
        out, _ = self.run_runner(7, BUILD_FALSE_SUCCESS='1')
        self.assertIn('refusing cached app', out)

    def test_explicit_prebuilt_and_invalid_bundle(self):
        _, calls = self.run_runner(1)
        app = Path(self.builds(calls)[1]) / 'Build/Products/Debug-iphonesimulator/Runner.app'
        _, calls = self.run_runner(1, E2E_VELOCK_APP_PATH=str(app))
        self.assertEqual(len(self.builds(calls)), 1)
        _, calls = self.run_runner(7, E2E_SYNC_APP_PATH=str(app))
        self.assertFalse(calls)
        info = app / 'Info.plist'
        data = plistlib.loads(info.read_bytes())
        data['CFBundleSupportedPlatforms'] = ['iPhoneOS']
        info.write_bytes(plistlib.dumps(data))
        self.run_runner(7, E2E_VELOCK_APP_PATH=str(app))

    def test_inventory_hint_is_not_a_device(self):
        _, calls = self.run_runner(5, BAD_INVENTORY='1')
        self.assertFalse(self.builds(calls))

    def test_same_simulator_rejected(self):
        _, calls = self.run_runner(4, E2E_REPLICA_SIMULATOR_UDID=SOURCE)
        self.assertFalse(calls)

    def test_invalid_and_occupied_port(self):
        self.run_runner(1, E2E_WEBDAV_PORT='65536')
        with socket.socket() as sock:
            sock.bind(('0.0.0.0', 0))
            sock.listen()
            _, calls = self.run_runner(1, E2E_WEBDAV_PORT=str(sock.getsockname()[1]))
            self.assertFalse(self.builds(calls))
        self.assertFalse((self.base / 'server').exists())

    def test_readiness_failure_never_installs(self):
        out, _ = self.run_runner(6, CURL_FAIL='1')
        self.assertIn('WsgiDAV did not start', out)
        self.assertFalse((self.base / 'sign').exists())

    def test_configuration_fails_before_build(self):
        _, calls = self.run_runner(10, E2E_REPLICA_ONLY='1')
        self.assertFalse(self.builds(calls))
        _, calls = self.run_runner(11, E2E_ERASE_SOURCE='1')
        self.assertFalse(self.builds(calls))
        _, calls = self.run_runner(9, E2E_RESUME_SOURCE='1', VELOCK_RUNTIME_PASSWORD='')
        self.assertFalse(self.builds(calls))

    def test_all_kinds_missing_image_fails_before_build(self):
        out, calls = self.run_runner(18, E2E_VERIFY_ALL_KINDS='1', E2E_IMPORT_IMAGE='')
        self.assertIn('requires a synthetic image fixture', out)
        self.assertEqual(calls, [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
