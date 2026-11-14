// SPDX-License-Identifier: GPL-3.0-only
// Windows programs' page file: answers Wine's vm.swapusage question with swap that can grow, as macOS's does
// (see commit-memory.h). Only the swap figures change; physical memory is reported as it is.
// NOKCANDU_MACOS_SWAP=1 turns it off (macOS's current swap figures are passed through).
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include "commit-memory.h"

static int nok_swap_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int rc = sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    if (rc != 0 || namelen != 2 || name[0] != CTL_VM || name[1] != VM_SWAPUSAGE || !oldp || !oldlenp
        || *oldlenp != sizeof(struct xsw_usage) || newp) return rc;
    const char *off = getenv("NOKCANDU_MACOS_SWAP");
    if (off && strcmp(off, "1") == 0) return rc;
    struct xsw_usage *swap = oldp;
    uint64_t ram = 0; size_t len = sizeof(ram);
    if (sysctlbyname("hw.memsize", &ram, &len, NULL, 0) != 0 || !ram) return rc;
    struct statfs fs;
    uint64_t disk = 0;
    if (statfs("/System/Volumes/VM", &fs) == 0 || statfs("/", &fs) == 0) disk = (uint64_t)fs.f_bavail * fs.f_bsize;
    uint64_t total, avail;
    nok_pagefile_model(swap->xsu_total, swap->xsu_used, ram, disk, &total, &avail);
    swap->xsu_total = total;
    swap->xsu_avail = avail;
    return rc;
}

__attribute__((used)) static const struct { const void *replacement, *original; } nok_swap_interpose[]
    __attribute__((section("__DATA,__interpose"))) = { { (const void *)nok_swap_sysctl, (const void *)sysctl } };
