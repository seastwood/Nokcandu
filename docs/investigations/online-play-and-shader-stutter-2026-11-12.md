# Online play (CS2, Overwatch): priorities, sync and shader stutter — November 12, 2026

User report: Overwatch plays very well until a fight, then hitches continuously as shaders load; CS2 has network jitter. Solo games are fine, so something specific to multiplayer. Asked whether esync/msync is in use.

## Verified

- **msync is on and working.** Every launcher exports `WINEMSYNC=1`; the Steam and Battle.net logs show `msync: up and running` on each start, and the engine's server contains the msync code. (esync is the Linux mechanism; msync is its macOS counterpart and the one that applies here.)
- **Overwatch uses DXMT v0.80-244 with shader IR release on.** Its log reports over 131,000 shaders created with IR released and about 1.4 GB of DXBC kept. That option is what keeps Overwatch inside 16 GB.
- **DXMT's caches exist and persist**: `$(getconf DARWIN_USER_CACHE_DIR)/dxmt/Overwatch.exe` holds `shaders_320.db` (119 MB, converted shaders) and Metal's own pipeline cache (169 MB), both written during the last session and kept since November 6.
- DXMT has no option for background/asynchronous pipeline compilation or pre-compilation (config file and binary strings checked; release notes read). Upstream's notes say the cache "builds as you play": each new hero, skin, ability and map compiles once.
- **Store clients were being run as background work while a game was in front — including the game's own client.** `priorities.m` set `PRIO_DARWIN_BG` on steam.exe, steamwebhelper, Battle.net, Agent and the others whenever any game was in front. On macOS that lowers CPU priority and also throttles the process's network and disk I/O.
- **wineserver had no priority of its own**, while the game's threads ask for user-interactive.
- Network path on this Mac: Wi-Fi (5 GHz, strong signal); a USB Ethernet adapter is attached but inactive. An earlier 15-minute sample with AWDL up showed router ping spikes of 20–35 ms every 10–60 s. The AWDL guard (off while a game runs) is installed.

## Changed (shared, for every game in a store client's environment)

1. The game now records its Wine environment beside its process id in `game-in-front`. A store client in that **same** environment keeps normal priority; clients in other environments step back as before. Older helpers read only the first line and behave as before. Pure decision code in `launcher-priority.h`, tested in `test_launcher_priority.py`.
2. wineserver sets user-interactive QoS at start and again after it forks into the background.

Both are in the helper library, so existing games pick them up through the normal helper update the next time they start. Undo for (1): Settings → "Lower store apps' priority while a game is in front" off restores every client to normal; there is no switch for (2).

## Hypotheses, not yet confirmed in a match

- CS2's jitter and multiplayer-only hitching come at least partly from waiting on a throttled Steam client (game coordinator, matchmaking and voice go through it) and on a de-prioritised wineserver. **Needs a before/after in a real match.** To compare without reinstalling: turning the Settings switch off gives the same result as (1) for the game's own client.
- Overwatch's fight hitching is first-time pipeline compilation that DXMT cannot move off the critical path; it should lessen as the cache fills and return after a DXMT update (the cache is versioned) or a game patch with new shaders. The priority changes may shorten each hitch but cannot remove them.

## Not done

- **Moving DXMT's cache to a location macOS won't purge.** The binary has `DXMT_SHADER_CACHE_PATH`, but its exact meaning is undocumented and a wrong value would throw away 290 MB of warm cache. The default location is purgeable under disk pressure (the startup disk is 87% full), so this is worth doing once verified with a test program.
- Wi-Fi itself: Ethernet removes the periodic spikes; that is a setup choice, not code.

## Fresh installs and migration

Fresh installs get the new helper. Existing games update the helper when idle, as usual. No game files, settings or caches are touched.

## Follow-up, November 12 (night)

### Measured while Battlefield 1942 / 2 were running (AWDL guard active, AWDL down)

- Router (Wi-Fi hop): 150 pings, average 3.9 ms, maximum 28.6 ms, standard deviation 3.8 ms.
- Internet (1.1.1.1): 100 pings, average 33.5 ms, **maximum 172 ms, standard deviation 27 ms**. The jitter is mostly beyond the Mac's Wi-Fi link: router queueing or the provider. Not yet known whether it lines up with CS2's.
- `netstat`: **1,728 UDP packets dropped because a receive buffer was full** since boot (macOS default UDP buffer 768 KB). None in a 20-second window with no online game. Which program dropped them is not known.
- A recorder now runs in the background for the next CS2 session (drops, router and internet latency, CS2 and wineserver CPU, queued UDP bytes every ~2 s). **No conclusion about CS2's jitter until that data exists.**

### Battlefield 2 performance — a shared cause found

BF2 runs DXVK 3.1.1 (gplasync) on KosmicKrisp. Every DXVK game's launcher forced `d3d9.maxFrameLatency = 1; dxgi.maxFrameLatency = 1` (since 0.9.0), so the CPU waits for the GPU each frame; the Performance → Low-latency Aiming option, meant to be the opt-in for exactly that, was therefore always on in effect. Changed: the renderer lines no longer set frame latency; the option still does. Existing unmodified launchers are rewritten by the existing idle-only launcher upgrade (Undo through the change history); edited launchers keep the old line. **The frame-rate gain is expected, not measured** — BF2 was running and couldn't be compared. KosmicKrisp itself (an experimental Vulkan-on-Metal driver) may also limit performance; DXVK through MoltenVK is the comparison to try next if BF2 is still slow.

### Paused, November 12 (late)

CS2 network investigation paused at the user's request before any in-match data was recorded; the background recorder was removed unused. Nothing about CS2's jitter is concluded. Starting point when resumed: record a CS2 online match (UDP full-buffer drops, router and internet latency, CS2 and wineserver CPU every ~2 s) and compare with the internet-side jitter measured above.

Battlefield 2 performance is also paused. Measured so far: under 10 FPS, down to about 2, in busy scenes on DXVK 3.1 + KosmicKrisp with frame latency left to DXVK (the shared fix in 0.12.18); MoltenVK (DXVK 1.10 / D9VK 2.3) made the menu slower; dgVoodoo2 + DXMT crashed at start (below). Next step when resumed: measure CPU and GPU in a busy scene to tell a Rosetta/CPU limit from a GPU or translation limit.
