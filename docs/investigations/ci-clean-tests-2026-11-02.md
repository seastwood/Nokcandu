# Clean-runner CI test dependencies — 2026-11-02

## Failure evidence

[GitHub Actions run 41463729782](https://github.com/seastwood/Nokcandu/actions/runs/41463729782/job/125339036080)
failed on main commit `4cf2429` in the Test step, before app packaging. It ran 221
tests, skipped 15 optional tests and reported three failures in NativeIPXNetworkingTests:
adapter selection, redacted-adapter migration and Wine adapter identity. Each
failure came from an absent bundled adapter reader on the clean runner. This Mac's
prebuilt native module had hidden that unit-test dependency.

## Correction and scope

Those tests already use a fake Wine executable that returns controlled adapter
identities. They now explicitly provide a private temporary packet-package fixture
and its manifest instead of reading the developer's built app. Adapter selection
uses the fixture LAN identity rather than a live host NIC. Official runtime/package
interoperability tests remain separately opt-in and continue to use verified real
packages; this correction does not replace those with fabricated binaries.

New native launcher-entry tests likewise compile their tiny helper from source in
a private temporary directory. No prebuilt app, real game, engine download or
committed runtime binary is needed to test migration, argument forwarding, receipts,
helper upgrades and Undo. Production package validation and fingerprint checks are
unchanged. CI also syntax-checks the newly added shell build/diagnostic scripts.

## Verification and Undo

The fifteen focused native-IPX/entry/startup tests passed locally with one optional
runtime test skipped. A fresh source copy, without build/, .build/ or engine caches,
passed the same test-then-ad-hoc-build sequence as CI; see the result below. The earlier failure is not marked
resolved solely because the cached developer tree passes.

This is test isolation, not a game-state migration. Undo is reverting the test and
CI-source changes; no user content or permission state is altered.


### Fresh-tree result

A separate source-only tree, with no build/, .build/ or engine caches, passed all
226 tests with eleven optional skips. Its subsequent `build-app.sh` completed with
ad-hoc signing and no packet module, matching the normal CI build order and optional
asset configuration. No production native-IPX checks were relaxed to obtain this
result. Remote verification is tracked in [CI run 41490271011](https://github.com/seastwood/Nokcandu/actions/runs/41490271011); check the remote result independently of the developer tree.
