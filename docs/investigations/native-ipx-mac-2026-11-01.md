# Native Ethernet IPX on the Mac — 2026-11-01

## Status and scope

**User-confirmed native IPX discovery, joining and gameplay:** Windows 98 found,
joined and played in a Mac-hosted ROM2 session with the Mac on Wi-Fi and the VM's
Windows host on Ethernet. The Windows 98 game/system setup was unchanged.
The final managed build also passed user-confirmed discovery and joining in the
reverse direction (VM hosts, Mac joins); see the final retest below.

A shared optional `native-ipx-networking` component is implemented and tested on top
of `ipx-networking`. It applies to eligible private 32-bit Wine 11 games, independently
of game name. The signed 0.12.2 development update and guarded ROM2 migration are
installed. The user confirmed normal permission approval opens ROM2 and, after
correcting the VM's restored NAT configuration to bridged networking, **discovery
and joining work in both hosting directions**. Earlier actual gameplay was also
confirmed with the Mac hosting. The managed session helper stays active until the
last native-IPX game closes; live closure restored device ownership and removed
its state. There is no fixed production match timeout.

The adapter correction passes ten focused tests, including official-package
installation, placeholder-MAC migration, preservation of manual conflicts and Undo.
The preceding complete suite had 212 passing tests and seven optional skips. Strict
signature verification passed using normal certificate access; no trust settings
or security bypass were changed. Historical failed attempts below are superseded
by this final result.

The ordinary UDP option remains unchanged. Native SPX is not supported. Wine 10
source builds, but native mode is not offered there until runtime validation.

The VM runs under VirtualBox on a Windows 11 computer connected by Ethernet. The
Mac uses Wi-Fi. The user confirmed the VM was hosting with its original IPX setup
during the three-format discovery test. No VM game/system DLLs or adapter settings
were changed. The earlier isolated `C:\NOKIPX01` test is historical and is not the
chosen implementation route; see the superseded proposal in the
[earlier investigation](ipx-rom2-networking-2026-11-01.md).

Native IPX is layer-two traffic, not UDP/IP. Equal IPv4 subnets do not prove it
passes through the physical adapter, AP, bridge and guest IPX binding. Mac Wi-Fi
is **not categorically unsupported**: a wired comparison helps locate filtering,
but this experiment has not established that a cable is required. Oracle's
[VirtualBox bridge limitations](https://docs.oracle.com/en/virtualization/virtualbox/7.0/user/networkingdetails.html)
for wireless bridges on macOS/Linux do not establish a limitation for this
Windows-hosted wired VM. The host's actual bridge selection remains uninspected.

## Confirmed Mac failures and corrections

The supplied engines are built without libpcap support and contain no wpcap
module. Wine 10.0/11.0 provide source for the module, including WoW64 entry points.
An additive build is under `Engine/wpcap/`, using the existing pinned Wine archive
checksums and build tools. It builds x86/x64 PE modules plus x86_64 Unix support;
it does not change the graphics driver or installed/global engine.

Adding the unmodified module was insufficient:

1. Capture enumeration worked (27 adapters), and positive-timeout capture handles
   opened with the user's temporary BPF authorization. IPXWrapper instead calls
   `pcap_open(..., PCAP_OPENFLAG_MAX_RESPONSIVENESS, -1, ...)`; Wine forwarded the
   negative timeout to libpcap. Darwin rejected it at BIOCSRTIMEOUT, leaving no
   IPX interfaces and Winsock bind error 10049. Translate that request into
   pre-activation immediate mode and nonblocking reads. Honor the documented
   [maximum-responsiveness flag](https://winpcap.org/docs/docs_40_2/html/group__remote__open__flags.html).
2. With capture open, the probe hit Wine's unimplemented `pcap_getevent` stub and
   opened a Wine exception window. This was the isolated `ipx-loopback.exe`,
   **not ROM2**. Implement a real manual-reset packet event, with a bounded
   selectable-descriptor poll worker; only libpcap reads packet buffers.
3. Synchronously joining that worker during a provider's DLL teardown hung
   cleanup on the loader lock. Close now signals stop and delegates final buffer,
   capture and handle cleanup to a module-pinned worker, releasing its module via
   `FreeLibraryAndExitThread`. The caller must not use a capture after close.

`native-capture-10.0.patch` and `native-capture-11.0.patch` deliberately match their
source versions (Wine 10 lacks Wine 11's low-address packet-buffer copy). Both
build, but **only Wine 11 is runtime-verified**. Wine 10 WoW64 packet-memory behavior
requires a separate runtime test before advertising support.

## Evidence and limits

Initial probes used a disposable prefix and temporary app-local DLLs. A later
ROM2 pilot temporarily adds an owned app-local wpcap.dll and private registry
transport/override settings, with original registry export and file fingerprints
recorded outside the repo. No launcher or engine files were modified. Executable,
three saved-game files and game.json still match the earlier snapshot. A character
file changed before this native-packet test stage during the broader user-testing
period; it was preserved, not restored from the old snapshot.
The probe temporarily selected the physical Wi-Fi MAC, network zero and each frame
type in the disposable prefix. Adapter values must remain local to a machine.

Verified under the installed Sikarugir Wine 11 engine:

- IPX socket creation, bind, address, send, receive and exact payload comparison
  pass for Ethernet II, Novell raw 802.3 and LLC 802.2.
- Independent tcpdump observes the corresponding native frames and DirectPlay
  discovery broadcasts, rather than UDP encapsulation. Locally captured outgoing
  frames do **not** prove transmission through the AP or arrival at the peer.
- DirectPlay enumeration returns S_OK and exits cleanly for all three frame types,
  but no sessions are returned and no native reply from the VM appears in capture.
- `Tools/ipx-probe/native-capture.c` passes three repeated immediate capture /
  packet-event / exact self-addressed payload / nonblocking drain / close cycles.
  Experimental Ethernet type 0x88b5 distinguishes its frames from game traffic.
- Clean pinned-source Wine 11 build and Wine 10 build complete. Shell syntax and
  whitespace checks pass. Swift production sources have not changed in this stage.

The shared `Tools/ipx-probe/directplay-ipx.c` has a `scan` mode so enumeration can
be repeated without changing game files. Its normal host/CreatePlayer cases remain.
The user refreshed the original VM’s IPX browser. Capture on the Mac Wi-Fi then
received native LLC 802.2 broadcasts from its VirtualBox MAC, network zero. This
**verifies the VM-to-Mac Wi-Fi receive path**, disproving a blanket cable requirement.
The VM queries use socket 0xba08, while the wrapper provider uses 0xa57f. The
subsequent provider comparison below confirms this is a provider protocol mismatch,
not a ROM2-specific discovery protocol. The generic probe used the wrapper too.

The first ROM2 pilot still failed BIOCSRTIMEOUT: BSD patch’s automatic reversal
heuristic caused the clean-build detection to mistake unpatched sources for an
already-applied patch. `--force` now disables that heuristic in all patch probes
and application. `Tools/native-ipx/check-patches.py` extracts the four original
source files from each checksum-verified archive, proves reverse detection fails
on pristine source, applies the patch, and proves reverse detection succeeds and
forward reapplication fails. Both 10/11 cases pass. The corrected clean Wine 11
module again passed all three capture/event/payload/close cycles before the pilot
was restarted. Module outputs now replace atomically so an earlier process retains
its original mapped inode. The user closed the failed pilot before DLL replacement.

The first corrected-capture pilot still failed discovery because of the provider
protocol mismatch below. The later Microsoft-provider pilot succeeded; see the
user-confirmed result at the top. Wi-Fi is not a remaining blocker for that setup.

## Historical integration requirements (implemented below; local installation pending)

There is intentionally no automatic installation/migration yet. The temporary pilot
has a separate guarded rollback record; it is not an alternative production installer. Do not turn on
native mode, modify generated launchers, publish a new profile ID or replace the
working UDP component before cross-machine discovery/joining is demonstrated.
Future integration must use shared component ownership and safe migration, refuse
modified files/manual launchers, preserve explicit transport/TCP choices, select
adapters locally, and include the portable transport requirement in saved/shared
profiles without serializing MAC addresses or raw local registry state.

The diagnostic module is loaded from a temporary probe directory using a matching
`WINEDLLPATH`. Remove those temporary probe files to undo. For the ROM2 pilot, close the game,
verify its IPX registry still matches the applied export and its capture DLL still
matches the recorded hash, then restore the original IPX export, remove only the
previously absent owned wpcap override and capture DLL. The diagnostic rollback
refuses later user changes. No global engine patch or VM rollback is required. Keep source patches and reproducible tools in the repo;
never commit generated DLLs, runtime archives or raw machine/session traces.

`Tools/native-ipx/packet-access.sh` is a **manual diagnostic lease**, not a shipped
privilege helper or ordinary launch requirement. The user runs sudo locally; Wine
and probes stay unprivileged. It temporarily changes only untouched root:wheel
0600 BPF device ownership to that user, records device identity, and restores only
unchanged leased devices on exit/signal/timeout. It skips customized devices and
never changes groups, modes, daemons or security policy. The first 900-second lease
expired and restored ownership successfully; the user renewed a 1800-second lease.
Ctrl+C ends the lease early. Already-open capture handles remain usable until the
owning processes close. SIGKILL cannot run shell traps; if a diagnostic is forcibly
killed, close probes and reboot to reset devfs, or explicitly restore only the
recorded unchanged leased device owners. A production permission flow remains
unimplemented and must be designed before enabling native mode for games.

## Native DirectPlay protocol comparison

The corrected capture module loads in actual ROM2. A simultaneous trace shows
both machines browsing the same ROM2 application GUID, but different provider
packets: Windows 98 uses destination socket 0xba08 with a 20-byte service-provider
header before the `play` envelope; the Mac’s IPXWrapper provider uses 0xa57f and
omits that header. IPXWrapper source `directplay.c` deliberately defines
`DISCOVERY_SOCKET 42367` (0xa57f). Thus the mismatch is not established as a
game-specific discovery protocol or AP failure; it is a provider interoperability
problem. The earlier generic probe used this same wrapper provider.

A second disposable-prefix comparison removes only its app-local wrapper
`dpwsockx.dll`, allowing the already-installed Microsoft system provider to load.
That provider imports WSOCK32, so socket operations still go through the native
Mac IPX transport. Legacy DirectPlay initialization, session Open and CreatePlayer
all pass. Enumeration returns S_OK with no host present (the VM was browsing).
A corresponding reversible ROM2 pilot preserves the original owned provider DLL
outside the game directory and temporarily removes the app-local wrapper. Actual
peer discovery/joining is still pending. The packet lease expired and restored
root ownership before that pilot could initialize native capture; do not interpret
a permission-denied attempt as provider failure. A renewed lease and game restart
are required for the next test.

Capture handles are limited to the preexisting BPF devices included in the lease.
Opening extra traces and peer-to-peer interfaces exhausted the initial four leased
devices in one disposable comparison; stopping the trace allowed the comparison
to proceed. Newly generated Wi-Fi peer-to-peer MACs can evade a static disabled-
interface list. Future adapter selection/permission management must account for
this without globally disabling unrelated networking.

## Shared feature and verification — 2026-11-02

The successful comparison is now represented by the separate optional
`native-ipx-networking` component, not a ROM2 recipe or a replacement of normal UDP
support. `CompatibilityFixes.install` safely installs/upgrades the existing base
component first. The native component checks its base ownership journal, the exact
pinned Microsoft provider, engine version, module hashes, PE architecture and file
links/conflicts before writing. Its own journal replaces the app-local provider,
adds app-local wpcap plus private matching Unix/PE modules and a permission helper.
The Wine engine bundle and VM remain untouched. Native Undo restores the wrapper;
base Undo requires native Undo first. The generic program-change path already
undoes components in reverse order, then reapplies them at the new program.

Registry ownership records each changed value and its previous type/data, including
absence. Undo validates applied/original values before mutation, preserves unrelated
values, and refuses later conflicting manual edits. Frame/adapter changes through
Nokcandu update that ownership record while retaining the original pre-component
Undo values. Existing valid frame and active physical-adapter choices are preserved;
fresh settings select the active LAN interface and LLC 802.2, network zero.
Manually edited launchers are not overwritten. Saved games are outside all plans.

The per-game interface setting filters Wine's private capture enumeration to that
one interface. It avoids opening unrelated/rotating peer-to-peer interfaces and
reduces capture-handle contention between games. Without that optional local
setting, wpcap still lists all adapters. The selected-interface capture probe listed
exactly one interface/opened one handle and passed three packet/event/payload/drain/
close cycles. Adapter choices are available in the game's Fixes, with local display
names. Advanced IPXWrapper settings remain available, but later manual registry
changes can intentionally require reconciliation before component Undo.

Generated launchers add only the private module search directory while native mode
is enabled. Windows tools receive the same module/interface environment. The
launcher checks the private permission script's fingerprint before execution and
checks the engine version. Only an actual user launch, never profile import,
installation or launcher --check, can request access. When needed it explains the
30-minute raw-LAN-packet lease and invokes macOS administrator authorization; the
password stays in macOS. A background lease runs only the fixed permission helper;
Wine and the game remain unprivileged. Existing handles survive lease expiry, and
the next launch asks again if access has expired. No persistent group/daemon/policy
is installed. The permission AppleScript compiles; the final interactive launch
flow still needs checking after the user unlocks the Mac. The underlying identical
permission lease was exercised manually and restored permissions on expiry.

Profiles capture the native component ID and `nativeIPXFrame` (1=Ethernet II,
2=802.3, 3=802.2), never local interface IDs, MACs, packet permissions or module paths.
The frame requires schema 2, the native component and an integer in 1–3. Profile
preview shows this setting. Apply sets it after component installation; profile
Undo protects later changes and restores the previous frame for preexisting native
installations. Components retain their separate Undo. The shared profile service
was updated with a SHA concurrency guard, commit
`52602c781d08e837a4a6dc71ed80aff66c8a3712`, and checked against all 12 trusted fix
IDs. All three frame choices normalize unchanged; invalid/bool/string values,
missing component, old schema and unknown download IDs are rejected. No profile,
issue or discussion was posted and no game/runtime binaries were committed.

The app build bundles only runtime-verified Wine 11 native modules, signs the Unix
module and regenerates its bundled fingerprints after signing. Release packaging
requires the module and builds a matching source archive with pinned complete Wine
source, patches, tool preparation, notices and build scripts. Wine 10's maintained
patch also builds, but is not enabled. `Tools/native-ipx/check-patches.py` verifies
pristine/applied/idempotent patch detection for both versions.

Final suite: `NOKCANDU_E2E_IPX=1 swift test` completed **216 tests: 209 passed, seven unrelated
skips, zero failures**. The native test actually used the official pinned packages
and packaged module: dependency install, provider replacement, native and base Undo,
profile capture, portable frame apply/Undo, later-edit conflict checks, local
adapter selection and generated shell syntax all passed. Packet-permission requests
were not executed by unit tests. App build completed, module SHA checks passed,
and whitespace/shell checks passed. The earlier actual ROM2/unchanged VM gameplay
proof is distinct from this package/ownership verification. The final managed ROM2
migration and launch are pending a closed game/unlocked Mac; do not mark installed
or claim a final managed-game retest before those steps are complete.

Additional preservation check: with the native-compatible Microsoft provider and
selected-interface backend in the disposable prefix, ordinary TCP/IP socket
bind/listen/connect/accept/send/receive passed. DirectPlay TCP initialization,
provider connection, session Open and CreatePlayer also passed and exited cleanly
after temporary packet permissions had returned to root:wheel 0600. No game was
interrupted. Pilot rollback exports/provider/manifest were copied into a durable
private game-state recovery folder while installation waits for the user, so a
temporary-directory cleanup will not lose its original network settings.

Upstream was rechecked immediately before final installation staging: v0.12.2 is
still the latest release; this working tree is based on its fast-forwarded commit.

## Managed rollout — 2026-11-02

After the user unlocked the Mac and closed ROM2, strict deep app-signature checks
passed again. The earlier trust error affected both old/new builds only while
locked; no trust setting or security bypass was changed. The old Nokcandu app was
retained outside the repo for rollback and the verified 0.12.2 update was installed
atomically. The temporary pilot's exports/hash/provider checks passed; its original
registry/provider and untouched launcher/settings were restored before using the
shared native installer. Native component installation then succeeded.

The first migration assertion incorrectly expected the fresh-install frame default.
The installer correctly preserved an existing Ethernet II value (1) from the old
UDP configuration. This was not an installer failure: components/profile validation
were present and valid. The migration explicitly selected the known-working 802.2
value (3) through `NativeIPXNetworking.setFrame`, retaining 1 as the original
component-Undo value. The actual profile contains both networking component IDs and
frame 3, passes validation/JSON round trip and excludes local adapter/module state.
Current character/saved-game files and allods2.exe still match the immediately
pre-migration fingerprints. Launcher syntax and --check pass. The updated UI shows
both networking components Installed, Wi-Fi (en0) and 802.2 (Windows 98).

The first normal Play attempt reached the native dialog and the user approved it,
but no packet access remained enabled and the game did not start. Do not record
that as a successful final launch. The original background helper discarded startup
errors. The corrected shared launch step embeds its administrator bootstrap before
authorization, creates a root-owned 0700 temporary directory, copies the lease
script into it, validates the copied SHA and only executes that protected copy.
It uses Bash privileged mode across the authorized handoff and waits for the lease
script's ready acknowledgment before returning. On failure, startup errors are
reported and the game stays closed. The detached lease forwards termination to its
child, restores permissions using the existing script and removes protected staging.
The exact reason the original background invocation stopped is not yet established;
loss of effective privilege was a hypothesis, not a verified diagnosis.

New unprivileged tests exercise the exact bootstrap with a harmless dummy lease:
startup detaches, staging is 0700, later edits to the original helper cannot affect
the verified copy, a hash mismatch is rejected, and staging is removed after exit.
The generated AppleScript compiles and shell syntax passes. No device permissions
are changed by these tests. The complete updated suite passed **217 tests total:
210 passed, seven unrelated skips, zero failures**. The corrected app was installed,
its signature verified and ROM2's managed launcher regenerated through the shared
API. The corrected normal Play permission prompt is now awaiting the user's local
approval; final managed launch/network retest remains pending that result.


## 2026-11-02: session lifetime and native authorization manager

The user correctly identified that a fixed 30-minute authorization window is
unsuitable for long matches. The earlier shipped shell lease is superseded by
`Resources/native-ipx/access.c`; the manually invoked diagnostic script retains
its explicit timeout. Production launch has no fixed timeout.

The ordinary launcher registers its own PID and process-start identity in a private
user session directory. After approval, a hash-verified root-owned copy of the
native manager acknowledges readiness through a pipe and detaches without a shell
background-job dependency. It grants only unchanged standard root-owned BPF device
nodes, records restoration intent before ownership changes, and keeps access while
at least one registered process remains alive. PID reuse, zombies, invalid start
identities and linked markers do not retain access. Original ownership is restored
after the last game exits. The game and Wine retain the normal user identity.
The public macOS process table is used when cross-user `proc_pidinfo` is denied;
otherwise a normal client could not verify the root manager's identity.

Unprivileged tests exercise two concurrent sessions, final-session cleanup,
invalid identities, symlinks and the exact protected-copy bootstrap. These tests
intentionally do not alter packet-device ownership. The production binary excludes
the test environment override. The full suite completed 219 tests: 212 passed,
seven optional tests skipped, zero failures. The signed app was verified through
normal macOS certificate access and installed with a recoverable previous-app copy.
A sandbox-only certificate lookup failure also affected the previous app; normal
signature verification passed without changing trust settings.

ROM2's unchanged owned launcher migrated through `HelperPatch.refresh` to revision
2; its existing registry recovery record, frame 802.2 and Wi-Fi selection remain.
Portable profile validation passes. Migration refuses manually edited launchers,
modified owned helper files and registry/environment conflicts. Undo uses the
original component journal, including the prior registry values; no game content
is part of this helper migration. The obsolete owned shell helper remains unused
until normal Undo removes it.

A normal Play attempt is now waiting for local approval. Actual privileged-manager
startup, game opening and automatic device restoration still need live verification.
Earlier manual-lease IPX gameplay remains verified independently of this final
managed launch flow. Do not describe that remaining check as complete.


## 2026-11-02: normal launch verified; adapter redaction regression

The user approved the session-based prompt and confirmed ROM2 opened. A live
read-only check returned ready from `native-ipx-access --check`; the detached
manager ran as root, ROM2 and wineserver as the normal account, and BPF ownership
was temporarily assigned to that account with mode 0600 unchanged. Final-session
restoration is still awaiting game closure. Discovery failed in both directions.

The actual game log showed IPX network `00000001`, whereas the gameplay-proven
pilot used `00000000`. The managed marker selected primary MAC
`020000000000` and zeroed that placeholder's network; the real capture interface's
old network remained 1. A minimal Foundation `Process` reproduction returned
`02:00:00:00:00:00` from `ifconfig en0`, while a normal shell and Wine's
`GetAdaptersInfo` returned the real capture MAC. Thus apparently valid ifconfig
output is insufficient for configuring native IPX on this Mac. The permission
manager did enable capture; this failure is a separate adapter identity defect.

The shared fix builds a small read-only Windows adapter enumerator from source,
fingerprints it in the native module manifest, and queries the game's Wine API
for the same name/MAC identity used by capture. Fresh installation and explicit
adapter changes reject the redacted placeholder. Existing installations migrate
only the unchanged owned placeholder-primary state while closed, preserving the
local adapter name, explicit frame, old registry Undo values and manual conflicts.
No game-specific workaround or VM change is involved. Ten focused native tests,
including the official-package installation test, redaction regression and guarded
migration/Undo, passed. Signed app build passed. Installation and actual discovery
retest remain pending a closed Mac game; no network success is claimed yet.


### Adapter correction installed; final network check pending

After the user closed Mac ROM2, the root manager exited, removed its state file,
and restored BPF0 to root:wheel 0600. This confirms the normal session cleanup,
independently of the concurrent-session unit test. The signed adapter update was
installed with a recoverable previous-app backup. `HelperPatch.refresh` corrected
the owned redacted primary to Wine's real capture identity and set its native
network to zero. The original primary Undo value remains all-FF; frame 802.2,
local Wi-Fi choice, current saves and the original game executable were preserved.
The exported profile still validates without local hardware/permission state.

The updated normal Play request is awaiting local approval and a Mac-host/VM-browser
retest. Do not infer discovery success from settings verification alone.


## 2026-11-02: adapter migration verified live; discovery still unresolved

The user confirmed ROM2 opens after the adapter correction, but no host appears.
The new game log confirms the real en0 capture MAC and IPX network zero. Live
module inspection confirms the private Microsoft provider and both managed wpcap
PE/Unix modules are loaded, with BPF0 open. This rules out repeating the earlier
placeholder-primary explanation for this latest attempt.

Using the exact installed module in the isolated diagnostic prefix, all three
native-capture event/send/receive/close cycles passed. A native AF_IPX socket
loopback also passed; an independent en0 trace decoded its outgoing LLC 802.2
IPX frames with network zero. This verifies local packet operation, not peer
connectivity or ROM2 session discovery.

Early short capture windows may have missed asynchronous user refreshes and are
not evidence against the VM. A subsequent continuous, non-promiscuous IPX-only
trace was active before the request and remained active through the user's
“Refreshed now” reply. It recorded no peer IPX frames. The previously guessed
VM IPv4 address did not answer two pings; that alone does not prove a bridge
failure or even that the address is current. The successful earlier pilot had
visible VM discovery broadcasts on this same Mac interface.

Jump Desktop showed the VM's running ROM2 game browser, but attempted input
returned noWindowsAvailable. No guest game, DLL, network or provider settings
were changed. All diagnostic captures were stopped. The next requested evidence
is the VM's current attachment mode, selected physical adapter and virtual cable
status, inspected without changes. The external path remains a hypothesis;
normal managed IPX discovery is still unresolved and must not be marked fixed.


## Final managed retest: both hosting directions confirmed

The user found that restoring the Windows 98 VM from a snapshot had reverted its
network attachment to NAT. After returning the VM to bridged networking, the user
reported it was “fully working” and could see and join games hosted in either
direction. This resolves the missing peer IPX packets observed during the continuous
trace. The bridge diagnosis is now confirmed rather than inferred from silence.
No VM game/system DLL replacement was needed.

Verified final scope: normal Nokcandu launch with local administrator approval,
correct Wine-visible adapter identity, native IPX LAN discovery and joining with
unchanged Windows 98 ROM2 in both hosting directions, and restoration of temporary
packet-device ownership after the game closes. Actual gameplay was separately
confirmed in the earlier Mac-hosted test. Long-match support has no fixed timer;
concurrent-session lifetime and last-session cleanup are covered by the helper
tests, but a multi-hour match was not run. Other eligible games use the shared
feature and profile component, but each game's interoperability still requires its
own gameplay test. Native SPX and Wine 10 runtime support remain outside the
verified scope.

Troubleshooting: inspect VM network mode after restoring snapshots. Same IPv4
subnet or working TCP/IP does not establish native IPX bridging. A NAT attachment
must not be treated as evidence of a Mac provider failure. Keep the Mac's native
frame compatible with the peer (802.2 in this test). Saved/shared profiles carry
the optional component and frame; local adapter selection and packet authorization
are resolved locally and are never granted by importing a profile. Normal component
Undo retains the original file/registry recovery records, including migrated ones.
