# LAN discovery investigation — 2026-11-01

Status: LAN browsing resolved by user-confirmed Windows host adapter change. No shared Wine networking defect established. The separate Internet-browser issue remains open.

## Report and affected scope

The user reports that Battlefield 1942 can join a Windows 11 LAN host by address, and other players can discover and join the Mac when it hosts. The Mac cannot list the Windows-hosted game. The report may affect more games; no other title was reproduced in this investigation. Joining and discovery must be tested separately.

## Verified evidence

- The Mac firewall is disabled. Its default route and limited-broadcast route use the active Wi-Fi interface; its IPv4 address and the supplied Windows host are on the same /24 LAN. The host answers ping.
- A temporary diagnostic library, added only by a scratch copy of the existing launcher, observed Battlefield send an eight-byte UDP message to `255.255.255.255`, ports 22000 through 22010. `sendmsg` returned 8, without a socket error.
- A separate native UDP listener bound to 22000 received repeated queries from the Mac's Wi-Fi address. The bytes were exactly `5c7374617475735c` (`\status\`). This verifies local delivery and the query format, not delivery across the Wi-Fi access point to Windows.
- No discovery replies appeared in the socket trace. Independent native queries to the supplied Windows host's discovery ports also got no response. Both limited broadcast and /24 directed broadcast were compared with direct unicast; no query response was observed. An additional unicast/broadcast comparison of port 23000 also produced no reply.
- The Windows host is running Battlefield in a hosted match (visible through the user's existing Jump Desktop session). Switching away from the game produced a black remote view; no host firewall or game configuration was changed.
- A read-only Windows `Get-NetUDPEndpoint` check for ports 22000–22010 was requested. Its result is still pending.

These observations do **not** prove a Wine broadcast translation defect. Socket-send success and self-receipt do not establish on-wire delivery. Silence does not distinguish host binding/configuration, host firewall, Mac network filtering/privacy, or network transport. Direct IP gameplay success does not prove that the separate discovery endpoint is reachable.

## Next discriminating tests

1. On the Windows host, while hosting, inspect `Get-NetUDPEndpoint | Where-Object { $_.LocalPort -ge 22000 -and $_.LocalPort -le 22010 } | Format-Table LocalAddress,LocalPort,OwningProcess`. Identify the owning process and whether the socket is bound to the LAN adapter or all IPv4 interfaces. No socket implies a host-side discovery setup issue rather than a Mac browser fix.
2. If a listener exists, compare a bounded capture at the host with the observed query. Check exact program/path, network profile and inbound UDP rules; do not disable the firewall globally as a diagnostic shortcut.
3. If Windows receives the query and sends an answer, follow that answer back to the Mac. If Windows never receives it, compare native versus Wine and unicast versus broadcast using captures on both ends.
4. Check macOS Local Network settings under the responsible game's/launcher's identity if packets are blocked. Existing archived preference records include multiple identities and historical records; they are not a reliable current-permission API and were not modified. App purpose strings are absent for local networking; that is an observation, not a demonstrated cause of this failure.
5. Verify the actual server appears in Battlefield's Local browser after any correction, then confirm joining still works in both directions. Repeat on another affected game before claiming shared renderer/runtime scope.

## Reusable diagnostic and validation

[Tools/lan-discovery-probe/query.py](../../Tools/lan-discovery-probe/query.py) uses only Python's standard library and sends the observed GameSpy v1 `\status\` query to ports 22000–22010 on an **explicit** host/broadcast address. It prints only reply source and byte count, not server/player payloads. It does not scan host ranges, relay traffic, alter a firewall, or write game files. This protocol is scoped to GameSpy v1/Battlefield 1942; do not apply it to Bonjour or unrelated games as if all discovery were the same.

Run `python3 Tools/lan-discovery-probe/query.py <host-ip>` and compare with the appropriate LAN broadcast address. Silence is deliberately reported as inconclusive. Two local UDP tests passed: exact query/reply socket handling, and silent endpoint timeout. These are diagnostic tests, not proof of successful LAN browsing.

## Preservation, migration and Undo

No game binary, save, explicit setting, installed launcher, privacy preference or firewall rule was changed. No installation migration is warranted yet. The diagnostic trace is temporary and loaded only by the scratch launch; normal launching returns to the original installed launcher. Exit the diagnostic game before removing the scratch trace library because Wine may inherit it for child processes. Machine-specific trace logs and compiled diagnostic libraries must not be committed. The new repository tool and documentation are the only durable additions.

Avoid repeating: changing graphics for a discovery-only failure; treating Bonjour bridging as a GameSpy broadcast fix; claiming that successful `sendmsg` proves receipt at the other PC; broad firewall disabling; forcing an adapter or broadcast rewrite without a captured failure.

## Follow-up: host monitor and Internet scope

The user ran a PowerShell monitor before reopening the Windows host. It samples UDP 14567, 22000–22010 and 23000 with bind address/process name. Another native query against the running host still returned no discovery reply; the host was then closed to inspect its CSV. The user suspects Windows is using a virtual Ethernet adapter; this is a hypothesis until the recorded bindings and IPv4 interface table are compared. Do not disable virtual adapters on that inference (the machine is remote-only).

The added Internet-browser complaint has a separate confirmed stale master hostname and a tested BF1942-specific copy correction. See [Internet investigation](bf1942-internet-browser-2026-11-01.md); its success must not be reported as a LAN discovery fix.

## User-confirmed LAN resolution

The user disabled the Windows host's virtual Ethernet adapter and reported that the Mac can now see the Windows-hosted game. This successful before/after comparison establishes involvement of the Windows virtual-adapter configuration. The exact discovery socket binding/routing mechanism was not captured, so do not claim a proven first-adapter selection bug. No Wine broadcast rewrite or Mac firewall change was needed. Previously reported direct joining worked in both directions; joining/gameplay after the adapter change were not separately retested here.

For affected installations, first compare the host's physical/virtual interfaces and discovery listener bindings. Do not automatically disable virtual adapters on fresh installs or migration; they may support other software or remote access. This user-applied host setting has no Nokcandu installation migration. Undo is re-enabling the same Windows adapter, which may restore the original discovery failure. A game-specific physical-interface binding, if supported, remains an untested alternative. Other games have not been verified.

The user separately tested the installed Internet hostname correction and still reported an empty Internet list. Keep that failure open; the LAN resolution does not validate the Internet fix.

The subsequent two-slot Internet correction was also user-confirmed successful: Internet servers now appear. Both browsing symptoms are resolved by different changes; public-match joining and post-change LAN joining/gameplay remain untested in this session.
