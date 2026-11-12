"""Exercise runtime selection against real Mach-O install names, without devices."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Engine/controller-hid/sdl-runtime.sh"

class ControllerSDLRuntimeTests(unittest.TestCase):
    def dylib(self, folder, name, install_name=None):
        src = folder / (name + ".c")
        src.write_text("int sdl_fixture(void) { return 0; }\n")
        subprocess.run(["xcrun", "clang", "-dynamiclib", str(src), "-Wl,-install_name," + (install_name or name), "-o", str(folder/name)], check=True, capture_output=True)

    def select(self, folder):
        return subprocess.run(["/bin/bash", "-c", 'source "$1"; nokcandu_controller_sdl_runtime "$2" || exit $?; printf "%s" "$NOKCANDU_CONTROLLER_SDL_NAME"', "--", str(SCRIPT), str(folder)], capture_output=True, text=True)

    def test_keeps_stock_dependency_when_old_and_compatibility_libraries_coexist(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp)
            self.dylib(folder,"libSDL2.dylib")
            self.dylib(folder,"libSDL2-2.0.0.dylib")
            result=self.select(folder)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(result.stdout,"libSDL2-2.0.0.dylib")

    def test_missing_or_mislabeled_runtime_cannot_fall_back_to_old_library(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp)
            self.dylib(folder,"libSDL2.dylib")
            self.assertNotEqual(self.select(folder).returncode,0)
            self.dylib(folder,"libSDL2-2.0.0.dylib", "libSDL2.dylib")
            self.assertNotEqual(self.select(folder).returncode,0)

if __name__=="__main__": unittest.main()
