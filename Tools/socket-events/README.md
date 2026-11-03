# Closed TCP readiness regression

`test.c` is the hardware-free CI boundary check, compiled by `SocketEventTests`. It checks role gating, errno preservation, clean EOF, real urgent data, non-sockets, truncated socket information and real errors.

`probe.c` and `probe.py` are real end-to-end tests. CI runs them through `ci.py` after building the app, downloading checksum-pinned official Wine 10/11 and template archives and compiling both 32/64-bit probes. All four modes run for each engine/architecture combination. They use a local synthetic TCP responder and a new disposable Wine prefix on every run. They never read game profiles or submit account credentials. The script stops only its own Wine prefix before deleting it.

Compile `probe.c` using llvm-mingw (`i686-w64-mingw32-clang` or `x86_64-w64-mingw32-clang`) with `-lws2_32`, then run:

```sh
python3 Tools/socket-events/probe.py \
  --wine /absolute/path/to/wine/bin/wine \
  --frameworks /absolute/path/to/Contents/Frameworks \
  --probe /absolute/path/to/probe.exe \
  --library /absolute/path/to/nokcandu-rawmouse.dylib \
  --mode graceful
```

Omit `--library` to observe the unmodified engine. Other modes are `refused`, `urgent` and `reset`. With the affected engine, normal EOF reports both readable and exceptional; the correction must make it readable only. Failed connection 10061, real urgent data and reset 10054 must remain visible. No real public service is contacted and no raw recording/packet capture is saved.

Run the complete pinned CI check locally after `./build-app.sh`:

```sh
python3 Tools/socket-events/ci.py
```

For offline developer validation, repeat `--runtime-contents /absolute/runtime/Contents` for already verified local runtimes. CI uses the pinned downloads, never user installations. An ARM runner installs Rosetta before executing x86 Wine.
