#!/usr/bin/env python3
"""Run one opt-in tutorial preparation/content probe, outside video capture.
Uses disposable-device config and existing runner safety checks; never erases.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
from record import ROOT, replace_once, validate

TESTS = ('testTutorialImportText', 'testTutorialPrepareCredentials', 'testSeedVelockDocumentOnly',
         'testProbeVelockFileAndImageImport', 'testTutorialNavigationProbe',
         'testTutorialFileContentProbe', 'testTutorialPhotoContentProbe',
         'testTutorialCredentialContentProbe', 'testTutorialPrepareEnglish',
         'testTutorialInspectState', 'testTutorialRejectIncompleteRemoteHistory')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',type=Path,required=True)
    parser.add_argument('--test',choices=TESTS,required=True)
    parser.add_argument('--take',required=True)
    parser.add_argument('--app',type=Path,help='Explicit preparation-only or production app')
    parser.add_argument('--use-installed',action='store_true')
    args=parser.parse_args()
    c=json.loads(args.config.read_text());secrets=validate(c)
    if Path(args.take).name!=args.take or args.take in ('','.','..'): parser.error('Fresh single-component take required')
    out=Path(c['artifact_root'])/args.take
    os.umask(0o077);out.mkdir(parents=True,exist_ok=False)
    runner=ROOT/'tool/ios_ui_test/run_cross_app_ui_test.sh'
    source=runner.read_text()
    boundary='\nif [[ "${E2E_VERIFY_ALL_KINDS:-0}" == "1" ]]; then'
    if source.count(boundary)!=1:raise ValueError('Runner probe boundary changed')
    source=source.split(boundary,1)[0]
    source=replace_once(source,'"E2E_SEED_DATA",','"E2E_SEED_DATA", "E2E_TUTORIAL_DIR", "E2E_TUTORIAL_LANGUAGE", "E2E_TUTORIAL_FULL_CONTENT", "E2E_TUTORIAL_PHOTO_NAME",')
    source=replace_once(source,'--host 0.0.0.0','--host 127.0.0.1')
    source=replace_once(source,'install_targets=("$SOURCE_SIMULATOR_ID" "$REPLICA_SIMULATOR_ID")','install_targets=("$SOURCE_SIMULATOR_ID")')
    source=replace_once(source,'HARNESS_DERIVED_DATA="$CACHE_DIR/harness-derived-data"', 'HARNESS_DERIVED_DATA="'+str((out/'fresh-harness').resolve())+'"')
    env={k:v for k,v in os.environ.items() if not k.startswith(('E2E_','VELOCK_'))}
    env.update(secrets)
    env.update(VELOCK_ROOT=c['velock_root'],E2E_SOURCE_SIMULATOR_UDID=c['devices']['source'],
        E2E_REPLICA_SIMULATOR_UDID=c['devices']['replica'],E2E_ERASE_SOURCE='0',E2E_ERASE_REPLICA='0',
        E2E_WEBDAV_PORT=str(c['port']),E2E_WEBDAV_ROOT=str(out/'unused-local-remote'),
        E2E_BUILD_CACHE_DIR=str(Path(c['artifact_root'])/'probe-build-cache'),
        E2E_TUTORIAL_DIR=str(out),E2E_TUTORIAL_LANGUAGE=c['language'],E2E_TUTORIAL_FULL_CONTENT='1',E2E_TUTORIAL_PHOTO_NAME=c.get('photo_name','velock-sync-e2e-proof.png'),
        E2E_SEED_DATA='1',E2E_SEED_NOTE='1',E2E_SEED_CREDIT_CARD='1',
        E2E_SYNC_APP_PATH=c['sync_app'],E2E_VELOCK_APP_PATH=str(args.app.resolve()) if args.app else c['velock_app'])
    if args.use_installed:
        start=source.index('sign_simulator_app "$SYNC_APP_PATH"');end=source.index('# Resolve containers without booting',start)
        source=source[:start]+'echo "Caller explicitly reuses installed build"\n'+source[end:]
    else:
        for key in ('E2E_SYNC_APP_PATH','E2E_VELOCK_APP_PATH'):
            dest=out/(key+'.app');subprocess.run(['cp','-cR',env[key],str(dest)],check=True);env[key]=str(dest)
    source+='\nrun_ui_test "$SOURCE_SIMULATOR_ID" '+args.test+' tutorial-probe\n'
    (out/'runner-snapshot.sh').write_text(source)
    with (out/'run.log').open('w') as log:
        proc=subprocess.Popen(['bash','-c',source,str(runner)],env=env,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        try:code=proc.wait(timeout=700)
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid,signal.SIGTERM)
                try:proc.wait(timeout=25)
                except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait()
    print('PROBE',args.test,'exit',code,'private log',out/'run.log')
    return code

if __name__=='__main__':sys.exit(main())
