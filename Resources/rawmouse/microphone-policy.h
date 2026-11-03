#ifndef NOKCANDU_MICROPHONE_POLICY_H
#define NOKCANDU_MICROPHONE_POLICY_H
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>
__attribute__((unused)) static int nokcandu_microphone_same_path(const char *a, const char *b) {
    while (*a && *b) { unsigned char x=*a++, y=*b++; if(x=='/')x='\\';if(y=='/')y='\\';if(tolower(x)!=tolower(y))return 0; }
    return !*a && !*b;
}
/* Wine removes its loader from argv and can shift the strings themselves.
 * Save the program bytes before Wine initialization, never retain an argv pointer. */
__attribute__((unused)) static const char *nokcandu_microphone_program(int argc, char *const argv[]) {
    if (!argv || argc < 1) return NULL;
    const char *first = argv[0];
    if (first && first[0] && first[0] != '/') {
        size_t n = strlen(first);
        if (n >= 4 && !strcasecmp(first + n - 4, ".exe")) return first;
    }
    return argc > 1 && argv[1] && argv[1][0] != '-' ? argv[1] : NULL;
}
/* A pure read of the generated per-program policy. This must also work before
 * the renderer constructor has copied settings into the process environment. */
__attribute__((unused)) static int nokcandu_microphone_route(const char *file, const char *program, const char *app_id) {
    if (!file || !program) return -1;
    const char *name = program;
    for (const char *p = program; *p; p++) if (*p == '/' || *p == '\\') name = p + 1;
    int client = !strcasecmp(name, "steam.exe") || !strcasecmp(name, "steamwebhelper.exe") ||
        !strcasecmp(name, "steamservice.exe") || !strcasecmp(name, "battle.net.exe") ||
        !strcasecmp(name, "agent.exe") || !strcasecmp(name, "regedit.exe") || !strcasecmp(name, "regedit");
    FILE *f = fopen(file, "r"); if (!f) return -1;
    char line[8192]; int result = -1, priority = 0;
    while (fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\r\n")] = 0;
        char *saved = NULL, *key = strtok_r(line, "\t", &saved);
        if (!key) continue;
        int rank = 0;
        if (!strncmp(key, "steam:", 6)) { if (!client && app_id && !strcmp(app_id, key+6)) rank=3; }
        else if (strchr(key, '/') || strchr(key, '\\')) { if(nokcandu_microphone_same_path(key,program))rank=2; }
        else if (!strcasecmp(key,name)) rank=1;
        if (!rank || rank < priority) continue;
        char *field;
        while ((field = strtok_r(NULL, "\t", &saved))) {
            int value = !strcmp(field,"NOKCANDU_NO_MICROPHONE=1") ? 1 : !strcmp(field,"NOKCANDU_NO_MICROPHONE=0") ? 0 : -1;
            if(value>=0) { if(rank>priority){result=value;priority=rank;}else if(value)result=1; }
        }
    }
    fclose(f); return result;
}
/* Shared by enumeration and the audio-unit boundary, including calls originating
 * in this dylib (dyld does not interpose a library's own calls). */
int nokcandu_microphone_blocked(void);
#endif
