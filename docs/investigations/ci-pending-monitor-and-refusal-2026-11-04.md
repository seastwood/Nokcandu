# CI pending-monitor crash and refusal probe — 2026-11-04

## Report and scope

GitHub CI failed after two pushes that had passed local checks. Run 41833477386 reached the real Wine Winsock matrix and failed Wine 10 x86_64 refused-connection validation. Run 41836696349 instead crashed the XCTest process with signal 11 at the first pending-monitor regression. These are different failure paths; neither should be described as a successful CI verification based on local results.

## Pending monitor

Non-sensitive progress markers in diagnostic run 41839839741 confirmed fixture creation, control-marker verification and actor initialization succeeded. The crash occurred at the asynchronous `drain` call using default async callbacks. Local Swift 6.4.2 tests passed, while the GitHub Xcode 26.6 runner crashed. The correction replaces default async callback values with optional nil callbacks and invokes the production operation directly inside the actor. Injected test callbacks remain available, with the same activity checks, locking, failure retention and automatic-apply behavior.

This establishes a narrow compatibility comparison; it does not establish an internal Swift runtime root cause. No test or safety check is disabled. No game settings or queue formats change. Existing installations receive the correction through a normal app update; reverting the app undoes it.

## Refused connections

The earlier probe called nonblocking `connect` but discarded its result, then always required a later exceptional `select` event. Winsock may report WSAECONNREFUSED synchronously from `connect`; that terminal error must be accepted without requiring a second asynchronous notification. The probe now reports initial result/error and accepts exactly that synchronous refusal or the original asynchronous exceptional event plus SO_ERROR 10061. Other errors, timeout without that evidence, success, lost urgent data, reset errors and clean EOF retain their existing checks.

The old CI log recorded select=0 and SO_ERROR 10061, but did not record the initial connect result. Synchronous refusal is therefore a possible explanation, not retrospectively proven from that log. The improved probe preserves enough non-sensitive information to distinguish the paths on future runs. The shared socket correction itself is unchanged. Local Wine 10 x86_64 refused checks passed with and without the helper, both taking the asynchronous path.

## Verification

Local full suite: 343 tests, 15 optional skips, zero failures. Required Wine/IPX production packaging succeeded. Corrected GitHub run 41840512347 passed its full Swift test step, confirming the callback comparison on the previously failing runner. The complete [GitHub run](https://github.com/seastwood/Nokcandu/actions/runs/41840512347) succeeded for commit 2074d20: 343 tests with 21 expected clean-runner skips and zero failures; app packaging; all 16 real Wine 10/11 × i686/x86_64 × graceful/refused/urgent/reset combinations; shell syntax checks. Every refused case in this run used the asynchronous path and passed the original strict exceptional-event/error assertion. Thus the old networking failure was not reproduced and its exact cause remains unconfirmed; the synchronous case handling is harness hardening, not proof of that historical cause. The corrected signed local package was installed through app-only recovery, passed deep/strict signature validation and reopened with BF2 Ready and normal status refresh. No game was launched or its preferences changed during this verification. No macOS diagnostic reports are collected or uploaded; temporary logs contain only synthetic test evidence.
