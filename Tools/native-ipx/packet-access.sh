#!/bin/bash
# Temporary native-IPX test access. No group, launch daemon, driver, or persistent policy changes.
# Inspect without changing anything: packet-access.sh --check
# User-authorized test lease: sudo packet-access.sh 900
set -euo pipefail
leaseSeconds="${1:---check}"
if [ "$leaseSeconds" != --check ]; then
    [[ "$leaseSeconds" =~ ^[0-9]+$ ]] && [ "$leaseSeconds" -ge 60 ] && [ "$leaseSeconds" -le 1800 ] || { echo 'Choose 60–1800 seconds.' >&2; exit 1; }
    [ "$(id -u)" = 0 ] || { echo 'macOS requires administrator authorization for native packet access.' >&2; exit 1; }
    [[ "${SUDO_UID:-}" =~ ^[0-9]+$ ]] && [ "$SUDO_UID" -gt 0 ] || { echo 'Run with sudo from your normal Mac account.' >&2; exit 1; }
fi
# Only existing, untouched root:wheel 0600 capture devices are eligible.
devices=(); identities=()
for device in /dev/bpf[0-9]*; do
    [ -c "$device" ] && [ ! -L "$device" ] || continue
    metadata=$(/usr/bin/stat -f '%u:%g:%Lp:%r' "$device")
    case "$metadata" in
        0:0:600:*) devices+=("$device"); identities+=("${metadata##*:}") ;;
        *) echo "Leaving customized device permissions alone: $device" ;;
    esac
done
[ "${#devices[@]}" -gt 0 ] || { echo 'No untouched capture devices are available.' >&2; exit 1; }
if [ "$leaseSeconds" = --check ]; then
    printf 'No changes made. Eligible existing capture devices: %s\n' "${devices[*]}"
    exit 0
fi
owned=()
cleanup() {
    trap - EXIT HUP INT TERM
    if [ "${#owned[@]}" -gt 0 ]; then
    for i in "${owned[@]}"; do
        device="${devices[$i]}"
        # Do not overwrite a later owner, replaced device, or customized mode/group.
        [ -c "$device" ] && [ ! -L "$device" ] || continue
        current=$(/usr/bin/stat -f '%u:%g:%Lp:%r' "$device")
        if [ "$current" = "$SUDO_UID:0:600:${identities[$i]}" ]; then
            /usr/sbin/chown 0:0 "$device"
        else
            echo "Device changed during the lease; left untouched: $device" >&2
        fi
    done
    fi
    echo 'Temporary packet-access lease ended.'
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
for ((i=0; i<${#devices[@]}; i++)); do
    device="${devices[$i]}"
    [ "$(/usr/bin/stat -f '%u:%g:%Lp:%r' "$device")" = "0:0:600:${identities[$i]}" ] || { echo 'Capture permissions changed. Stopping.' >&2; exit 1; }
    owned+=("$i")
    /usr/sbin/chown "$SUDO_UID:0" "$device"
done
echo "Native packet access is ready for your Mac account for $leaseSeconds seconds."
echo 'This permits raw-packet capture and transmission. Leave this Terminal open; Ctrl+C restores the original ownership early.'
echo 'Already opened handles remain usable until the games/tools that opened them close.'
/bin/sleep "$leaseSeconds" &
wait "$!"
