#!/usr/bin/env python3
"""Synthetic client/child launch only; disposable prefix, no games or account data."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--runtime', type=Path, required=True, help='Cached verified runtime Contents directory')
parser.add_argument('--compiler', type=Path, required=True, help='Pinned llvm-mingw bin directory')
parser.add_argument('--library', type=Path, required=True)
args = parser.parse_args()
source = Path(__file__).with_name('probe.c')
for architecture in ['i686', 'x86_64']:
    with tempfile.TemporaryDirectory(prefix='nok-program-fixes-') as temporary:
        work = Path(temporary)
        client, game = work/'prefix/drive_c/Client', work/'prefix/drive_c/Games/Own'
        state = work/'Harness.app/Contents/SharedSupport/nokcandu'
        for folder in [client, game, state]: folder.mkdir(parents=True)
        compiler = args.compiler/(architecture+'-w64-mingw32-clang')
        for output in [client/'client.exe', game/'game.exe']:
            subprocess.run([str(compiler), str(source), '-O2', '-Wall', '-Wextra', '-Werror', '-o', str(output)], check=True)
        dll_source = work/'module.c'
        dll_source.write_text('__declspec(dllexport) int __cdecl marker(void) { return 1942; }\n')
        for output in [client/'nok-scoped-test.dll', game/'nok-scoped-test.dll']:
            subprocess.run([str(compiler), '-shared', str(dll_source), '-o', str(output)], check=True)
        shutil.copyfile(args.library, state/'nokcandu-rawmouse.dylib')
        (state/'program-fixes.tsv').write_text('test-owner\tC:\\Games\\Own\\game.exe\tWINEDLLOVERRIDES=nok-scoped-test=n\n')
        env = os.environ.copy()
        env.update(WINEPREFIX=str(work/'prefix'), DYLD_FALLBACK_LIBRARY_PATH=str(args.runtime/'Frameworks')+':/usr/lib',
                   DYLD_INSERT_LIBRARIES=str(state/'nokcandu-rawmouse.dylib'), CX_ROOT=str(args.runtime/'SharedSupport/wine'),
                   WINEDEBUG='-all', SikarugirAppWine11='1', ROSETTA_ADVERTISE_AVX='1', NOKCANDU_NO_GAME_APP='1',
                   NOKCANDU_NO_MICROPHONE='1', WINEDLLOVERRIDES='nok-scoped-test=b')
        wine = args.runtime/'SharedSupport/wine/bin/wine'
        try:
            result = subprocess.run([str(wine), 'C:\\Client\\client.exe', 'C:\\Games\\Own\\game.exe'], env=env,
                                    capture_output=True, text=True, timeout=100)
            print(architecture, result.stdout, end='', flush=True)
            if result.returncode or 'client retained its original DLL rules' not in result.stdout:
                print(result.stderr[-3000:])
                raise SystemExit('Scoped child DLL routing failed: '+str(result.returncode))
        finally:
            for flag in ['-k', '-w']:
                subprocess.run([str(wine.with_name('wineserver')), flag], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
