"""Which controller is which player in Windows games (Resources/rawmouse/padmap.m), run as Wine's controller driver
with a fake SDL holding a Switch Pro Controller and a Steam Controller: the presentation a profile asks for (also a
profile used everywhere), Auto order with the Steam Controller a profile reads first, players set in Nokcandu's
Controllers panel, and the players report Nokcandu reads back."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

SDL = r'''#include <stdint.h>
#include <string.h>
typedef struct { int32_t inst; uint16_t vid, pid; const char *serial, *path; } J;
static J js[2] = { { 3, 0x057e, 0x2009, "", "DevSrvsID:111" }, { 7, 0x28de, 0x1142, 0, "DevSrvsID:222" } };
int SDL_WaitEventTimeout(void *ev, int t) { (void)ev; (void)t; return 0; }
int SDL_NumJoysticks(void) { return 2; }
int32_t SDL_JoystickGetDeviceInstanceID(int i) { return js[i].inst; }
uint16_t SDL_JoystickGetDeviceVendor(int i) { return js[i].vid; }
uint16_t SDL_JoystickGetDeviceProduct(int i) { return js[i].pid; }
void *SDL_GameControllerOpen(int i) { return &js[i]; }
void *SDL_GameControllerGetJoystick(void *c) { return c; }
int32_t SDL_JoystickInstanceID(void *j) { return ((J *)j)->inst; }
uint16_t SDL_JoystickGetVendor(void *j) { return ((J *)j)->vid; }
uint16_t SDL_JoystickGetProduct(void *j) { return ((J *)j)->pid; }
const char *SDL_JoystickGetSerial(void *j) { return ((J *)j)->serial; }
const char *SDL_JoystickPath(void *j) { return ((J *)j)->path; }
int SDL_JoystickGetType(void *j) { (void)j; return 1; }
void *fixture_joystick(int i) { return &js[i]; }
'''

DRIVER = r'''#include <dlfcn.h>
__attribute__((noinline)) void *lookup(void *h,const char *n) { void *p=dlsym(h,n); __asm__ volatile("" : "+r"(p)); return p; }
'''

MAIN = r'''#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
 (void)argc; const char *state = argv[2], *map = argv[3];
 char p[1024]; snprintf(p, sizeof p, "%s/pad-active", state);
 FILE *f = fopen(p, "w"); fprintf(f, "%d\n%s\n", getpid(), map); fclose(f);
 void *sdl = dlopen("./libSDL-fixture.dylib", RTLD_NOW|RTLD_LOCAL), *bus = dlopen("./winebus.so", RTLD_NOW|RTLD_LOCAL);
 if (!sdl || !bus) return 1;
 void *(*lookup)(void *, const char *) = (void *(*)(void *, const char *))dlsym(bus, "lookup");
 int (*wait)(void *, int) = (int (*)(void *, int))lookup(sdl, "SDL_WaitEventTimeout");
 uint16_t (*vendor)(void *) = (uint16_t (*)(void *))lookup(sdl, "SDL_JoystickGetVendor");
 void *(*joystick)(int) = (void *(*)(int))dlsym(sdl, "fixture_joystick");
 unsigned char ev[56]; memset(ev, 0, 56); wait(ev, 1);          /* reads the profile */
 /* Wine asks about the Pro first, as it found it first. */
 uint16_t pro = vendor(joystick(0)), steam = vendor(joystick(1));
 printf("pro %04x steam %04x\n", pro, steam);
 return 0;
}
'''


class PadPlayersTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="nokp-", dir="/tmp")
        cls.work = Path(cls.tmp.name)

        def build(args):
            subprocess.run(["xcrun", "clang", *args], cwd=ROOT, check=True, capture_output=True, text=True)
        cls.helper = cls.work / "nokcandu-rawmouse.dylib"
        build(["-dynamiclib", "-fobjc-arc", "-O2", "-mmacosx-version-min=11.0",
               "-framework", "AppKit", "-framework", "GameController", "-framework", "CoreGraphics",
               "-framework", "IOKit", "-framework", "OpenGL", "-framework", "AudioToolbox",
               "-framework", "CoreAudio", "-ISources/NokcanduPadEngine/include",
               *["Resources/rawmouse/" + s for s in ["rawmouse.m", "audiofollow.m", "bonjourbridge.m",
                 "micguard.m", "socket-events.c", "helper-state.c", "commit-memory.c"]],
               "Sources/NokcanduPadEngine/padengine.c", "-o", str(cls.helper)])
        for name, text, out in [("sdl.c", SDL, "libSDL-fixture.dylib"), ("driver.c", DRIVER, "winebus.so")]:
            (cls.work / name).write_text(text)
            build(["-dynamiclib", "-O2", str(cls.work / name), "-o", str(cls.work / out)])
        (cls.work / "main.c").write_text(MAIN)
        build(["-O2", str(cls.work / "main.c"), "-o", str(cls.work / "probe")])

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_driver(self, name, map_text, players=None, everywhere=False):
        case = self.work / name
        state, home = case / "state", case / "home"
        support = home / "Library/Application Support/Nokcandu"
        state.mkdir(parents=True); support.mkdir(parents=True)
        os.link(self.helper, state / "nokcandu-rawmouse.dylib")
        if everywhere:
            (support / "controller-profiles-everywhere").write_text("p\n")
            (support / "controller-profiles-everywhere.map").write_text(map_text)
            active = support / "controller-profiles-everywhere.map"
        else:
            (state / "pad-map").write_text(map_text)
            active = state / "pad-map"
        if players is not None:
            (support / "controller-players").write_text(players)
        env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(state / "nokcandu-rawmouse.dylib"), NOKCANDU_NO_GAME_APP="1", HOME=str(home))
        r = subprocess.run([str(self.work / "probe"), "winedevice.exe", str(state), str(active)], cwd=self.work, env=env,
                           capture_output=True, text=True, timeout=20)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        seen = state / "pad-players-seen"
        return r.stdout.strip(), (seen.read_text() if seen.exists() else ""), r.stderr

    STEAM_PROFILE = "nokpad 1\npresent xbox\nsource steam\nplayer 2 asis\nplayer 3 asis\n"
    BOTH_AUTO = ("nokplayers 1\nc 111 1406 8201 - 0 0 057e:2009:n:0\n"
                 "c 222 10462 4418 - 0 0 28de:1142:n:0\n")

    def test_a_profile_used_everywhere_presents_the_steam_controller_it_reads_as_player_one(self):
        out, seen, err = self.run_driver("everywhere", self.STEAM_PROFILE, self.BOTH_AUTO, everywhere=True)
        self.assertEqual(out, "pro 057e steam 045e", err)
        self.assertIn("presented as Xbox Wireless Controller", err)
        lines = set(seen.split("\n")[1:]) - {""}
        self.assertEqual(lines, {"28de:1142:n:0 1", "057e:2009:n:0 2"}, seen)

    def test_a_controller_set_to_player_one_in_nokcandu_is_player_one(self):
        players = ("nokplayers 1\nc 111 1406 8201 - 0 1 057e:2009:n:0\n"
                   "c 222 10462 4418 - 0 0 28de:1142:n:0\n")
        profile = "nokpad 1\npresent xbox\nplayer 2 asis\n"
        out, seen, err = self.run_driver("seat", profile, players)
        self.assertEqual(out, "pro 045e steam 28de", err)
        lines = set(seen.split("\n")[1:]) - {""}
        self.assertEqual(lines, {"057e:2009:n:0 1", "28de:1142:n:0 2"}, seen)

    def test_players_given_the_same_profile_are_presented_too(self):
        profile = "nokpad 1\npresent xbox\nplayer 2 same\n"
        out, _, err = self.run_driver("same", profile, None)
        self.assertEqual(out, "pro 045e steam 045e", err)

    def test_without_nokcandus_players_the_order_wine_found_them_in(self):
        out, seen, err = self.run_driver("order", "nokpad 1\npresent xbox\nplayer 2 asis\n", None)
        self.assertEqual(out, "pro 045e steam 28de", err)
        self.assertTrue(seen.startswith("pid "), seen)

    def test_a_map_without_player_lines_presents_everyone(self):
        out, _, err = self.run_driver("old", "nokpad 1\npresent xbox\n", None)
        self.assertEqual(out, "pro 045e steam 045e", err)


if __name__ == "__main__":
    unittest.main()
