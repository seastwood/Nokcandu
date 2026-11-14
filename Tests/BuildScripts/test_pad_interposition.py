"""Exercise the actual helper against fake SDL/driver images; no controller or Wine needed."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class PadInterpositionTests(unittest.TestCase):
    def test_only_wine_driver_lookups_are_intercepted(self):
        with tempfile.TemporaryDirectory(prefix="nok-pad-symbols-") as tmp:
            work = Path(tmp)
            def build_fixture(args):
                subprocess.run(["xcrun", "clang", *args], cwd=ROOT, check=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            helper = work / "helper.dylib"
            build_fixture(["-dynamiclib", "-fobjc-arc", "-O2", "-mmacosx-version-min=11.0",
                     "-framework", "AppKit", "-framework", "GameController", "-framework", "CoreGraphics",
                     "-framework", "IOKit", "-framework", "OpenGL", "-framework", "AudioToolbox",
                     "-framework", "CoreAudio", "-ISources/NokcanduPadEngine/include",
                     *["Resources/rawmouse/" + s for s in ["rawmouse.m", "audiofollow.m", "bonjourbridge.m",
                       "micguard.m", "socket-events.c", "helper-state.c", "commit-memory.c"]],
                     "Sources/NokcanduPadEngine/padengine.c", "-o", str(helper)])
            sdl = work / "sdl.c"
            sdl.write_text('''#include <dlfcn.h>
#include <string.h>
int SDL_WaitEventTimeout(void *event,int timeout) { (void)timeout; *(unsigned *)event=0; return 7; }
void *SDL_GameControllerOpen(int index) { (void)index; return 0; }
void *expected(const char *name) { return !strcmp(name,"SDL_WaitEventTimeout") ? (void *)SDL_WaitEventTimeout : (void *)SDL_GameControllerOpen; }
__attribute__((noinline)) void *lookup(void *h,const char *n) { void *p=dlsym(h,n); __asm__ volatile("" : "+r"(p)); return p; }
''')
            build_fixture(["-dynamiclib", "-O2", str(sdl), "-o", str(work / "libSDL-fixture.dylib")])
            driver = work / "driver.c"
            driver.write_text('''#include <dlfcn.h>
__attribute__((noinline)) void *lookup(void *h,const char *n) { void *p=dlsym(h,n); __asm__ volatile("" : "+r"(p)); return p; }
''')
            for name in ["winebus.so", "winebus.sys.so", "other.so"]:
                build_fixture(["-dynamiclib", "-O2", str(driver), "-o", str(work / name)])
            main = work / "main.c"
            main.write_text('''#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
typedef void *(*lookup_t)(void *,const char *);
int main(int argc,char **argv) {
 (void)argc;int enabled=!strcmp(argv[1],"winedevice.exe");
 void *sdl=dlopen("./libSDL-fixture.dylib",RTLD_NOW|RTLD_LOCAL);
 if(!sdl)return 1;
 lookup_t inside=(lookup_t)dlsym(sdl,"lookup");
 const char *symbols[]={"SDL_WaitEventTimeout","SDL_GameControllerOpen"};
 for(unsigned s=0;s<2;++s) {
  void *(*expected)(const char *)=(void*(*)(const char*))dlsym(sdl,"expected");
  void *original=expected(symbols[s]);
  if(dlsym(sdl,symbols[s])!=original)return 9;
  /* SDL's own lookup must remain original, even before Wine loads its table. */
  if(!original || inside(sdl,symbols[s])!=original)return 10+s;
  const char *drivers[]={"./winebus.so","./winebus.sys.so","./other.so"};
  for(unsigned i=0;i<3;++i) {
   void *driver=dlopen(drivers[i],RTLD_NOW|RTLD_LOCAL);if(!driver)return 2;
   lookup_t lookup=(lookup_t)dlsym(driver,"lookup");
   void *result=lookup(sdl,symbols[s]);
   if((result!=original)!=(i<2 && enabled))return 20+i;
   if(s==0) { unsigned char event[56]={0}; if(((int(*)(void*,int))result)(event,10)!=7)return 30; }
   else if(((void*(*)(int))result)(0)!=0)return 31;
   if(inside(sdl,symbols[s])!=original)return 40;
  }
 }
 puts("SDL internal lookups preserved; Wine hooks forward successfully");return 0;
}
''')
            exe = work / "probe"
            build_fixture(["-O2", str(main), "-o", str(exe)])
            env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(helper), NOKCANDU_NO_GAME_APP="1")
            for program in ["winedevice.exe", "game.exe"]:
                with self.subTest(program=program):
                    result = subprocess.run([str(exe), program], cwd=work, env=env,
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("Wine hooks forward successfully", result.stdout)

if __name__ == "__main__":
    unittest.main()
