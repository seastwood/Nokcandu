#!/bin/bash
# Diagnostic only: official Win98 branch, built without a modern UCRT dependency.
# Usage: build.sh /absolute/build/output /absolute/i686-w64-mingw32-clang
set -euo pipefail
probeSourceDir="$(cd "$(dirname "$0")" && pwd)"
peerBuildRoot="${1:?Choose an output directory outside tracked source}"
export NOKCANDU_WIN98_CC="${2:?Choose i686-w64-mingw32-clang}"
peerCommit=17a861e9168dc07780263df6e8ea0b8f1079fcf6
mkdir -p "$peerBuildRoot"
peerBuildRoot="$(cd "$peerBuildRoot" && pwd)"
peerSource="$peerBuildRoot/source"
[ ! -e "$peerSource" ] || { echo 'Choose a fresh output directory.' >&2; exit 1; }
git clone https://github.com/solemnwarning/ipxwrapper.git "$peerSource"
git -C "$peerSource" checkout --detach "$peerCommit"
export NOKCANDU_WIN98_BUILTINS="$("$NOKCANDU_WIN98_CC" --print-runtime-dir)/libclang_rt.builtins-i386.a"
[ -f "$NOKCANDU_WIN98_BUILTINS" ]
# LLVM checks this pre-existing prototype mismatch more strictly than GCC.
python3 - "$peerSource" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1])/'src/winsock.c'
s=p.read_bytes();old=b'const PTIMEVAL timeout';assert old in s
p.write_bytes(s.replace(old,b'const TIMEVAL *timeout'))
PY
cat > "$peerBuildRoot/compiler.sh" <<'SH'
#!/bin/bash
set -e
extra=()
for arg in "$@"; do
 if [ "$arg" = -shared ]; then
  # These are C DLLs with their own DllMain, no C++ constructors or CRT globals.
  # Do not link the modern toolchain's UCRT startup into a Win98 diagnostic.
  extra=(-nostdlib -Wl,--entry,DllMain@12 -Wl,--major-os-version,4,--minor-os-version,0,--major-subsystem-version,4,--minor-subsystem-version,0 -lmsvcrt-os -lkernel32 -ladvapi32 -luser32 -lmingwex -lmsvcrt-os "$NOKCANDU_WIN98_BUILTINS")
 fi
done
exec "$NOKCANDU_WIN98_CC" -D__MSVCRT_VERSION__=0x600 -D__USE_MINGW_ANSI_STDIO=0 -Wno-incompatible-function-pointer-types "$@" "${extra[@]}"
SH
chmod +x "$peerBuildRoot/compiler.sh"
cd "$peerSource"
make src/ipxwrapper_stubs.s src/wsock32_stubs.s src/mswsock_stubs.s src/dpwsockx_stubs.s
# GNU ld's stdcall-fixup resolves these names automatically; LLD needs exact labels.
python3 - "$peerSource" <<'PY'
import pathlib,re,sys
for p in (pathlib.Path(sys.argv[1])/'src').glob('*_stubs.s'):
 s=p.read_text()
 for name,n in [('find_sym',8),('find_sym_direct',8),('log_call',12),('fprof_record_timed',12),('fprof_record_untimed',4)]:
  s=re.sub('_'+name+r'\b','_'+name+'@'+str(n),s)
 p.write_text(s)
PY
make -j4 ipxwrapper.dll wsock32.dll mswsock.dll dpwsockx.dll CC="$(printf '%q' "$peerBuildRoot/compiler.sh")" VERSION="win98-$peerCommit"
common=(-D__MSVCRT_VERSION__=0x600 -D__USE_MINGW_ANSI_STDIO=0 -nostdlib -Wl,--entry,mainCRTStartup -Wl,--major-os-version,4,--minor-os-version,0,--major-subsystem-version,4,--minor-subsystem-version,0)
"$NOKCANDU_WIN98_CC" "${common[@]}" "$probeSourceDir/../ipx-loopback.c" "$probeSourceDir/probe-entry.c" -o probe.exe -lmsvcrt-os -lkernel32 -luser32 -lwsock32
python3 - "$peerSource" "$peerBuildRoot/payload.h" <<'PY'
import pathlib,sys
names=['ipxwrapper.dll','mswsock.dll','wsock32.dll','dpwsockx.dll','probe.exe']
with open(sys.argv[2],'w') as f:
 for i,name in enumerate(names):
  data=(pathlib.Path(sys.argv[1])/name).read_bytes()
  f.write('static const unsigned char payload%d[]={%s};\n'%(i,','.join(map(str,data))))
 f.write('struct Member{const char*name;const unsigned char*data;unsigned long size;};static const struct Member files[]={\n')
 for i,name in enumerate(names):f.write('{"%s",payload%d,sizeof(payload%d)},\n'%(name,i,i))
 f.write('};\n')
PY
"$NOKCANDU_WIN98_CC" "${common[@]}" -Wl,--subsystem,windows -I "$peerBuildRoot" "$probeSourceDir/test-installer.c" -o "$peerBuildRoot/win98-ipx-test.exe" -lkernel32 -luser32 -lmsvcrt-os
shasum -a 256 "$peerBuildRoot/win98-ipx-test.exe"
echo 'Diagnostic package built. This is not a game installer or a verified native-IPX bridge.'
