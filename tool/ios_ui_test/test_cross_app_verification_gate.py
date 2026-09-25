"""Execute the real Bash verification function with isolated counting doubles."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

RUNNER = Path(__file__).with_name('run_cross_app_ui_test.sh')


class VerificationGateTests(unittest.TestCase):
    def run_gate(self, kinds, missing_note=False, verifier_failure=False):
        with tempfile.TemporaryDirectory(prefix='velock-gate-') as directory:
            root = Path(directory)
            (root / 'Documents').mkdir()
            (root / 'Documents/venyoreDb').write_bytes(b'fixture')
            text = RUNNER.read_text()
            function = text.split('verify_replica_business_data() {', 1)[1].split(
                '\nif [[ "${E2E_SYNC_EXISTING_ONLY', 1)[0]
            script = '''set -euo pipefail
app_data_container() { echo "$RESULTS_DIR"; }
selected_sandbox_id() { echo 7; }
sqlite3() {
  if [[ "${MISSING_NOTE:-0}" == 1 && "$2" == *t_note* ]]; then echo 0; else echo 1; fi
}
python3() {
  printf '%s\\n' "$@" >> "$RESULTS_DIR/calls"
  if [[ "${VERIFIER_FAILURE:-0}" == 1 ]]; then return 19; fi
  echo '{}'
}
verify_replica_business_data() {''' + function + '\nverify_replica_business_data\n'
            env = os.environ | dict(ROOT_DIR=str(root), RESULTS_DIR=str(root),
                SOURCE_SIMULATOR_ID='source', REPLICA_SIMULATOR_ID='replica',
                E2E_REQUIRED_KINDS=kinds, E2E_REQUIRE_ALL_DATA='0',
                MISSING_NOTE='1' if missing_note else '0',
                VERIFIER_FAILURE='1' if verifier_failure else '0')
            result = subprocess.run(['bash', '-c', script], env=env,
                                    capture_output=True, text=True, timeout=3)
            calls = (root / 'calls').read_text() if (root / 'calls').exists() else ''
            return result, calls

    def test_subset_requires_persistence_and_convergence(self):
        result, calls = self.run_gate('password,card,note')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('verify_business_persistence.py', calls)
        self.assertIn('--kinds\npassword\ncard\nnote', calls)
        self.assertIn('verify_replica_convergence.py', calls)

    def test_missing_required_kind_fails_before_verifiers(self):
        result, calls = self.run_gate('password,card,note', missing_note=True)
        self.assertEqual(result.returncode, 14)
        self.assertEqual(calls, '')

    def test_verifier_failure_propagates_through_tee(self):
        result, calls = self.run_gate('password,card,note', verifier_failure=True)
        self.assertEqual(result.returncode, 19)
        self.assertNotIn('verify_replica_convergence.py', calls)


if __name__ == '__main__':
    unittest.main()
