#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Writes Nokcandu's entitlements for a hardened (Developer ID) build.

usage: entitlements.py OUT.plist PROFILE.plist|"" BUNDLE_ID

PROFILE.plist is a decoded provisioning profile (`security cms -D -i`), or "" for none. With a profile, the
virtual-controller entitlement is added only if the profile grants it, together with the App ID and team the
profile names (macOS ignores a restricted entitlement, and kills the app, unless they match). Refuses a profile
for another bundle ID, an expired one, or one that isn't for Developer ID.
"""
import datetime, plistlib, sys

VIRTUAL = "com.apple.developer.hid.virtual.device"

def entitlements(profile, bundle_id, now=None):
    ents = {"com.apple.security.device.audio-input": True}
    if profile is None:
        return ents, []
    notes = []
    granted = profile.get("Entitlements", {})
    app_id = granted.get("com.apple.application-identifier") or granted.get("application-identifier") or ""
    team = granted.get("com.apple.developer.team-identifier") or (profile.get("TeamIdentifier") or [""])[0]
    if not team or app_id != f"{team}.{bundle_id}":
        raise SystemExit(f"The provisioning profile is for {app_id or 'an unknown App ID'}, not {team}.{bundle_id}.")
    expires = profile.get("ExpirationDate")
    now = now or datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    if isinstance(expires, datetime.datetime) and expires.replace(tzinfo=None) <= now:
        raise SystemExit(f"The provisioning profile expired on {expires:%Y-%m-%d}. Download a new one.")
    if profile.get("ProvisionsAllDevices") is not True:
        raise SystemExit("The provisioning profile isn't a Developer ID profile (it's limited to listed devices).")
    if granted.get(VIRTUAL) is not True:
        raise SystemExit(f"The provisioning profile doesn't grant {VIRTUAL}. Wait for Apple to grant the capability, then download a new profile.")
    ents["com.apple.application-identifier"] = app_id
    ents["com.apple.developer.team-identifier"] = team
    ents[VIRTUAL] = True
    notes.append("Virtual controllers on the Mac: entitlement granted by the provisioning profile")
    return ents, notes

def main(argv):
    out, profile_path, bundle_id = argv[1], argv[2], argv[3]
    profile = None
    if profile_path:
        with open(profile_path, "rb") as f:
            profile = plistlib.load(f)
    ents, notes = entitlements(profile, bundle_id)
    with open(out, "wb") as f:
        plistlib.dump(ents, f)
    for n in notes:
        print(n)

if __name__ == "__main__":
    main(sys.argv)
