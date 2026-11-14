"""A profile that reads the controller itself feeds Wine's driver (Resources/rawmouse/padmap.m, "Fed by Nokcandu"):
the game gets the profile's controller, and the raw controller's own input is dropped."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class PadFeedTests(unittest.TestCase):
    def test_the_game_gets_the_fed_controller_and_not_the_raw_one(self):
        with tempfile.TemporaryDirectory(prefix="nokf-", dir="/tmp") as tmp:
            work = Path(tmp)
            state = work / "state"; state.mkdir()
            def build_fixture(args):
                subprocess.run(["xcrun", "clang", *args], cwd=ROOT, check=True, capture_output=True, text=True)
            helper = state / "nokcandu-rawmouse.dylib"
            build_fixture(["-dynamiclib", "-fobjc-arc", "-O2", "-mmacosx-version-min=11.0",
                     "-framework", "AppKit", "-framework", "GameController", "-framework", "CoreGraphics",
                     "-framework", "IOKit", "-framework", "OpenGL", "-framework", "AudioToolbox",
                     "-framework", "CoreAudio", "-ISources/NokcanduPadEngine/include",
                     *["Resources/rawmouse/" + s for s in ["rawmouse.m", "audiofollow.m", "bonjourbridge.m",
                       "micguard.m", "socket-events.c", "helper-state.c", "commit-memory.c"]],
                     "Sources/NokcanduPadEngine/padengine.c", "-o", str(helper)])
            (work / "sdl.c").write_text('''#include <stdint.h>
#include <string.h>
typedef struct { uint32_t type, timestamp; int32_t which; uint8_t button, state, p1, p2; } cb;
static int raw_sent;
int SDL_WaitEventTimeout(void *ev, int t) { (void)t; if (raw_sent < 3) { raw_sent++; cb e = { 0x651, 0, 7, 0, 1 }; memset(ev, 0, 56); memcpy(ev, &e, sizeof e); return 1; } return 0; }
int SDL_NumJoysticks(void) { return 1; }
int32_t SDL_JoystickGetDeviceInstanceID(int i) { (void)i; return 7; }
uint16_t SDL_JoystickGetDeviceVendor(int i) { (void)i; return 0x28de; }
uint16_t SDL_JoystickGetDeviceProduct(int i) { (void)i; return 0x1102; }
void *SDL_GameControllerOpen(int i) { (void)i; return 0; }
''')
            build_fixture(["-dynamiclib", "-O2", str(work / "sdl.c"), "-o", str(work / "libSDL-fixture.dylib")])
            (work / "driver.c").write_text('''#include <dlfcn.h>
__attribute__((noinline)) void *lookup(void *h,const char *n) { void *p=dlsym(h,n); __asm__ volatile("" : "+r"(p)); return p; }
''')
            build_fixture(["-dynamiclib", "-O2", str(work / "driver.c"), "-o", str(work / "winebus.so")])
            (work / "main.c").write_text('''#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
typedef struct { uint32_t type, timestamp; int32_t which; uint8_t button, state, p1, p2; } cb;
int main(int argc, char **argv) {
 (void)argc; const char *state = argv[2];
 char p[1024]; snprintf(p, sizeof p, "%s/map", state);
 FILE *f = fopen(p, "w"); fputs("nokpad 1\\npresent xbox\\nsource steam\\n", f); fclose(f);
 snprintf(p, sizeof p, "%s/pad-active", state); f = fopen(p, "w"); fprintf(f, "%d\\n%s/map\\n", getpid(), state); fclose(f);
 void *sdl = dlopen("./libSDL-fixture.dylib", RTLD_NOW|RTLD_LOCAL), *bus = dlopen("./winebus.so", RTLD_NOW|RTLD_LOCAL);
 if (!sdl || !bus) return 1;
 void *(*lookup)(void *, const char *) = (void *(*)(void *, const char *))dlsym(bus, "lookup");
 int (*wait)(void *, int) = (int (*)(void *, int))lookup(sdl, "SDL_WaitEventTimeout");
 unsigned char ev[56]; int raw = 0, fed = 0;
 for (int i = 0; i < 3; i++) { memset(ev, 0, 56); if (wait(ev, 1)) { cb e; memcpy(&e, ev, sizeof e); if (e.type == 0x651 && e.button == 0) raw++; } }
 snprintf(p, sizeof p, "%s/pad-feed", state); f = fopen(p, "r"); if (!f) return 3;
 char sock[200] = ""; if (!fgets(sock, sizeof sock, f)) return 4; fclose(f); sock[strcspn(sock, "\\n")] = 0;
 int s = socket(AF_UNIX, SOCK_DGRAM, 0); struct sockaddr_un a = { .sun_family = AF_UNIX }; strlcpy(a.sun_path, sock, sizeof a.sun_path);
 uint8_t msg[4] = { 1, 1, 1, 0 };   /* button 1 (B) down */
 if (sendto(s, msg, 4, 0, (struct sockaddr *)&a, sizeof a) != 4) return 5;
 for (int i = 0; i < 5 && !fed; i++) { memset(ev, 0, 56); if (wait(ev, 1)) { cb e; memcpy(&e, ev, sizeof e); if (e.type == 0x651 && e.which == 7 && e.button == 1) fed = 1; if (e.type == 0x651 && e.button == 0) raw++; } }
 printf("raw %d fed %d\\n", raw, fed); return 0;
}
''')
            exe = work / "probe"
            build_fixture(["-O2", str(work / "main.c"), "-o", str(exe)])
            env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(helper), NOKCANDU_NO_GAME_APP="1")
            r = subprocess.run([str(exe), "winedevice.exe", str(state)], cwd=work, env=env, capture_output=True, text=True, timeout=20)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertEqual(r.stdout.strip(), "raw 0 fed 1", r.stderr)
            self.assertIn("controller fed by Nokcandu", r.stderr)


if __name__ == "__main__":
    unittest.main()
