#!/usr/bin/env python3
"""Native unedited tutorial recorder. See docs/testing/tutorial-recording.md.
--check validates configuration/runner compatibility without starting any devices.
"""
import argparse,json,os,pathlib,subprocess,threading,time,sys,signal,shutil
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parent))
from tutorial_coverage import REQUIRED_KINDS, require_full_coverage, verify_source, verify_ui_evidence, verify_recording_history
ROOT=pathlib.Path(__file__).resolve().parents[3]

def replace_once(source, old, new):
 if source.count(old)!=1:
  raise ValueError('Base runner changed; inspect tutorial adapter before recording: '+old[:80])
 return source.replace(old,new,1)

def validate(config):
 require_full_coverage(config)
 required=['language','artifact_root','devices','disposable_devices','sync_app','velock_app','velock_root','secrets_file','port']
 for key in required:
  if key not in config: raise ValueError('Missing config field: '+key)
 if config['language'] not in ('zh','en'): raise ValueError('language must be zh or en')
 ids=config['devices']
 if set(ids)!= {'source','replica'} or len(set(ids.values()))!=2: raise ValueError('Two distinct devices required')
 if not set(ids.values()) <= set(config['disposable_devices']): raise ValueError('Devices must be explicitly disposable')
 for key in ('artifact_root','sync_app','velock_app','velock_root','secrets_file'):
  p=pathlib.Path(config[key]).expanduser()
  if not p.is_absolute(): raise ValueError(key+' must be absolute')
  config[key]=str(p.resolve())
 artifact=pathlib.Path(config['artifact_root'])
 if artifact==ROOT or ROOT in artifact.parents: raise ValueError('Artifacts must resolve outside the source tree')
 for key in ('sync_app','velock_app'):
  if not (pathlib.Path(config[key])/'Info.plist').is_file(): raise ValueError('Missing app Info.plist: '+key)
 if not pathlib.Path(config['velock_root']).is_dir(): raise ValueError('Missing companion project')
 secret=pathlib.Path(config['secrets_file'])
 if secret.stat().st_mode & 0o077: raise ValueError('Secrets file must be private (chmod 600)')
 values=json.loads(secret.read_text())
 if not all(isinstance(k,str) and isinstance(v,str) for k,v in values.items()): raise ValueError('Secrets must map env names to strings')
 allowed={'VELOCK_RUNTIME_PASSWORD','E2E_RECOVERY_PASSPHRASE'}
 if not set(values)<=allowed or not values.get('VELOCK_RUNTIME_PASSWORD') or not all(values.values()): raise ValueError('Secrets require VELOCK_RUNTIME_PASSWORD; only optional E2E_RECOVERY_PASSPHRASE is allowed')
 if not 1024<=int(config['port'])<=65535: raise ValueError('Invalid local port')
 if config.get('replica_only'):
  if not config.get('keep_source'): raise ValueError('Replica-only requires keep_source')
  for key in ('recovery_card','remote_root'):
   if not pathlib.Path(config.get(key,'')).is_absolute() or not pathlib.Path(config[key]).exists(): raise ValueError('Missing explicit '+key)
 if config.get('use_installed') and not (config.get('keep_source') and config.get('keep_replica')): raise ValueError('use_installed requires both keep flags')
 if config.get('prepared') and not config.get('keep_source'): raise ValueError('prepared requires keep_source')
 build_mode=config.get('build_mode','debug')
 if build_mode not in ('debug','release'): raise ValueError('build_mode must be debug or release')
 if build_mode!='debug':
  raise ValueError('Flutter iOS Simulator does not support release/profile builds; use physical devices for Release recording')
 return values

error=[]; active={}; done=threading.Event()
def cli(args):
 r=subprocess.run([CLI,*args],capture_output=True,text=True,timeout=60)
 if r.returncode or '"isError":true' in r.stdout.replace(' ',''):
  raise RuntimeError(r.stdout[-1000:]+r.stderr[-1000:])
 return r.stdout

def recorder():
 try:
  for name,role in ([('02-new-device-recovery','replica')] if os.environ.get('TUTORIAL_REPLICA_ONLY')=='1' else [('01-first-setup','source'),('02-new-device-recovery','replica')]):
   while not (ART/('start-'+name)).exists():
    if done.wait(.2): return
   active.update(name=name,role=role)
   # XcodeBuildMCP AXe recorder cannot load SimulatorKit on this host.
   # Fall back to the native CoreSimulator encoder, with no postprocessing.
   logpath=ART/(name+'-native-recorder.log')
   with logpath.open('w') as capturelog:
    capture=subprocess.Popen(['xcrun','simctl','io',IDS[role],'recordVideo','--codec=h264',str(ART/(name+'.mp4'))],stdout=capturelog,stderr=subprocess.STDOUT)
    deadline=time.monotonic()+20
    while 'Recording started' not in logpath.read_text():
     if capture.poll() is not None or time.monotonic()>deadline: raise RuntimeError('Native recorder did not start: '+logpath.read_text())
     time.sleep(.1)
    (ART/('recording-'+name)).touch()
    print('RECORDING_STARTED',name,flush=True)
    while not (ART/('stop-'+name)).exists():
     if done.wait(.2): break
    capture.send_signal(signal.SIGINT)
    capture.wait(timeout=30)
    if capture.returncode: raise RuntimeError('Native recorder failed: '+logpath.read_text())
   (ART/('stopped-'+name)).touch()
   active.clear()
   print('RECORDING_SAVED',name,flush=True)
 except Exception as e:
  if 'capture' in locals() and capture.poll() is None:
   capture.send_signal(signal.SIGINT)
   try: capture.wait(timeout=30)
   except subprocess.TimeoutExpired: capture.kill(); capture.wait()
  error.append(str(e));print('RECORDER_ERROR',str(e),flush=True)


def run():
 # Recheck actual source data immediately before any simulator reset/boot.
 verify_recording_history(config)
 source_evidence=verify_source(config)
 (ART/'source-coverage.json').write_text(json.dumps(source_evidence,indent=2))
 # Dedicated new simulators only. Existing test/user simulators are untouched.
 for ident in IDS.values():
  cli(['simulator','boot','--simulator-id',ident])
 cli(['daemon','start'])
 env={k:v for k,v in os.environ.items() if not k.startswith(('E2E_','VELOCK_'))}
 env.update(secrets)
 env.update(E2E_SOURCE_SIMULATOR_UDID=IDS['source'],E2E_REPLICA_SIMULATOR_UDID=IDS['replica'],
  E2E_SYNC_APP_PATH=config['sync_app'],
  E2E_VELOCK_APP_PATH=config['velock_app'],
  E2E_WEBDAV_ROOT=str(ART/'webdav-public-root'),E2E_WEBDAV_PORT=str(config['port']),
  E2E_REQUIRED_KINDS=','.join(REQUIRED_KINDS),E2E_TUTORIAL_FULL_CONTENT='1',E2E_TUTORIAL_PHOTO_NAME=config.get('photo_name','velock-sync-e2e-proof.png'),E2E_SEED_DATA='1',E2E_ERASE_SOURCE='0' if os.environ.get('TUTORIAL_KEEP_SOURCE')=='1' else '1',E2E_ERASE_REPLICA='0' if os.environ.get('TUTORIAL_KEEP_REPLICA')=='1' else '1',E2E_ALLOW_ERASE='1',E2E_TUTORIAL_CLEAN='1',E2E_TUTORIAL_PACE='1',E2E_TUTORIAL_PREPARED=os.environ.get('TUTORIAL_PREPARED','0'),E2E_TUTORIAL_LANGUAGE=LANG,
  VELOCK_E2E_SANDBOX_NAME='Velock E2E Tutorial' if LANG=='en' else 'Velock E2E 教程演示',E2E_TUTORIAL_DIR=str(ART))
 if os.environ.get('TUTORIAL_REPLICA_ONLY') == '1':
  assert os.environ.get('TUTORIAL_KEEP_SOURCE') == '1'
  env.update(E2E_REPLICA_ONLY='1',E2E_EXISTING_RECOVERY_CARD=config['recovery_card'],E2E_WEBDAV_ROOT=config['remote_root'])
 
 # Independent signed snapshots; UI and simulator preparation must still run serially.
 for key in ['E2E_SYNC_APP_PATH','E2E_VELOCK_APP_PATH']:
  destination=ART/(key+'.app')
  subprocess.run(['cp','-cR',env[key],str(destination)],check=True)
  env[key]=str(destination)
 env['E2E_BUILD_CACHE_DIR']=str(ART/'build-cache')
 env['XCODEBUILDMCP_BIN']=CLI
 env['VELOCK_ROOT']=config['velock_root']
 runner=ROOT/'tool/ios_ui_test/run_cross_app_ui_test.sh'
 source=replace_once(runner.read_text(),'"E2E_SEED_DATA",','"E2E_SEED_DATA",\n        "E2E_TUTORIAL_DIR",\n        "E2E_TUTORIAL_CLEAN",\n        "E2E_TUTORIAL_PACE",\n        "E2E_TUTORIAL_LANGUAGE",\n        "E2E_TUTORIAL_PREPARED",\n        "E2E_TUTORIAL_FULL_CONTENT",\n        "E2E_TUTORIAL_PHOTO_NAME",')
 source=replace_once(source,'HARNESS_DERIVED_DATA="$CACHE_DIR/harness-derived-data"', 'HARNESS_DERIVED_DATA="'+str((ART/'fresh-harness').resolve())+'"')
 source=replace_once(source,'testCrossAppPairingFlow source-new-flow','testTutorialSourceFlow source-tutorial')
 if os.environ.get('TUTORIAL_USE_INSTALLED') == '1':
  assert os.environ.get('TUTORIAL_KEEP_SOURCE') == '1' and os.environ.get('TUTORIAL_KEEP_REPLICA') == '1'
  start=source.index('sign_simulator_app "$SYNC_APP_PATH"')
  end=source.index('# Resolve containers without booting a retained source simulator.',start)
  source=source[:start]+'echo "Reusing the identical installed tutorial app builds"\n\n'+source[end:]
 
 needle='run_ui_test "$REPLICA_SIMULATOR_ID" testRecoverVelockAccountFromCardPhoto replica-recover-account\nverify_recovered_identity\nexport E2E_REQUIRE_RECOVERED_ACCOUNT=1\nrun_ui_test "$REPLICA_SIMULATOR_ID" testCrossAppPairingFlow replica-repair-and-sync'
 replacement='unset E2E_SEED_DATA\nexport E2E_REQUIRE_RECOVERED_ACCOUNT=1\nrun_ui_test "$REPLICA_SIMULATOR_ID" testTutorialReplicaFlow replica-tutorial\nverify_recovered_identity'
 assert needle in source
 source=replace_once(source,needle,replacement)
 old_branch='  run_ui_test "$REPLICA_SIMULATOR_ID" testRecoverVelockAccountFromCardPhoto replica-recover-account\n  verify_recovered_identity\n  export E2E_REQUIRE_RECOVERED_ACCOUNT=1\n  run_ui_test "$REPLICA_SIMULATOR_ID" testCrossAppPairingFlow replica-repair-and-sync'
 new_branch='  unset E2E_SEED_DATA\n  export E2E_REQUIRE_RECOVERED_ACCOUNT=1\n  run_ui_test "$REPLICA_SIMULATOR_ID" testTutorialReplicaFlow replica-tutorial\n  verify_recovered_identity'
 assert old_branch in source
 source=replace_once(source,old_branch,new_branch)
 
 # Freeze the verified COMPLETE source backup before a replacement device
 # publishes any join requests. Retakes clone this pristine backup, never
 # reset source history or filter business artifacts from a live remote.
 source=replace_once(source, '\nimport_recovery_card "$CARD_IMAGE"\n',
     '\ncp -cR "$WEBDAV_ROOT" "$E2E_TUTORIAL_DIR/pristine-remote"\n'
     'cp "$CARD_IMAGE" "$E2E_TUTORIAL_DIR/pristine-recovery-card.png"\n'
     'import_recovery_card "$CARD_IMAGE"\n')

 # Keep the loopback-only, disposable demo server inaccessible to the LAN.
 source=replace_once(source,'--host 0.0.0.0','--host 127.0.0.1')
 if LANG == 'en' and os.environ.get('TUTORIAL_PREPARED') != '1':
  language_setup = r'''for simulator_id in "$SOURCE_SIMULATOR_ID" "$REPLICA_SIMULATOR_ID"; do
   xcrun simctl spawn "$simulator_id" defaults write NSGlobalDomain AppleLanguages -array en
   xcrun simctl spawn "$simulator_id" defaults write NSGlobalDomain AppleLocale en_US
   xcrun simctl shutdown "$simulator_id"
   "$XCODEBUILDMCP_BIN" simulator boot --simulator-id "$simulator_id"
 done
 '''
  source = replace_once(source,'finish_stage sign-and-install', language_setup + 'finish_stage sign-and-install')
 if os.environ.get('TUTORIAL_WAIT_FOR'):
  import shlex
  barrier=shlex.quote(os.environ['TUTORIAL_WAIT_FOR'])
  source=replace_once(source,'echo "Running the new source-to-replacement recovery flow..."',
      f'while [[ ! -f {barrier} ]]; do sleep 1; done\necho "Running the new source-to-replacement recovery flow..."')
 (ART/'runner-snapshot.sh').write_text(source)
 t=threading.Thread(target=recorder,daemon=True);t.start()
 start=time.monotonic(); code=1; p=None
 try:
  with (ART/'tutorial-run.log').open('w') as log:
   p=subprocess.Popen(['bash','-c',source,str(runner)],cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
   try: code=p.wait(timeout=1100)
   except subprocess.TimeoutExpired:
    os.killpg(p.pid,signal.SIGTERM)
    try: code=p.wait(timeout=45)
    except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); code=p.wait()
 finally:
  if p is not None and p.poll() is None:
   os.killpg(p.pid,signal.SIGTERM)
   try: p.wait(timeout=30)
   except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); p.wait()
  done.set();t.join(timeout=70)
  if os.environ.get('TUTORIAL_SIGNAL_DONE'): pathlib.Path(os.environ['TUTORIAL_SIGNAL_DONE']).touch()
 names=['02-new-device-recovery'] if config.get('replica_only') else ['01-first-setup','02-new-device-recovery']
 for name in names:
  if not (ART/('stopped-'+name)).exists() or not (ART/(name+'.mp4')).is_file(): error.append('Incomplete recording: '+name)
 try: verify_ui_evidence(ART,config.get('replica_only',False))
 except (ValueError,OSError) as exc: error.append('UI coverage incomplete: '+str(exc))
 print('TUTORIAL_FINISHED',{'exit':code,'seconds':round(time.monotonic()-start),'recorder_errors':error},flush=True)
 print('Private diagnostic log:', ART/'tutorial-run.log', flush=True)
 sys.exit(code or bool(error))

def check_adapter():
 source=(ROOT/'tool/ios_ui_test/run_cross_app_ui_test.sh').read_text()
 for needle in ['"E2E_SEED_DATA",','HARNESS_DERIVED_DATA="$CACHE_DIR/harness-derived-data"','testCrossAppPairingFlow source-new-flow','--host 0.0.0.0','finish_stage sign-and-install','\nimport_recovery_card "$CARD_IMAGE"\n']:
  replace_once(source,needle,needle)
 for indent in ('','  '):
  needle=indent+'run_ui_test "$REPLICA_SIMULATOR_ID" testRecoverVelockAccountFromCardPhoto replica-recover-account\n'+indent+'verify_recovered_identity\n'+indent+'export E2E_REQUIRE_RECOVERED_ACCOUNT=1\n'+indent+'run_ui_test "$REPLICA_SIMULATOR_ID" testCrossAppPairingFlow replica-repair-and-sync'
  replace_once(source,needle,needle)

if __name__=='__main__':
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--config',required=True,type=pathlib.Path)
 parser.add_argument('--take',required=True,help='New directory name; existing takes are never reused')
 parser.add_argument('--check',action='store_true')
 args=parser.parse_args()
 try:
  config=json.loads(args.config.read_text()); secrets=validate(config); check_adapter(); verify_source(config); verify_recording_history(config)
 except (ValueError,OSError) as exc:
  parser.error('Preflight failed before device changes: '+str(exc))
 if pathlib.Path(args.take).name!=args.take or args.take in ('.','..',''): parser.error('take must be a single directory name')
 BASE=pathlib.Path(config['artifact_root']); ART=BASE/args.take
 if ART.exists(): parser.error('Take already exists; choose a fresh name')
 LANG=config['language']; IDS=config['devices']; CLI=config.get('xcodebuildmcp',shutil.which('xcodebuildmcp'))
 if not CLI: parser.error('xcodebuildmcp not found')
 for key in list(os.environ):
  if key.startswith('TUTORIAL_'): del os.environ[key]
 for key in ('keep_source','keep_replica','prepared','replica_only','use_installed'):
  os.environ['TUTORIAL_'+key.upper()]='1' if config.get(key,False) else '0'
 if args.check:
  print('Configuration, six-kind source persistence and runner adapter OK; no devices or files changed.'); sys.exit(0)
 os.umask(0o077)
 ART.mkdir(parents=True,exist_ok=False)
 run()
