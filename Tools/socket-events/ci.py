#!/usr/bin/env python3
"""Run the real Winsock regression against pinned Wine engines, using scratch prefixes only."""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
ASSETS = {
    '10.0_8': ('Sikarugir-App/Engines', 'v1.0', 'WS12WineSikarugir10.0_8.tar.xz', '2a6bcf2a3bf13cddf825599b6bc1e3659cbf71e1282c6d77141a92f6ac8d4c68'),
    '11.0_1': ('Sikarugir-App/Engines', 'v1.0', 'WS12WineSikarugir11.0_1.tar.xz', '67e29fb3d74f363af39c69ba11f9b13a79812c5db07cf4748672658e4a200a0e'),
    'template': ('Sikarugir-App/Template', 'v1.0', 'Template-1.0.24.tar.xz', '4b5f89eeb9ef139936bdfad33d9b420b05ea4597cb7d63376674f7a8e171321c'),
}
COMPILER = 'llvm-mingw-20261006-ucrt-macos-universal'
ASSETS['compiler'] = ('mstorsjo/llvm-mingw', '20261006', COMPILER+'.tar.xz',
                      (ROOT/'Engine/winemac/checksums'/f'{COMPILER}.sha256').read_text().strip())
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, default=ROOT/'build/Nokcandu.app')
parser.add_argument('--runtime-contents', type=Path, action='append', help='Local validation only; CI downloads the pinned archives by default.')
args = parser.parse_args()
library = args.app.resolve()/'Contents/Resources/nokcandu-rawmouse.dylib'
if not library.is_file():
    parser.error('Build Nokcandu first.')

def unpack(key, work):
    project, release, name, sha = ASSETS[key]
    archive = work/name
    with urllib.request.urlopen(f'https://github.com/{project}/releases/download/{release}/{name}', timeout=120) as response:
        with archive.open('wb') as output:
            shutil.copyfileobj(response, output)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != sha:
        raise SystemExit('Pinned archive checksum mismatch: '+name)
    destination = work/key
    destination.mkdir()
    subprocess.run(['/usr/bin/tar', '-xJf', str(archive), '-C', str(destination)], check=True, timeout=180)
    return destination

with tempfile.TemporaryDirectory(prefix='nok-winsock-ci-') as temporary:
    work = Path(temporary)
    # Provision the same official checksum-pinned compiler as the engine build.
    # The app build uses Zig and does not populate a local llvm-mingw cache.
    compiler_root = unpack('compiler', work)/COMPILER/'bin'
    for architecture in ['i686', 'x86_64']:
        subprocess.run([str(compiler_root/(architecture+'-w64-mingw32-clang')), str(ROOT/'Tools/socket-events/probe.c'), '-O2', '-Wall', '-Wextra', '-Werror', '-lws2_32', '-o', str(work/(architecture+'.exe'))], check=True)
    runtimes = args.runtime_contents
    if not runtimes:
        template = unpack('template', work)
        contents = next(template.glob('*.app/Contents'))
        runtimes = []
        for engine in ['10.0_8', '11.0_1']:
            archive = unpack(engine, work)
            runtime = work/('runtime-'+engine)/'Contents'
            (runtime/'SharedSupport').mkdir(parents=True)
            shutil.move(str(archive/'wswine.bundle'), str(runtime/'SharedSupport/wine'))
            shutil.copytree(contents/'Frameworks', runtime/'Frameworks', symlinks=True)
            subprocess.run(['/usr/bin/xattr', '-dr', 'com.apple.quarantine', str(runtime)], check=True)
            runtimes.append(runtime)
    for architecture in ['i686', 'x86_64']:
        probe = work/(architecture+'.exe')
        for runtime in runtimes:
            runtime = runtime.resolve()
            for mode in ['graceful', 'refused', 'urgent', 'reset']:
                print(f'Winsock {runtime.parent.name} {architecture} {mode}', flush=True)
                subprocess.run(['python3', str(ROOT/'Tools/socket-events/probe.py'), '--wine', str(runtime/'SharedSupport/wine/bin/wine'), '--frameworks', str(runtime/'Frameworks'), '--probe', str(probe), '--library', str(library), '--mode', mode], check=True, timeout=150)
print('All real Winsock socket regressions passed.', flush=True)
