"""Windows programs' page file (Resources/rawmouse/commit-memory.c): Wine's vm.swapusage answer shows swap that can
grow, as macOS's does, so commit checks (Trackmania's "free up at least 5.0 GB") see the room macOS has."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GB = 1 << 30


class CommitMemoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="nok-commit-")
        work = Path(cls.tmp.name)
        model = work / "model.c"
        model.write_text('''#include <stdio.h>
#include <stdlib.h>
#include "commit-memory.h"
int main(int c, char **v) { unsigned long long t, a;
  nok_pagefile_model(strtoull(v[1],0,10), strtoull(v[2],0,10), strtoull(v[3],0,10), strtoull(v[4],0,10), &t, &a);
  printf("%llu %llu\\n", t, a); return 0; }''')
        cls.model = work / "model"
        subprocess.run(["xcrun", "clang", "-IResources/rawmouse", str(model), "-o", str(cls.model)], cwd=ROOT, check=True)
        cls.helper = work / "commit.dylib"
        subprocess.run(["xcrun", "clang", "-dynamiclib", "Resources/rawmouse/commit-memory.c", "-o", str(cls.helper)], cwd=ROOT, check=True)
        probe = work / "probe.c"
        probe.write_text('''#include <stdio.h>
#include <sys/sysctl.h>
int main(void) { struct xsw_usage s; size_t n = sizeof s; int mib[2] = { CTL_VM, VM_SWAPUSAGE };
  if (sysctl(mib, 2, &s, &n, NULL, 0)) return 1; printf("%llu %llu %llu\\n", s.xsu_total, s.xsu_used, s.xsu_avail); return 0; }''')
        cls.probe = work / "probe"
        subprocess.run(["xcrun", "clang", str(probe), "-o", str(cls.probe)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def model_of(self, total, used, ram, disk):
        out = subprocess.run([str(self.model), str(total), str(used), str(ram), str(disk)], check=True, capture_output=True, text=True).stdout
        return tuple(int(x) for x in out.split())

    def test_the_reported_mac(self):
        # November 13, 2026: 16 GB, 4 GB swap with 0.7 GB free; Trackmania saw about 4 GB of commit.
        total, avail = self.model_of(4 * GB, int(3.3 * GB), 16 * GB, 200 * GB)
        self.assertEqual(total, 16 * GB)
        self.assertGreater(avail, 12 * GB)

    def test_never_grows_into_the_last_10_gb_of_disk(self):
        total, avail = self.model_of(2 * GB, 1 * GB, 16 * GB, 13 * GB)
        self.assertEqual(total, 4 * GB)
        self.assertEqual(avail, 3 * GB)

    def test_never_less_than_macos_reports(self):
        self.assertEqual(self.model_of(20 * GB, 5 * GB, 16 * GB, 5 * GB), (20 * GB, 15 * GB))
        self.assertEqual(self.model_of(0, 0, 8 * GB, 0), (0, 0))

    def run_probe(self, **env):
        e = dict(os.environ, DYLD_INSERT_LIBRARIES=str(self.helper), **env)
        return tuple(int(x) for x in subprocess.run([str(self.probe)], env=e, check=True, capture_output=True, text=True).stdout.split())

    def test_the_helper_answers_the_sysctl_wine_asks(self):
        plain = tuple(int(x) for x in subprocess.run([str(self.probe)], check=True, capture_output=True, text=True).stdout.split())
        total, used, avail = self.run_probe()
        self.assertEqual(used, plain[1])
        self.assertGreaterEqual(total, plain[0])
        self.assertEqual(avail, total - used)
        self.assertEqual(self.run_probe(NOKCANDU_MACOS_SWAP="1"), plain, "the opt-out passes macOS's figures through")


if __name__ == "__main__":
    unittest.main()
