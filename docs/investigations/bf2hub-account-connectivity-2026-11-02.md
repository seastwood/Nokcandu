# BF2Hub account connection investigation (2026-11-02)

## Status and scope

**Resolved for login and server browsing:** the shared wineserver closed-socket readiness correction was installed after the investigation below. The user confirmed successful login and visible multiplayer games. See [the confirmed correction](wineserver-closed-socket-readiness-2026-11-02.md). The user later confirmed joining an Internet multiplayer match and running around; basic gameplay is verified, while extended-session reliability remains untested. The following records the initial indefinite connection/creation investigation. Keep the working engine, renderer, BF2Hub Play route and saved settings intact. The displayed profile was identified by BF2Hub as single-player; whether a verified multiplayer account exists is a separate question from green client/CD-key readiness checks.

## Verified checks

- BF2Hub's client readiness indicators were green. The user launches BF2 through the BF2Hub GUI's Play Battlefield 2 button, which is the [official documented route](https://www.bf2hub.com/home/maintenance.php).
- The stalled game's socket to `5.252.33.100:29900` was TCP ESTABLISHED. Socket statistics showed both sent and received bytes, including a small unread receive queue. This rules out a complete TCP-connect block to that endpoint; it does **not** establish successful authentication or account creation.
- A separate credential-free native socket received a 38-byte GameSpy login challenge from that address. TCP 29901 also accepted a connection. No credentials, account queries or creation requests were sent by these probes.
- The guessed public names `gpcm.bf2hub.com`, `gpsp.bf2hub.com` and `login.bf2hub.com` resolved to a different address whose tested account ports timed out. This does not prove those names are the correct current endpoints for this installed client. Do not replace the observed working TCP endpoint with a guessed address or add global hosts overrides.
- No relevant redirect was present in the Mac hosts file or the game's private hosts file. The actual endpoint was learned from the live game socket, not assumed from obsolete GameSpy strings in BF2.exe.
- Downloaded the [official BF2Hub 1.8 installer](https://www.bf2hub.com/home/downloads.php) for offline extraction only. Its SHA-1 matched the published `91bb4f5fcc0481f57d72231ccc7d5e8fb676401d`. Installed `bf2hub.exe`, `bf2hub.dll` and `bf2hbc.dll` matched the extracted official copies byte-for-byte. The game's two modules matched the client's copies too. No installer was executed and no game module was replaced.
- The [official client help](https://www.bf2hub.com/clientcode/2400) documents UDP 29940 for the client's account checks. That is not interchangeable with the game's TCP login connection. No firewall, router or port-forwarding settings were changed. Its static status page reports normal operation, but does not validate a particular account transaction.
- BF2Hub's [Webclient documentation](https://www.bf2hub.com/home/webclient.php) distinguishes creating/verifying an account from CD-key backup/readiness. The public page was read only; no user credentials were requested, stored or submitted by the agent.

## Failed diagnostic comparisons and recovery

An experimental native network interposer was limited to TCP 29900/29901 and whitelisted command names, lengths and numeric error codes. A local synthetic-credential test verified its output omitted the synthetic secret. It was not a packet capture and did not save payloads.

The first test launched BF2.exe directly from a temporary alternate native entry instead of BF2Hub Play. That changed the user's known working route and startup crashed; do not repeat that comparison as equivalent to a BF2Hub launch. The original launcher script was never edited, and original app metadata was restored byte-for-byte immediately after the launch request. The extra interposer was not confirmed loaded in the eventual BF2 process.

A second test combined the tracer with a temporary copy of BF2's private shared helper so BF2Hub Play could be used normally. Startup crashed again before any account exchange was traced. Its log contained only module-loaded markers. The provided crash excerpt stopped at `RendDX9 + 0x74ee1` (`int3`); the accompanying graphics log reported failure to enter fullscreen at **800×600 @ 85 Hz**. This is a rendering startup failure, not evidence of a blocked account port. The precise cause of the diagnostic-era rendering regression was not isolated.

The exact pre-diagnostic helper was restored atomically, original app metadata verified, and the temporary launcher removed. With BF2 closed, only BF2's private Wine session was stopped; other games were left alone. Nokcandu reopened the original BF2Hub launcher. The user then confirmed **“Menu opens normally.”** Stop invasive tracing here; retain the restored startup baseline. No engine, renderer, saved display choices, account files, game content or saves were changed as a proposed fix.

## Next discriminating checks

Establish whether the login is for a previously verified BF2Hub multiplayer account or a first account. A successful Windows/website comparison with the same account would help separate service/account failure from Wine-specific behavior. Credentials must stay local to the user. Do not infer authentication success from the tray/client readiness state, TCP establishment or a public server challenge.

At this earlier stage there was no confirmed shared fix to distribute; the later shared helper correction and its migration are documented in the linked follow-up. The temporary diagnostic has been removed from the installed game; returning to the original helper and restarting the private session restored startup. Preserve that baseline while the account issue remains unresolved.

## Follow-up: account and socket isolation

The user confirmed this is a new account that successfully logs into BF2Hub’s website. A subsequent isolated test reproduced the Wine/macOS closed-socket exception bug. See [the shared readiness correction and independent regression results](wineserver-closed-socket-readiness-2026-11-02.md). The earlier no-confirmed-fix statement above describes the pre-reproduction baseline; the user subsequently confirmed BF2Hub login and visible multiplayer servers after activation.
