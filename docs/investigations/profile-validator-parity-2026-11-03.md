# Profile validator parity — 2026-11-03

## Confirmed failure

Profile issue 22 in Nokcandu-Profiles was rejected with only “unknown fix”. Its settings included the newly supported `bf1942-software-audio` ID. The app accepted/exported that component, but the companion catalog allowlist had not been updated. This was an integration omission, not a malformed user sound setting.

## Correction and evidence

Companion commit `8005d70` adds the built-in ID, names unknown IDs in errors, safely rejects non-string fix entries and supports explicitly revalidating an existing issue with workflow_dispatch. Nine companion unit tests passed. The app-side parity/round-trip tools confirmed all 13 built-in fix IDs, rejected unknown IDs and preserved native IPX frame validation. The existing issue was revalidated through its normal workflow, without rewriting its submitted profile. Runs 41771204166 and 41771204849 succeeded; issue 22 now carries profile-valid, its validation comment says Published, and the public catalog contains the issue. No account/session data or profile body is committed here.

App CI now reads the trusted companion validator allowlist as source data and compares it with the app enum. This check does not execute downloaded validator code. A future app/catalog fix-ID mismatch fails validation rather than silently shipping.

## Scope, migration and Undo

Fresh and existing submissions use the updated validator. Existing invalid submissions can be revalidated without recreating an issue. The correction changes no game files, permissions or app settings. It does not make arbitrary DLLs or unknown fix names valid. Reverting the allowlist addition would again reject profiles using the new built-in component; the diagnostic improvement can remain independently.
