#!/usr/bin/env python3
"""Check clean/previously-patched detection without compiling or network access."""
import hashlib
from pathlib import Path
import subprocess
import tarfile
import tempfile
import sys

root = Path(__file__).resolve().parents[2]
for version in (sys.argv[1:] or ("10.0", "11.0")):
    assert version in ("10.0", "11.0")
    archive = root / f"build/winemac-work/wine-{version}.tar.xz"
    expected = (root / f"Engine/winemac/checksums/wine-{version}.sha256").read_text().strip()
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == expected
    patch = (root / f"Engine/wpcap/native-capture-{version}.patch").read_bytes()
    with tempfile.TemporaryDirectory(prefix="nokcandu-packet-patch-") as scratch:
        destination = Path(scratch)
        with tarfile.open(archive) as source:
            for name in ("wpcap.c", "wpcap.spec", "unixlib.c", "unixlib.h"):
                data = source.extractfile(f"wine-{version}/dlls/wpcap/{name}").read()
                file = destination / "dlls/wpcap" / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_bytes(data)
        def apply(*args):
            return subprocess.run(["/usr/bin/patch", "--force", "--silent", "-p1", "-d", scratch, *args],
                                  input=patch, stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode
        # Without --force, patch can silently undo -R and mistake pristine
        # sources for an already-patched tree. Test both states explicitly.
        assert apply("--dry-run", "-R") != 0, "Pristine source incorrectly accepted as patched"
        assert apply("--dry-run") == 0
        assert apply() == 0
        assert apply("--dry-run", "-R") == 0
        assert apply("--dry-run") != 0, "Patch must not apply twice"
        source = (destination / "dlls/wpcap/wpcap.c").read_text()
        assert "HANDLE CDECL pcap_getevent" in source
        assert "FreeLibraryAndExitThread" in source
        unix = (destination / "dlls/wpcap/unixlib.c").read_text()
        assert "pcap_set_immediate_mode( handle, 1 )" in unix
        assert "pcap_setnonblock( handle, 1" in unix
        print(f"Wine {version}: clean apply, patched detection, event and capture changes verified")
