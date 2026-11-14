// SPDX-License-Identifier: GPL-3.0-only
// The page file Windows programs see, modelled on macOS's swap. Wine reports a Windows program's available commit
// (GlobalMemoryStatusEx's ullAvailPageFile) as macOS's free + inactive memory plus unused swap. macOS swap grows on
// demand (it was 4 GB with 0.7 GB free on a 16 GB Mac), so programs that check commit before starting, such as
// Trackmania ("free up at least 5.0 GB… page_file/committed memory"), warned although macOS had room. Windows'
// system-managed page file also grows; this reports swap as able to grow to the size of RAM, never into the last
// 10 GB of free disk.
#ifndef NOKCANDU_COMMIT_MEMORY_H
#define NOKCANDU_COMMIT_MEMORY_H
#include <stdint.h>

#define NOK_PAGEFILE_DISK_RESERVE (10ULL << 30)

/// Swap as programs should see it: `total`/`used` from vm.swapusage, `ram` from hw.memsize, `disk_free` on the
/// swap volume. Never less than macOS reports.
static inline void nok_pagefile_model(uint64_t total, uint64_t used, uint64_t ram, uint64_t disk_free,
                                      uint64_t *out_total, uint64_t *out_avail) {
    uint64_t growable = disk_free > NOK_PAGEFILE_DISK_RESERVE ? disk_free - NOK_PAGEFILE_DISK_RESERVE : 0;
    uint64_t can_reach = used + growable;
    uint64_t want = ram < can_reach ? ram : can_reach;
    uint64_t t = want > total ? want : total;
    if (used > t) t = used;
    *out_total = t;
    *out_avail = t - used;
}
#endif
