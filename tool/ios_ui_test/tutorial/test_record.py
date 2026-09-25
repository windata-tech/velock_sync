"""Offline safety tests: never start simulators."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
spec=importlib.util.spec_from_file_location('rec',Path(__file__).with_name('record.py'))
rec=importlib.util.module_from_spec(spec); spec.loader.exec_module(rec)
class RecorderTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
  p=Path(self.tmp.name);app=p/'Runner.app';app.mkdir();(app/'Info.plist').touch()
  secret=p/'secrets.json';secret.write_text(json.dumps(dict(VELOCK_RUNTIME_PASSWORD='dummy-only',E2E_RECOVERY_PASSPHRASE='dummy-only')));secret.chmod(0o600)
  self.c=dict(language='zh',artifact_root=str(p/'out'),devices=dict(source='a',replica='b'),disposable_devices=['a','b'],sync_app=str(app),velock_app=str(app),velock_root=str(p),secrets_file=str(secret),port=18994,prepared=True,keep_source=True)
 def test_valid(self): self.assertEqual(len(rec.validate(self.c)),2)
 def test_adapter(self): rec.check_adapter()
 def test_anchors(self):
  for s in ('none','xx'):
   with self.assertRaises(ValueError): rec.replace_once(s,'x','y')
 def test_unsafe_configs(self):
  for update in [dict(language='fr'),dict(disposable_devices=['a']),dict(devices=dict(source='a',replica='a')),dict(artifact_root=str(rec.ROOT/'generated')),dict(replica_only=True),dict(prepared=False),dict(use_installed=True),dict(port=80),dict(required_kinds=['password']),dict(keep_source=False)]:
   with self.subTest(update=update),self.assertRaises(ValueError):rec.validate(dict(self.c,**update))
 def test_public_secret(self):
  Path(self.c['secrets_file']).chmod(0o644)
  with self.assertRaises(ValueError):rec.validate(self.c)
 def test_extra_secret_env(self):
  Path(self.c['secrets_file']).write_text('{"E2E_ALLOW_ERASE":"1"}')
  with self.assertRaises(ValueError):rec.validate(self.c)
if __name__=='__main__':unittest.main()
