#ifndef NOKCANDU_GAME_WRAPPER_STAMP_H
#define NOKCANDU_GAME_WRAPPER_STAMP_H
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
/* A wrapper is executable code copied from one engine. Never route a new engine
 * through an older copy while an engine replacement is in progress. */
static int nokcandu_wrapper_engine_current(const char *list, const char *loader) {
    struct stat st;
    if (!list || !loader || stat(loader, &st)) return 0;
    FILE *file = fopen(list, "r");
    if (!file) return 0;
    char line[1024], expected[96];
    snprintf(expected, sizeof(expected), "#engine\t%lld:%lld", (long long)st.st_size, (long long)st.st_mtimespec.tv_sec);
    int matches = 0;
    while (fgets(line, sizeof(line), file)) {
        line[strcspn(line, "\r\n")] = 0;
        if (!strncmp(line, "#engine\t", 8)) { matches = !strcmp(line, expected); break; }
    }
    fclose(file);
    return matches;
}
#endif
