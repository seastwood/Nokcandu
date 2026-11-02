# Experimental native packet capture for Wine

This is an additive build of Wine's wpcap module for the pinned 10.0/11.0 engines.
It backs the optional shared native-IPX component. Wine 11 passed local regressions
and ROM2 native-IPX discovery/join/gameplay against unchanged Windows 98 over Mac
Wi-Fi. Wine 10 builds but is not offered until runtime validation. SPX is unsupported.

Prepare the pinned source archives/compiler/Bison with the existing winemac build,
then run `WINE_VERSION=11.0 Engine/wpcap/build.sh` (or `10.0`). The script checks the
upstream archive hash, applies only the matching patch, rejects conflicting source
or an object directory configured against another source, and emits modules plus
source/patch hashes and SHA256SUMS under ignored `build/wpcap-<version>`.

The patches provide Darwin immediate/nonblocking capture for WinPcap's maximum
responsiveness request and implement the missing real packet-notification event.
They preserve Wine's LGPL-2.1-or-later notices. Distribution must include matching
Wine source, these patches and this build script, allowing the modules to be
rebuilt/replaced. No generated binaries belong in Git.

See the [investigation](../../docs/investigations/native-ipx-mac-2026-11-01.md) for
verified evidence, failures, test probes, temporary permission lease and remaining
integration/profile/migration requirements. The UDP component remains the default.

The component selects a single local interface through
`NOKCANDU_NATIVE_IPX_INTERFACE`; ordinary clients without it retain full enumeration.
`Engine/wpcap/package-source.sh` packages matching complete Wine source, patches and
build/tool scripts for release alongside the app. The app includes license/source
information; generated binaries and source archives stay under ignored build/.


The build also compiles `adapter-info.c` into a read-only Windows adapter reader.
Nokcandu verifies its manifest fingerprint and reads adapter identities through the
game's Wine API. macOS can redact a Foundation-launched `ifconfig` MAC to
02:00:00:00:00:00; that address must never become the native IPX primary adapter.
See the native-IPX investigation for the guarded existing-install migration.
