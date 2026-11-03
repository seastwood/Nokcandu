# Wine server closed-socket readiness (2026-11-02)

## Scope and diagnosis

Shared macOS Wine networking infrastructure, not a BF2-specific DNS/port override. BF2Hub's account exists and the user can log in on its website. The game can establish its login TCP connection and receives data, but remains on the account screen. A separate closed HTTP connection was observed alongside it. See [the preceding account investigation](bf2hub-account-connectivity-2026-11-02.md) for rejected tracing attempts and restored startup.

[Krauzi's WineHQ report and source patch](https://forum.winehq.org/viewtopic.php?t=42859) describe the same macOS condition. A graceful close may be reported as `POLLPRI|POLLHUP` when urgent events were requested, or as an error despite no socket error. Wine translates this to Winsock's exception set. The statically linked GameSpy HTTP state machine can then remain waiting. The author supplies a server patch; another poster reports working BF2Hub login after applying it. Those reports motivated testing, not an assumption that this installation was fixed.

## Independent reproduction and implementation

An isolated Windows executable connected only to a local synthetic responder in a scratch prefix. With the unchanged engine, a normal 40-byte response followed by FIN produced `select=2 readable=1 exceptional=1`, both before draining and at EOF. The received response and normal zero-byte EOF were intact.

`Resources/rawmouse/socket-events.c` normalizes that event at the native `poll` boundary **only inside an executable named wineserver**. Nokcandu's existing helper was verified already mapped into its server, so no Wine engine executable, request protocol, synchronization implementation or graphics driver is replaced. The code uses non-consuming `TCP_CONNECTION_INFO` to require `CLOSE_WAIT`, checks for real urgent data with `MSG_OOB|MSG_PEEK|MSG_DONTWAIT`, then maps the false error/urgent indication to readable while keeping hangup and other events. Unexpected socket/query failures are left unchanged. `SO_ERROR` is never consumed; errno and poll's return count are preserved. Game processes forward the original poll call without extra socket inspection. There are no endpoint names, account fields, packet logs or network payload recordings in production code.

The author's source fix also changes Wine's server error mapping more broadly. This implementation intentionally limits normalization to confirmed graceful TCP half-closes; reset/error handling outside that condition remains the engine's existing behavior. Guessed masks that removed only POLLERR or POLLHUP did not fix the reproduction; identifying Darwin's `POLLPRI` bit was essential. Do not repeat generic “clear all socket errors” workarounds.

## Verification

- Complete production helper: 32-bit and 64-bit Wine 11 normal close now reports `select=1 readable=1 exceptional=0` before draining and at EOF, with the same 40 response bytes.
- Supported Wine 10.0-8 runtime: the same 32-bit production-helper test passed.
- Refused connection still reports exceptional readiness and WSA error 10061.
- Genuine urgent data sent before FIN remains exceptional; normal response data remains readable.
- A real reset remains visible as WSA error 10054.
- Hardware-free boundary tests check that game processes, non-sockets, short socket-information responses and unexpected errors are unchanged; errno is preserved.
- Full suite: 249 tests, ten optional skips, zero failures. The signed development app passed deep/strict signature verification.

After activation and a full private-session restart, the user confirmed BF2Hub login completes and multiplayer servers appear: “it works, i got in and i can see games!” The user subsequently confirmed joining an Internet multiplayer match and running around in it. Login, server browsing, joining and basic multiplayer gameplay are verified; a sustained session and all anti-cheat/server configurations have not been tested.

## Fresh installs, migration, profiles and Undo

The correction is built into the same centrally generated audio/input helper for standalone, recipe, Steam, Battle.net, EA and Ubisoft Wine environments. Existing installations use the existing hash-verified, atomic helper migration and Repair paths. Their explicit engine, renderer, launch options, manually edited launchers, content and saves are preserved. Native Mac games do not use this Wine correction.

A server already mapping the older helper keeps that code until the complete Windows environment closes. Quit the game through Nokcandu; shared games require quitting their client through Nokcandu too. Repair now explains this activation requirement. The targeted BF2 test restarts only BF2's private prefix, not other games.

Profiles require no new game-specific switch or secret: imported/created installations receive the current shared helper, while existing profile settings remain unchanged. No global hosts, DNS, firewall, router or account settings are changed. Restoring the previous app/helper and restarting that private environment undoes this correction. Runtime rollback copies stay local and are not committed.

Portable optional tests are in `Tools/socket-events/`; only source, tests and documentation belong in the repository. The WineHQ patch download was inspected as source, not executed as software.

## Activation

After the user closed BF2, the signed development app was installed atomically with a local rollback copy retained. The private BF2 environment had no remaining owned processes. Normal helper migration installed the tested library; its SHA-256 matched the installed app’s bundled helper before BF2Hub was launched. A before/after checksum confirmed BF2’s saved game.json was unchanged. BF2Hub was started through the original Nokcandu entry for the user’s normal BF2Hub Play/login test. The user subsequently confirmed successful account login and a populated multiplayer/server browser.

## Confirmed result

The installed shared correction resolved the reported BF2Hub account-screen hang without changing the account, BF2Hub modules, game executable, engine choice, renderer, hosts file or firewall. BF2 continued through BF2Hub’s normal Play route. The user confirmed login, visible games, joining an Internet multiplayer match and moving around in it. Do not extend that result to every anti-cheat configuration or sustained-session reliability without a separate test.
