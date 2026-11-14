"""Rumble for controllers SDL can't rumble: the Wine helper reports rumble as supported to Wine's controller driver
and, when SDL fails, sends the request to Nokcandu's socket (Resources/rawmouse/padmap.m)."""
import os
import socket
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class ControllerRumbleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="nokr-", dir="/tmp")   # short: socket paths are limited
        work = Path(cls.tmp.name)
        def build_fixture(args):
            subprocess.run(["xcrun", "clang", *args], cwd=ROOT, check=True, capture_output=True, text=True)
        cls.helper = work / "helper.dylib"
        build_fixture(["-dynamiclib", "-fobjc-arc", "-O2", "-mmacosx-version-min=11.0",
                 "-framework", "AppKit", "-framework", "GameController", "-framework", "CoreGraphics",
                 "-framework", "IOKit", "-framework", "OpenGL", "-framework", "AudioToolbox",
                 "-framework", "CoreAudio", "-ISources/NokcanduPadEngine/include",
                 *["Resources/rawmouse/" + s for s in ["rawmouse.m", "audiofollow.m", "bonjourbridge.m",
                   "micguard.m", "socket-events.c", "helper-state.c", "commit-memory.c"]],
                 "Sources/NokcanduPadEngine/padengine.c", "-o", str(cls.helper)])
        sdl = work / "sdl.c"
        sdl.write_text('''#include <stdint.h>
#include <stdlib.h>
int SDL_JoystickRumble(void *j, uint16_t lo, uint16_t hi, uint32_t ms) { (void)j;(void)lo;(void)hi;(void)ms; return getenv("SDL_CAN_RUMBLE") ? 0 : -1; }
uint16_t SDL_JoystickGetVendor(void *j) { (void)j; return 0x28de; }
uint16_t SDL_JoystickGetProduct(void *j) { (void)j; return 0x1102; }
const char *SDL_JoystickName(void *j) { (void)j; return "Steam Controller"; }
''')
        build_fixture(["-dynamiclib", "-O2", str(sdl), "-o", str(work / "libSDL-fixture.dylib")])
        driver = work / "driver.c"
        driver.write_text('''#include <dlfcn.h>
__attribute__((noinline)) void *lookup(void *h,const char *n) { void *p=dlsym(h,n); __asm__ volatile("" : "+r"(p)); return p; }
''')
        build_fixture(["-dynamiclib", "-O2", str(driver), "-o", str(work / "winebus.so")])
        main = work / "main.c"
        main.write_text('''#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
typedef void *(*lookup_t)(void *,const char *);
int main(void) {
 void *sdl=dlopen("./libSDL-fixture.dylib",RTLD_NOW|RTLD_LOCAL), *bus=dlopen("./winebus.so",RTLD_NOW|RTLD_LOCAL);
 if(!sdl||!bus)return 1;
 int (*rumble)(void *,uint16_t,uint16_t,uint32_t)=(int(*)(void *,uint16_t,uint16_t,uint32_t))((lookup_t)dlsym(bus,"lookup"))(sdl,"SDL_JoystickRumble");
 if(!rumble)return 2;
 if(rumble((void *)1,0,0,0)!=0)return 3;              /* Wine's probe: must succeed */
 printf("%d\\n", rumble((void *)1,0x8000,0x4000,250)); return 0;
}
''')
        cls.exe = work / "probe"
        build_fixture(["-O2", str(main), "-o", str(cls.exe)])
        cls.home = work / "home"
        (cls.home / "Library/Application Support/Nokcandu").mkdir(parents=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_probe(self, **env):
        path = str(self.home / "Library/Application Support/Nokcandu/controller-rumble.sock")
        if os.path.exists(path):
            os.unlink(path)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        s.bind(path)
        s.settimeout(0.5)
        try:
            e = dict(os.environ, DYLD_INSERT_LIBRARIES=str(self.helper), NOKCANDU_NO_GAME_APP="1", HOME=str(self.home), **env)
            r = subprocess.run([str(self.exe)], cwd=self.exe.parent, env=e, capture_output=True, text=True, timeout=10)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertEqual(r.stdout.strip(), "0", "rumble reported as played")
            got = []
            try:
                while True:
                    got.append(s.recv(256).decode())
            except socket.timeout:
                pass
            return got
        finally:
            s.close()

    def test_rumble_sdl_cannot_play_goes_to_nokcandu(self):
        got = self.run_probe()
        self.assertEqual(got, ["nokcandu-rumble 1 28de 1102 0 0 0 Steam Controller",
                               "nokcandu-rumble 1 28de 1102 32768 16384 250 Steam Controller"])

    def test_rumble_sdl_plays_stays_with_sdl(self):
        self.assertEqual(self.run_probe(SDL_CAN_RUMBLE="1"), [])


if __name__ == "__main__":
    unittest.main()
