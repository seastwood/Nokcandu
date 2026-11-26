"""The Developer ID entitlements: microphone always, the virtual-controller entitlement only as a matching profile grants it."""
import datetime, importlib.util, plistlib, subprocess, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("entitlements", ROOT / "Tools/signing/entitlements.py")
ent = importlib.util.module_from_spec(spec); spec.loader.exec_module(ent)
BUNDLE = "io.github.seastwood.nokcandu"

def profile(app_id="TEAM123456." + BUNDLE, virtual=True, expires=datetime.datetime(2099, 1, 1), all_devices=True):
    e = {"com.apple.application-identifier": app_id, "com.apple.developer.team-identifier": "TEAM123456"}
    if virtual: e[ent.VIRTUAL] = True
    p = {"Entitlements": e, "TeamIdentifier": ["TEAM123456"], "ExpirationDate": expires}
    if all_devices: p["ProvisionsAllDevices"] = True
    return p

class EntitlementsTests(unittest.TestCase):
    def test_without_profile_only_the_microphone(self):
        e, _ = ent.entitlements(None, BUNDLE)
        self.assertEqual(e, {"com.apple.security.device.audio-input": True})
    def test_granting_profile_adds_app_id_team_and_virtual_device(self):
        e, _ = ent.entitlements(profile(), BUNDLE)
        self.assertEqual(e["com.apple.application-identifier"], "TEAM123456." + BUNDLE)
        self.assertEqual(e["com.apple.developer.team-identifier"], "TEAM123456")
        self.assertTrue(e[ent.VIRTUAL]); self.assertTrue(e["com.apple.security.device.audio-input"])
    def test_refusals(self):
        for bad in [profile(virtual=False), profile(app_id="TEAM123456.other.app"), profile(expires=datetime.datetime(2001, 1, 1)),
                    profile(all_devices=False)]:
            with self.assertRaises(SystemExit): ent.entitlements(bad, BUNDLE)
    def test_script_writes_a_plist(self):
        with tempfile.TemporaryDirectory() as d:
            src, out = Path(d) / "p.plist", Path(d) / "e.plist"
            src.write_bytes(plistlib.dumps(profile()))
            subprocess.run([sys.executable, str(ROOT / "Tools/signing/entitlements.py"), str(out), str(src), BUNDLE], check=True, capture_output=True)
            self.assertTrue(plistlib.loads(out.read_bytes())[ent.VIRTUAL])
            subprocess.run([sys.executable, str(ROOT / "Tools/signing/entitlements.py"), str(out), "", BUNDLE], check=True)
            self.assertNotIn(ent.VIRTUAL, plistlib.loads(out.read_bytes()))

if __name__ == "__main__": unittest.main()
