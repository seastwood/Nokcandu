"""The emulated Switch Pro Controller and DualShock 4 in Nokcandu's Wine controller driver (its glue plus the shared
virtual-controller core), driven like SDL's HIDAPI Switch and PS4 drivers."""
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HID = os.path.join(ROOT, "Engine", "controller-hid")
CORE = [os.path.join(ROOT, "Sources", "NokcanduPadEngine"), os.path.join(ROOT, "Sources", "NokcanduPadEngine", "include")]


def sdl_cflags():
    for d in ["/opt/homebrew/include/SDL2", "/usr/local/include/SDL2"]:
        if os.path.exists(os.path.join(d, "SDL.h")):
            return ["-I" + d]
    return None


def unpack(b, offset):
    x = b[offset] | ((b[offset + 1] & 0x0F) << 8)
    y = (b[offset + 1] >> 4) | (b[offset + 2] << 4)
    return x, y


@unittest.skipIf(sdl_cflags() is None or shutil.which("clang") is None, "needs SDL2 headers and clang")
class SwitchProEmulationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        exe = os.path.join(cls.dir, "harness")
        subprocess.run(["clang", "-std=gnu11", "-w", "-I" + HID, *["-I" + c for c in CORE], *sdl_cflags(), os.path.join(ROOT, "Tests", "BuildScripts", "switch-pro", "harness.c"), "-o", exe], check=True)
        cls.lines = subprocess.run([exe], check=True, capture_output=True, text=True).stdout.split("\n")
        cls.reports = [bytes.fromhex(l) for l in cls.lines if l and all(c in "0123456789abcdef" for c in l)]

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir, ignore_errors=True)

    def reply(self, report_id, second):
        return [r for r in self.reports if r[0] == report_id and r[1 if report_id == 0x81 else 14] == second]

    def test_device_identity_and_descriptor(self):
        self.assertIn("desc 057e:2009 gamepad=0 hidraw=0", self.lines)
        self.assertIn("descriptor 185", self.lines)
        for r in self.reports:
            self.assertEqual(len(r), 64, "every Pro report is 64 bytes on USB")

    def test_usb_handshake(self):
        status = self.reply(0x81, 0x01)
        self.assertEqual(len(status), 1)
        self.assertEqual(status[0][3], 0x03, "controller type: Pro")
        self.assertEqual(len(self.reply(0x81, 0x02)), 1)
        self.assertEqual(len(self.reply(0x81, 0x03)), 1)
        self.assertEqual(len(self.reply(0x81, 0x04)), 0, "USB-only mode has no reply")

    def test_device_info(self):
        info = self.reply(0x21, 0x02)
        self.assertEqual(len(info), 1)
        self.assertEqual(info[0][13], 0x82)
        self.assertEqual(info[0][17], 0x03, "Pro Controller type in the device info")

    def test_stick_calibration_reads_back_centred(self):
        spi = self.reply(0x21, 0x10)
        sticks = [r for r in spi if r[15:20] == bytes([0x3d, 0x60, 0x00, 0x00, 0x12])][0]
        self.assertEqual(sticks[13], 0x90)
        data = sticks[20:20 + 18]
        self.assertEqual(unpack(data, 3), (2048, 2048), "left stick centre")
        self.assertEqual(unpack(data, 0), (1792, 1792), "left range above centre")
        self.assertEqual(unpack(data, 9), (2048, 2048), "right stick centre comes first")

    def test_imu_calibration(self):
        imu = [r for r in self.reply(0x21, 0x10) if r[15:17] == bytes([0x20, 0x60])][0][20:44]
        self.assertEqual(imu[6:8], bytes([0x00, 0x40]), "accelerometer sensitivity 0x4000")
        self.assertEqual(imu[18:20], bytes([0x3b, 0x34]), "gyro sensitivity 0x343b")

    def test_subcommands_are_acknowledged(self):
        self.assertEqual(self.reply(0x21, 0x03)[0][13], 0x80)
        self.assertEqual(self.reply(0x21, 0x40)[0][13], 0x80)

    def test_rumble_reaches_the_controller(self):
        line = [l for l in self.lines if l.startswith("rumble")][0]
        low, high = map(int, line.split()[1:])
        self.assertGreater(low, 0)

    def test_buttons_sticks_and_triggers_in_full_reports(self):
        self.assertIn("handled 1", self.lines)
        self.assertIn("other 0", self.lines, "another controller's events are left to Wine")
        full = [r for r in self.reports if r[0] == 0x30]
        last = full[-1]
        self.assertTrue(last[3] & 0x04, "SDL south button is the Pro's B")
        self.assertTrue(last[3] & 0x80, "right trigger past half is ZR")
        self.assertTrue(last[5] & 0x02, "d-pad up")
        x, y = unpack(last, 6)
        self.assertGreater(x, 3800, "left stick pushed right")
        self.assertGreater(y, 3800, "SDL's up (negative) is the Pro's up (high)")
        self.assertEqual(unpack(last, 9), (2048, 2048), "right stick centred")
        self.assertNotEqual(last[13:25], bytes(12), "motion is sent once the IMU is on")


if __name__ == "__main__":
    unittest.main()


@unittest.skipIf(sdl_cflags() is None or shutil.which("clang") is None, "needs SDL2 headers and clang")
class DualShock4EmulationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        exe = os.path.join(cls.dir, "harness")
        subprocess.run(["clang", "-std=gnu11", "-w", "-I" + HID, *["-I" + c for c in CORE], *sdl_cflags(), os.path.join(ROOT, "Tests", "BuildScripts", "switch-pro", "harness.c"), "-o", exe], check=True)
        cls.lines = subprocess.run([exe, "ds4"], check=True, capture_output=True, text=True).stdout.split("\n")
        cls.reports = [bytes.fromhex(l) for l in cls.lines if l and all(c in "0123456789abcdef" for c in l)]
        cls.features = {int(l.split()[1], 16): l.split() for l in cls.lines if l.startswith("feature")}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.dir, ignore_errors=True)

    def test_identity_and_descriptor_size(self):
        self.assertIn("desc 054c:05c4 gamepad=0 hidraw=0", self.lines)
        descriptor = [l for l in self.lines if l.startswith("descriptor")][0]
        self.assertGreater(int(descriptor.split()[1]), 100)
        for r in self.reports:
            self.assertEqual(len(r), 64)
            self.assertEqual(r[0], 0x01)

    def test_feature_reports(self):
        cal = bytes.fromhex(self.features[0x02][6])
        self.assertEqual(len(cal), 37)
        self.assertEqual(int.from_bytes(cal[7:9], "little", signed=True), 8192, "pitch plus")
        self.assertEqual(int.from_bytes(cal[19:21], "little"), 540, "gyro speed")
        mac = bytes.fromhex(self.features[0x12][6])
        self.assertEqual(len(mac), 16)
        self.assertEqual(len(bytes.fromhex(self.features[0xa3][6])), 49)
        self.assertNotEqual(self.features[0x81][3], "0", "unknown features are refused")

    def test_rumble(self):
        line = [l for l in self.lines if l.startswith("rumble")][0]
        low, high = map(int, line.split()[1:])
        self.assertEqual(low, 0xc0 * 257, "left (strong) motor")
        self.assertEqual(high, 0x40 * 257, "right (weak) motor")

    def test_input_report(self):
        self.assertIn("touch handled 1", self.lines)
        last = self.reports[-1]
        self.assertEqual(last[1], 255, "left stick right")
        self.assertEqual(last[5] & 0x0f, 0, "hat up")
        self.assertTrue(last[5] & 0x20, "SDL south is cross")
        self.assertTrue(last[6] & 0x08, "R2 pressed")
        self.assertEqual(last[9], 255, "R2 analog full")
        self.assertEqual(last[33], 1, "one touch packet")
        self.assertFalse(last[35] & 0x80, "finger 0 down")
        x = last[36] | ((last[37] & 0x0f) << 8)
        self.assertAlmostEqual(x, 959, delta=2, msg="touch at the middle")
        self.assertTrue(last[39] & 0x80, "finger 1 up")
        self.assertEqual(int.from_bytes(last[21:23], "little", signed=True), 8192, "1 g on y at rest")
