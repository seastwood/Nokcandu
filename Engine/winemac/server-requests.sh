#!/bin/bash
# Lists the wineserver requests Nokcandu's driver sends, with the number each has in the Wine source it was built
# from ("name number" lines). Requests are numbered by position, so the driver only works with a wineserver whose
# request table has those names at those numbers; Nokcandu checks an engine's table before installing the driver.
# Usage: server-requests.sh <wine source dir>
set -euo pipefail
SRC="$1"
awk '/^enum request$/,/REQ_NB_REQUESTS/' "$SRC/include/wine/server_protocol.h" | grep -oE 'REQ_[a-z0-9_]+' | grep -v '^REQ_NB_REQUESTS$' \
    | awk '{ sub(/^REQ_/, ""); print $0, NR - 1 }' > /tmp/nokcandu-requests.$$
grep -rhoE 'SERVER_START_REQ\( *[a-z0-9_]+' "$SRC/dlls/winemac.drv" | sed -E 's/SERVER_START_REQ\( *//' | sort -u \
    | while read -r r; do grep -E "^$r [0-9]+$" /tmp/nokcandu-requests.$$ || { echo "unknown request $r" >&2; exit 1; }; done
rm -f /tmp/nokcandu-requests.$$
