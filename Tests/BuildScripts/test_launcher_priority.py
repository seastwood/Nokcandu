"""The store client a game belongs to must not be put in the background (actual helper header)."""
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
class LauncherPriorityTests(unittest.TestCase):
    def test_own_client_stays_normal_and_others_step_back(self):
        with tempfile.TemporaryDirectory(prefix="nok-launcher-prio-") as tmp:
            work = Path(tmp); source = work/'test.c'; binary = work/'test'
            source.write_text(r'''
#include "launcher-priority.h"
int main(void) {
 char env[64];
 if (nokcandu_front_game("1234\n/games/steam/prefix\n", env, sizeof env) != 1234 || strcmp(env, "/games/steam/prefix")) return 1;
 if (nokcandu_front_game("1234\n", env, sizeof env) != 1234 || env[0]) return 2;          // older helper: no environment
 if (nokcandu_front_game("1234", env, sizeof env) != 1234 || env[0]) return 3;
 if (nokcandu_front_game("", env, sizeof env) || nokcandu_front_game("x", env, sizeof env) || nokcandu_front_game("1\n/a\n", env, sizeof env) || nokcandu_front_game(0, env, sizeof env)) return 4;
 char small[4];
 if (nokcandu_front_game("77\n/long/path\n", small, sizeof small) != 77 || strlen(small) != 3) return 5;
 if (nokcandu_launcher_steps_back(true, "/games/steam/prefix", "/games/steam/prefix")) return 6;   // the game's own client
 if (!nokcandu_launcher_steps_back(true, "/games/steam/prefix", "/games/battle/prefix")) return 7; // another client
 if (!nokcandu_launcher_steps_back(true, "", "/games/steam/prefix")) return 8;                    // unknown: as before
 if (!nokcandu_launcher_steps_back(true, "/games/steam/prefix", 0)) return 9;
 if (nokcandu_launcher_steps_back(false, "/a", "/b")) return 10;                                   // no game in front
 return 0;
}
''')
            subprocess.run(['xcrun','clang','-Wall','-Wextra','-Werror','-I',str(ROOT/'Resources/rawmouse'),str(source),'-o',str(binary)],check=True,capture_output=True,text=True)
            result = subprocess.run([str(binary)],capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
if __name__ == '__main__': unittest.main()
