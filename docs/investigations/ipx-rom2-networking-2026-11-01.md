# Shared IPX networking and ROM2 — 2026-11-01

## Request and current evidence

The user reports that Rage of Mages II cannot use IPX and does not find TCP/IP games. They cannot perform the cross-machine test until later and note that the host may also be responsible. Do not equate installing IPX support with a verified multiplayer fix.

The installed GOG `allods2.exe` is 32-bit and imports `WSOCK32.dll`. Its shipped README documents TCP/IP ports 8000 and 8001 and says those ports are hard-coded. Its Wine prefix already has legacy DirectPlay IPX/TCP provider registrations pointing to `dpwsockx.dll`.

A small Winsock 1 probe using **that installation's existing engine/environment**, without modifying game files, failed `socket(AF_IPX, SOCK_DGRAM, NSPROTO_IPX)` with Winsock error **10047** (address family unsupported). Repeating from a temporary folder with the official IPXWrapper release and native DLL rules passed socket creation, bind, address retrieval, send, and receive. Legacy `DirectPlayCreate` with the IPX provider GUID also initialized successfully using the temporary wrapper and existing provider registrations. No registry setup tool was run.

Ordinary Winsock 1 TCP/IP socket/bind/listen/connect/accept/send/receive passed both without and with the wrapper. This establishes basic TCP/IP transport locally and checks forwarding through the IPX shims; it does **not** establish ROM2's discovery, remote joining, or gameplay. Host/interface configuration remains a possible TCP/IP cause. The earlier Battlefield LAN failure was resolved by a Windows virtual-adapter change; do not assume the same cause without a ROM2 test.

## Component, scope and source

The shared opt-in component is `ipx-networking`, displayed as **IPX networking (legacy games)** in Fixes. It uses [IPXWrapper 0.7.2](https://github.com/solemnwarning/ipxwrapper/releases/tag/ipxwrapper-0.7.2), SHA-256 `a32255f528533be0add8eeabb0794fcbf8b025110cb4624b79dbb82698e6a404` for the official binary zip. The official release metadata and downloaded bytes agree on this digest. Project [instructions and compatibility](https://github.com/solemnwarning/ipxwrapper/blob/master/readme.txt) cover Winsock 1.x and legacy DirectPlay before version 8.

The initial installer extracted the four named DLLs (`ipxwrapper`, `mswsock`, `wsock32`, `dpwsockx`), the settings utility, license and README. It validates the Windows architecture and writes through the normal component journal. DLL rules are `n,b`, scoped to the private game's launcher environment. Ordinary TCP/IP continues through the wrapper's forwarding path. The component does not add IPX API support to modern Winsock 2 or DirectPlay 8 applications.

Offer it to private managed **32-bit** games without a game-name allowlist. Static imports alone cannot identify all IPX-capable games: engines, COM and delayed loads can hide networking use. Eligibility is permission to try the component, not a claim that the game implements IPX or that multiplayer has been verified. Native Mac games, 64-bit games and shared Steam/Battle.net/hosted environments are excluded. Shared environments need safe per-program routing before environment-wide DLL rules can be applied there; do not use one game's configuration to change all games in a shared prefix.

This is IPX **over UDP/IP**, not native Ethernet IPX frames. Other computers need compatible IPXWrapper support. Windows 11 should not be assumed to supply native IPX either. Keep the default UDP transport for this Wine setup; native Ethernet capture modes require additional platform support and were not tested. DOSBox/IPX-server interoperability is not verified here.

## User flow and preservation

Install from Fixes, choose IPX inside a game that offers it, and use **IPX Network Settings…** to choose the appropriate physical adapter when needed. The settings utility is fingerprint-checked before launching. Adapter identities are local machine choices, not portable settings to force on another player's machine.

Downloads and extraction finish before mutation; the game/config and target paths are rechecked. Existing differing DLLs/utilities/license files and symlinks are refused rather than overwritten. No game executable, save, graphics setting, global engine DLL, Mac network setting, firewall rule or DirectPlay provider registration is edited. Existing `ipxwrapper.ini` and other explicit user settings are not generated or overwritten. Recovery records precede mutation. Manual launcher edits retain the existing protection.

Fresh and existing eligible installations use the same optional component installer; nothing is automatically enabled for unrelated games. Existing already-working games keep their configurations. The version is pinned; future updates need a tested component migration or explicit Undo/reinstall, not silent replacement of third-party DLLs.

Undo in Fixes validates the owned files and DLL-rule values, restores the previous per-game rules while preserving unrelated settings, and removes/restores only journal-owned files. Edits after installation block conflicting Undo. Installation failure retains the recovery marker and normal Undo path.

## Profiles and sharing

Using the shared `CompatibilityFix` ID automatically includes the component in `Profiles.make`, profile JSON, the prefilled sharing payload, compatibility previews and normal profile application. Profiles contain trusted component IDs and settings, never DLL bytes, arbitrary download URLs or machine-specific network adapter identities. Applying a profile downloads the pinned release through the same protected installer.

The live profile-service allowlist was updated to match every current built-in component, including IPX and the previously omitted Ubisoft browser fix. The change is [Nokcandu-Profiles commit c0c61d3](https://github.com/seastwood/Nokcandu-Profiles/commit/c0c61d3c2f4d962cda34c79e0a205c2de2b22b1a). Re-fetching the live validator passed ID parity and synthetic normalization round trips for all 11 trusted fix IDs; an unknown ID was rejected. No profile/issue/comment was posted. The dirty local `profiles-repo` checkout was preserved.

`Tools/profile-check/check-fix-ids.py` checks source allowlist parity without executing the validator. `test-roundtrip.py` exercises its normalizer with synthetic per-component settings. Run these against the current service source whenever adding a fix; the app enum alone cannot update the separate service. A matching one-line patch is retained beside the tools for review/provenance.

## Verification and limits

Portable probe sources are in `Tools/ipx-probe/`; compiled Windows probes and release DLLs are temporary and must not be committed. Swift tests cover eligibility independent of names, exclusions, protected destinations, symlink/architecture rejection, profile creation/sharing/preview, preservation of unrelated settings, and Undo. An opt-in `NOKCANDU_E2E_IPX=1` test ran the **real verified release** through install/profile/Undo in a disposable fixture; all four IPX tests passed.

Actual ROM2 cross-machine IPX/TCP discovery, joining and gameplay remain pending the user's later test. No TCP/IP-specific runtime fix is established. Do not call the local socket probe a multiplayer regression pass. The optional standalone Battlefield server-browser offering remains queued; its existing combined menu/server correction is already retained by the built-in profile recipe.

## Final installed state and verification

The final app build and full suite passed: **207 tests, 7 skipped, zero failures**. The official-package E2E was run separately with its opt-in flag and all four IPX tests passed. Built/signed and installed the app, then installed `ipx-networking` into ROM2 through the actual shared component API after confirming the managed launcher fingerprint. A restore point was created. The original game executable, all four existing top-level save/character files, graphics/confirmed-graphics state, program selection, launch arguments, display/window settings and unrelated environment values were compared before/after and preserved. The generated launcher matches its saved fingerprint, and a freshly created profile includes `ipx-networking`.

The installed app was opened and ROM2 selected: Fixes visibly shows **IPX networking (legacy games) — Installed**, **Undo**, and **IPX Network Settings…**, alongside Save Setup as Profile and Share This Setup. ROM2 itself was not launched for an unattended multiplayer claim. Local test success does not replace the deferred cross-machine test.

Temporary trace/probe processes had finished; no process held the temporary diagnostic libraries when checked. Temporary downloaded/extracted IPX binaries and compiled diagnostic/probe helpers were removed; portable probe sources and the checksum-pinned normal download cache remain. No machine-specific backup, account/session log or runtime/game binary was added to the repository.


## Hosting crash correction (supersedes initialization-only readiness)

The user's actual ROM2 host attempt crashed reading address zero. The report's
DirectPlay return address maps to Wine 11 `dplayx_messages.c` calling the unset
`SendToGroupEx` callback. IPXWrapper 0.7.2 `src/directplay.c:SPInit` supplies legacy
`Send`, not `SendEx`/`SendToGroupEx`. Initialization and socket loopback therefore
were insufficient regressions. `Tools/ipx-probe/directplay-ipx.c` now opens an IPX
host session and creates/destroys a host player. The original integration reproduced
the NULL callback crash on CreatePlayer. With native Microsoft `dplayx.dll`, the
same engine, prefix, wrapper, and probe passed all operations without registration
changes. This is a shared legacy DirectPlay integration problem, not a ROM2 recipe.

The component now adds a private 32-bit native `dplayx.dll` rule alongside the four
wrapper DLLs. The matching Microsoft `dplayx.dll`, `dpwsockx.dll` and `dplaysvr.exe`
go in the private prefix’s `windows/syswow64`, replacing only exact untouched copies
of the bundled Wine files (or creating missing files). Each original is journal-backed.
COM uses that system directory, so a game-folder-only core is insufficient. IPXWrapper
continues to supply the game-folder IPX provider and forwards TCP/IP to the matching
Microsoft system provider. The engine bundle and other prefixes stay untouched. Source: Microsoft's February 2010 DirectX redistributable, archived
at the mirror documented by the official Winetricks recipe (the original Microsoft
URL returns 404; June 2010 lacks `dxnt.cab`). Installer SHA-256:
`f6d191e89a963d7cca34f169d30f49eab99c1ed3bb92da73ec43617caaa1e93f`.
Extract only `dxnt.cab` then the three named files; additionally require DLL SHA-256
`f50362966d69446f3f562946e77cb72ba8058abcddfadac4d2b0841e07434c3c`.
No complete DirectX installation or provider re-registration is performed.

Fresh installs and profile application use the corrected component. Existing
component records without the `dplayx` rule offer Update; profile application also
plans that update. Migration requires a closed game, unchanged managed program,
owned DLLs, applied rules, and generated launcher fingerprint, and rechecks settings
and destinations after downloads. It extends the existing journal and keeps old
Undo values while recording the prior value of the newly managed rule. Unrelated
rules, configuration files, game content, saves, and explicit graphics/display
choices stay intact. Failure retains a recovery record; Undo uses the normal
ownership checks. Manually edited launchers or changed DLLs block migration.
The portable profile ID remains `ipx-networking`, so the shared validator needs no
additional ID change. Adapter preferences remain local.

During this correction the checkout was fast-forwarded from v0.12.1 to the verified
v0.12.2 commit `26966b5`. The release changed packaging, version, notes and README;
no source overlap or merge conflicts occurred. All in-progress changes were retained.
Cross-machine discovery, joining and gameplay still require the deferred user test.


### Matching provider/session-helper verification

Native core plus Wine's TCP/IP provider returned `DPERR_UNAVAILABLE`; Wine's original
legacy TCP/IP Open returned `E_NOTIMPL`. A COM-based explicit-address probe revealed
that game-folder-only native core still allows COM to load the builtin system copy.
The complete matching Winetricks set passed in a disposable prefix; reducing it to
`dplayx.dll`, `dpwsockx.dll`, and `dplaysvr.exe` also passed after restarting only
that test prefix. COM initialization, provider connection, Open(create), CreatePlayer,
DestroyPlayer and Close passed for both IPX and TCP/IP. No extra DirectPlay 8, modem,
NAT-help or registration changes were needed. A legacy DirectPlayCreate comparison
alone does not test a COM game's loading path. Preserve these comparisons when
changing the dependency layout.

Additional extracted-file pins: `dpwsockx.dll`
`0725598871b2f1f65ccd0235683873346c8024a38dead045bce20526af65654d`;
`dplaysvr.exe` `e3ee1e2d903237131ba42c770f07e7eceaa3574b4ce718062a4e3c1f9cdbf893`.
The six real-package/component tests pass, including exact-stock prefix-file
replacement, original-file restoration on Undo, manual-provider/symlink protection,
and an older-component update with unrelated rules preserved. Development executable
lookup now skips the cabextract source directory and can use the built app's reader.
Ordinary remote server discovery/gameplay remain separate, pending cross-machine tests.


### Installed correction and remaining handoff

Final full suite: **209 tests, 9 skipped, zero failures**. Separately, all six
IPX tests passed with `NOKCANDU_E2E_IPX=1`, including real-package fresh install,
older-component migration, profile planning and full Undo restoration of three
original prefix files. Built and signed the app from v0.12.2 (`26966b5`).

Applied the shared migration API to the actual closed ROM2 installation with a
restore point. Confirmed the game executable and four top-level save/character
files retain their hashes; all config except the required DLL rules and generated
launcher fingerprint is unchanged. A new profile includes `borderless` and
`ipx-networking`. In the updated actual ROM2 prefix, COM IPX and COM TCP/IP probes
both passed provider initialization, host-session creation, host-player creation,
destruction and close. This closes the reproduced NULL callback regression at the
DirectPlay layer; actual ROM2 hosting, cross-machine discovery, joining and gameplay
still need the user's test. No claim that remote TCP/IP discovery is fixed yet.

The running Nokcandu app had an unfinished Battlefront II installation open.
Its disk version remains 0.12.1; the signed corrected 0.12.2 app is ready under
`build/Nokcandu.app`. App replacement was deferred to preserve the active installer;
the user was asked to report when it is finished/closed. ROM2's component migration
is already installed independently through the shared API. Do not replace or quit
the app until that installation can be safely left closed. Do not launch a fullscreen
ROM2 test over the user's ongoing installation.


App replacement subsequently completed after Battlefront's automatic file transfer
and launcher check finished. The signed combined 0.12.2 build, including the IPX
correction, nonblocking installation window and installer-destination routing, is
installed in the normal Applications location. The later UI change did not alter
the verified ROM2 component or its profile ID. Actual ROM2 multiplayer remains
pending the user's gameplay test.


### User cross-machine test: host and TCP/IP confirmed; native-IPX peer pending

The user confirmed ROM2 can now host on the Mac. They then confirmed TCP/IP
works and that the Mac and Windows 98 VM can join over TCP/IP. This supersedes
the earlier pending cross-machine TCP/IP status. They report IPX sessions remain
invisible in both directions. The Windows 98 VM runs on their Windows 11 host;
the user believes its IP is 192.168.1.115. The remote view confirms Oracle
VirtualBox. No VM bridge mode or native-IPX driver settings have yet been verified.

Nokcandu currently uses IPXWrapper's UDP transport, which does not directly
interoperate with Windows 98 native IPX Ethernet. IPXWrapper's maintainer explains
this and recommends real-IPX encapsulation for native 9x peers in
[issue 17](https://github.com/solemnwarning/ipxwrapper/issues/17). There is also an
official `win98` compatibility branch, currently commit
`17a861e9168dc07780263df6e8ea0b8f1079fcf6`, distinct from the normal 0.7.2 release.
Do not install the normal modern wrapper into Windows 98 and assume compatibility.
Native Mac packet access is currently unavailable without administrator approval;
`sudo -n tcpdump` reports that a password is required. No permissions, VM adapters,
network drivers, game files, or working TCP/IP settings were changed during this
inspection. Native-IPX interoperability remains an open task, not a confirmed fix.


### Isolated Windows 98 compatibility result

A temporary build of the official Win98 branch passed the socket/bind/address/
send/receive loopback probe in Wine. The user explicitly approved running an
isolated unsigned diagnostic in their VM. Remote keyboard input was unreliable,
so the user downloaded and ran it themselves via a temporary Mac-LAN-only HTTP
server. Both the remote view and user confirm **result 0** on actual Windows 98.
The diagnostic extracted only to `C:\NOKIPX01`; no game or Windows DLL was replaced.
It tested local IPX socket behavior, not DirectPlay hosting or cross-machine
broadcasts. The current native-IPX ROM2 instance is still not a compatible peer
until an appropriate transport/bridge is configured.

Reusable diagnostic build sources are in `Tools/ipx-probe/win98/`. The source is
pinned to official commit `17a861e9168dc07780263df6e8ea0b8f1079fcf6`.
LLVM portability changes: correct the existing select const-pointer prototype,
use exact stdcall labels where GNU ld normally performs fixups, target the old
MSVCRT/PE 4.0 ABI and the C DLL's own DllMain rather than modern UCRT startup.
The DLLs contain no C++ constructors. No vendor binaries are checked into the
repository. Treat this as an experimental diagnostic, not a released universally
compatible Windows 9x component or a native Ethernet bridge. The ordinary stable
Mac IPX component remains on official IPXWrapper 0.7.2.


The reusable build script also completed from a fresh pinned-source checkout.
The diagnostic executable tested in the VM has SHA-256
`e46006ecc9570140efc4ed477e1399d84717f7a340fc92c8fb19eac1a73bdfd4`.
Its complete project/build/probe sources were also made available alongside the
binary on the temporary delivery server. No runtime binaries or generated payload
arrays are tracked. The proposed next step was to place compatibility DLLs in the
VM game directory. The user rejected this direction and clarified that native IPX
must be fixed on the Mac. That proposed VM change was abandoned: no DLLs were
copied into the VM game or Windows directories. The isolated result 0 is historical
only and does not establish native-IPX interoperability. Continue with the
[Mac native-IPX investigation](native-ipx-mac-2026-11-01.md).
