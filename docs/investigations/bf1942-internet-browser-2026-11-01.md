# Battlefield 1942 Internet browser — 2026-11-01

Current status: user confirmed Internet servers appear after the two-slot correction. Public-match joining/gameplay has not been retested. Earlier failed checks below are retained as investigation history.

## Confirmed cause

The installed verified BF1942 source and both managed menu/mod-restart copies contain `master.bf1942.sk`. A live DNS lookup failed for this hostname. `master.bf1942.org` resolved and TCP 28900 returned the expected 21-byte GameSpy secure challenge. This establishes a concrete obsolete-directory endpoint defect, independent of the still-open LAN discovery investigation. It does not establish that every public game is joinable.

The community master implementation's [client demo](https://github.com/Ahrkylien/BF1942-Master/blob/main/client_demo.py) explicitly queries `master.bf1942.org`; its [README](https://github.com/Ahrkylien/BF1942-Master) documents TCP 28900 and UDP 27900. A [server operator's explanation](https://jdrgaming.com/using-the-bf1942-in-game-server-browser/) distinguishes the master list from direct-address joining and reminds players to click Update. Endpoint liveness is a dated observation, not a permanent guarantee.

## Change and scope

Extend the existing built-in BF1942 managed-copy recipe with the hostname correction. At offsets `0x557c30` and `0x557df8`, replace each exact padded `master.bf1942.sk\0\0` slot with `master.bf1942.org\0`. Each slot occupies 18 bytes. Six bytes change across the two slots; executable length, sections, unrelated strings and authentication code remain intact. Full-file fingerprints precede mutation, and the final output must match a hardcoded expected digest. The original game executable is never written or distributed.

Source/derived fingerprints:

- Original verified source: `3a3eab9af4ad711f9faf6a17d8e31a3bacbbace99fe8356a700e1071c143cd7f`
- Earlier menu-only source: `3b8033a58197ee844f4c4238b0bb873d1fcc6ba0a0f918b4fb247c9ac1ee01f2`
- Menu + mod-restart output (superseded): `e3b58cc22cd5d638b3d915cf3527b2af700f98dc97e2d6b6373601f4c3204801`
- First hostname attempt (incomplete; only one slot): `d6d283cd4982abfdd6b52950afae40b5bcaf1f287b81fe59d0cb11124082f975`
- Current output (both hostname slots): `6496982e7a2b693bb6f0cce53cadbcabf6d362c6762448d03dd9b27282c6b51f`

This is deliberately BF1942-specific. No global hosts-file edit, DNS override, Wine network hook, adapter preference, broadcast rewrite or firewall change is introduced. Other games require their own server-directory evidence; Bonjour discovery is a different protocol.

## Fresh install, migration and preservation

Applying the recommended BF1942 setup/menu correction creates the corrected main and mod-restart copies through the existing journal. Existing managed copies migrate through both generated-launcher maintenance and HelperPatch maintenance while the game is closed. This prevents the new launcher from requiring a fingerprint that its copies do not yet have.

Migration requires the saved launcher fingerprint to match the actual launcher, a recommended recipe receipt, a journal-owned copy, allowlisted current copy hashes and a valid journal. Unknown sources or edited files are refused before replacement. Resolution, graphics, launch arguments, environment settings, original executable, saves and unrelated game files stay intact. The old copy hashes remain accepted as migration inputs. The generated launcher accepts the known source generations but requires the current generated-copy digest at launch. Interrupted migrations retain their file journal and can be retried.

Undo uses **Undo BF1942 Display Settings**, because the hostname correction is part of that managed-copy recipe; the UI explains that it also restores the Internet browser. Undo removes/restores only recipe-owned files/settings using existing conflict-aware behavior. This is a combined recipe Undo, not a claim of an independent Internet-only toggle. Keep the original executable available as before.

## Validation and remaining checks

`swift test` completed 203 tests, 6 skipped, zero failures. Tests cover the exact padded slot, byte count and changed offsets, rejection without full-file verification, all verified source generations, idempotence, migration of both copies, resolution/config preservation, file-journal Undo, and refusing migration when the launcher was manually edited. The installed source is read conditionally as a local regression fixture; it is not copied into the repository.

The initial targeted run caught two test-fixture gaps after adding the manual-launcher guard and an obsolete five-byte-only assertion; fixtures now supply a hash-verified managed launcher and allow precisely the three additional hostname bytes. No guard was weakened to make the tests pass.

Live Internet-browser population and joining a public match remain to be verified after installing the tested correction. A successful master handshake alone does not prove either. LAN discovery remains separate, with a Windows virtual-adapter/binding hypothesis awaiting the host's recorded port and adapter results. See [LAN investigation](lan-discovery-2026-11-01.md).

## Installed validation — first attempt (superseded)

After the passing full suite, built and signed the app, quit the older Nokcandu process, stopped only the Mac diagnostic game process created for this investigation, and installed the tested app update. Invoked the normal journaled copy/launcher migration for the existing BF1942 installation. Both generated copies now match `d6d283cd4982abfdd6b52950afae40b5bcaf1f287b81fe59d0cb11124082f975`; the original remains `3a3eab9af4ad711f9faf6a17d8e31a3bacbbace99fe8356a700e1071c143cd7f`. The regenerated launcher matches its saved fingerprint. Program selection, graphics, display-pixel setting, launch arguments and environment compare equal before/after migration. Restarted the updated app and launched Battlefield through its normal Play action; renderer startup succeeded. The user was asked to verify Multiplayer → Internet → Update. Server-list population and public joining are still pending that check.

## Failed live browser check and ongoing diagnosis

The user selected Internet → Update after installation and reported that the list remained empty. The installed hostname correction is therefore not a complete verified fix. A subsequent independent native client performed the documented GameSpy master-list request and received 509 encoded response bytes after the 21-byte challenge. The community endpoint can return list data from this Mac, but the game’s own request/response and decoding/filtering path still need comparison. A new temporary diagnostic records only master DNS names, endpoint addresses, socket results and lengths (no payloads or account/session fields). It is loaded by a scratch launcher, not installed into the runtime.

The LAN portion is now user-confirmed working after disabling the Windows virtual Ethernet adapter; this does not establish Internet-browser success.

## Second hostname slot: confirmed reason the first correction failed

The temporary native trace recorded `gethostbyname(master.bf1942.sk)` failing inside the running corrected game. Scanning exact hostname occurrences then found two source offsets, not one: `0x557c30` and `0x557df8`. The first correction had changed only the first; the old hostname remained in the generated executable and was still used by the browser. A unique **set** of extracted hostname strings had hidden the duplicate. Avoid repeating a first-match-only replacement or assuming that one changed slot proves every runtime reference changed. The source now validates both padded slots before changing either and verifies the final full-file fingerprint. Regression checks require no obsolete hostname anywhere in the generated image.

The user also reports that Windows can populate the Internet list using the same game folder. That is a useful working control, not evidence that the Mac’s observed failed lookup did not occur. Windows resolver/hosts settings and actual program selection were not compared, so the exact platform difference remains unknown. Public Google DNS returned status 3 (NXDOMAIN) for the old name and status 0 with an A record for the replacement, agreeing with the Mac’s native resolver failure.

The revised full suite passed 203 tests, 6 skipped, zero failures, before installation. Both old menu-only copies and the first hostname attempt are supported migration inputs. Built/signed and installed the revision, then migrated both owned copies with original/settings preservation checks. An immediate attempt while the diagnostic process was still exiting did not pass migration completion; retry after exit succeeded. The migration did not bypass the running-game protection. Current installed copies use digest `6496982e7a2b693bb6f0cce53cadbcabf6d362c6762448d03dd9b27282c6b51f`. Live browser validation of this revision is ongoing.

## User-confirmed successful browser result

After installation of the two-slot revision, the user retried Multiplayer → Internet → Update and reported **“Servers appear now.”** This supersedes the first-attempt empty-list result for the current correction. Internet server-list population is now verified in the actual installed game. Joining a public server, gameplay, and mod-switch/restart after this revision have not been separately retested. The original executable and explicit game settings remain preserved as documented above. The correction applies through the built-in generator and protected migration to all supported, verified BF1942 installations with the managed menu recipe; no global resolver override is needed.
