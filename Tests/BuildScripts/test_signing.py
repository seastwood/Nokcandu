"""Hermetic signing-selection/installation guards. Never use real keys or alter trust."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class SigningScriptsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="nok-signing-tests-")
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.bin = self.work / "tools"
        self.bin.mkdir()
        self.kc = self.work / "signing keychain"
        self.pw = self.work / "password file"
        self.kc.touch(); self.pw.write_text("test-fixture-password")
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        NOKCANDU_SIGNING_KEYCHAIN=str(self.kc), NOKCANDU_SIGNING_PASSWORD_FILE=str(self.pw))
        self.env.pop("NOKCANDU_SIGN_IDENTITY", None)
        self.env.pop("NOKCANDU_ALLOW_SIGNING_CHANGE", None)
        self.tool("security", '''case "$1" in
unlock-keychain) [ "${FAKE_MODE:-ok}" != denied ] ;;
find-identity) if [ "${FAKE_MODE:-ok}" != missing ]; then echo '  1) ABCDEF "Nokcandu Signing" (CSSMERR_TP_NOT_TRUSTED)'; fi ;;
esac''')
    def tool(self, name, body):
        file = self.bin / name
        file.write_text("#!/bin/bash\nset -eu\n" + body + "\n"); file.chmod(0o755)
    def select(self):
        result = subprocess.run(["/bin/bash", "-c", 'set -euo pipefail; source scripts/select-signing-identity.sh; nokcandu_select_signing_identity; echo "SELECTED=$SIGN_ID"; printf "%s\\n" "${SIGN_KC[@]+${SIGN_KC[@]}}"'], cwd=ROOT, env=self.env, capture_output=True, text=True)
        self.assertNotIn("test-fixture-password", result.stdout + result.stderr)
        return result
    def test_existing_self_signed_identity_selected_without_trust_mutation(self):
        result = self.select()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SELECTED=ABCDEF", result.stdout)
        self.assertIn(str(self.kc), result.stdout)
    def test_explicit_adhoc_is_build_only_opt_in(self):
        self.env["NOKCANDU_SIGN_IDENTITY"] = "-"
        self.env["FAKE_MODE"] = "denied"
        result = self.select()
        self.assertEqual(result.returncode, 0); self.assertIn("SELECTED=-", result.stdout)
    def test_configured_but_inaccessible_keychain_fails_closed(self):
        self.env["FAKE_MODE"] = "denied"
        result = self.select()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing an ad-hoc fallback", result.stderr)
    def test_missing_identity_fails_closed(self):
        self.env["FAKE_MODE"] = "missing"
        self.assertNotEqual(self.select().returncode, 0)
    def test_missing_password_fails_closed(self):
        self.pw.unlink()
        self.assertNotEqual(self.select().returncode, 0)
    def continuity(self, compatible, adhoc=False, override=False):
        current = self.work / "Current.app"; current.mkdir()
        incoming = self.work / "New.app"; incoming.mkdir()
        self.tool("codesign", '''case "$*" in
*--verbose=2*) echo "Signature=${FAKE_SIGNATURE:-certificate}" >&2 ;;
*--display*) echo 'designated => identifier "example" and certificate leaf = H"abcdef"' >&2 ;;
*--verify*) [ "${FAKE_COMPATIBLE:-0}" = 1 ] ;;
esac''')
        self.env["FAKE_COMPATIBLE"] = str(int(compatible))
        self.env["FAKE_SIGNATURE"] = "adhoc" if adhoc else "certificate"
        if override: self.env["NOKCANDU_ALLOW_SIGNING_CHANGE"] = "1"
        return subprocess.run(["/bin/bash", "scripts/check-signing-continuity.sh", str(current), str(incoming)], cwd=ROOT, env=self.env, capture_output=True, text=True)
    def test_installs_require_existing_certificate_identity(self):
        self.assertEqual(self.continuity(True).returncode, 0)
    def test_incompatible_install_refused(self):
        self.assertNotEqual(self.continuity(False).returncode, 0)
    def test_adhoc_to_stable_migration_permitted(self):
        self.assertEqual(self.continuity(False, adhoc=True).returncode, 0)
    def test_deliberate_transition_requires_explicit_override(self):
        self.assertEqual(self.continuity(False, override=True).returncode, 0)

if __name__ == "__main__": unittest.main()
