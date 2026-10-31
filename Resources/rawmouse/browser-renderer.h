#ifndef NOKCANDU_BROWSER_RENDERER_H
#define NOKCANDU_BROWSER_RENDERER_H
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

// Wine 11 CEF workers need Metal surfaces even when the game uses a different renderer.
// This runs before Wine initializes its DLL search paths. Only the exact browser worker is
// changed; Steam itself, games, installers and other helpers retain their launch environment.
// The shared Steam launcher supplies the opt-in root only for the tested Wine 11.0 engine.
static bool nokcandu_configure_browser_renderer(const char *path) {
    if (!path || !*path) return false;
    const char *name = path;
    for (const char *p = path; *p; ++p) if (*p == '/' || *p == '\\') name = p + 1;
    // NOKCANDU_BROWSER_EXES: ';'-separated program names the launcher opted in (default: Steam's worker).
    const char *list = getenv("NOKCANDU_BROWSER_EXES");
    if (!list || !*list) list = "steamwebhelper.exe";
    bool match = false;
    for (const char *s = list; *s && !match; ) {
        const char *e = strchr(s, ';'); size_t n = e ? (size_t)(e - s) : strlen(s);
        if (n == strlen(name) && !strncasecmp(s, name, n)) match = true;
        s = e ? e + 1 : s + n;
    }
    if (!match) return false;
    const char *root = getenv("NOKCANDU_BROWSER_DXMT_ROOT");
    if (!root || !*root || access(root, R_OK | X_OK)) return false;
    const char *old = getenv("WINEDLLOVERRIDES");
    char value[8192];
    int size = snprintf(value, sizeof value, "%s%sdxgi,d3d10core,d3d11,winemetal=b",
                        old ? old : "", old && *old ? ";" : "");
    if (size < 0 || (size_t)size >= sizeof value) return false;
    if (setenv("WINEDLLPATH_DXMT", root, 1) || setenv("WINEDLLOVERRIDES", value, 1)) return false;
    unsetenv("WINEDLLPATH_D3DMETAL");
    unsetenv("WINEDLLPATH_DXVK");
    // The Windows environment block also needs this: the launcher exports it before Wine
    // creates the process. Changing Unix getenv here alone cannot update that inherited block.
    return true;
}

// Games started by a launcher (Battle.net, Steam) inherit the launcher's renderer. program-renderers.tsv (in the
// launcher app's state folder, beside this library) maps a game to its own settings: "<Program.exe>\tKEY=VALUE…"
// or "steam:<app id>\t…" (Steam sets SteamAppId for its games). The renderer search paths are reset first so
// only the chosen renderer remains. NOKCANDU_VIRTUAL_SCREEN=WxH switches the shared virtual screen to the
// game's size, the same way a live resolution change from Nokcandu does.
__attribute__((unused)) static void nokcandu_set_virtual_screen(const char *size) {
    const char *prefix = getenv("WINEPREFIX");
    int w = 0, h = 0;
    if (!prefix || sscanf(size, "%dx%d", &w, &h) != 2 || w < 320 || h < 200) return;
    char lock[4096], path[4096], tmp[4200];
    snprintf(path, sizeof path, "%s/.nokcandu-virtual-display", prefix);
    snprintf(lock, sizeof lock, "%s.lock", path);
    if (access(lock, F_OK)) return;                  // the virtual screen isn't used in this prefix
    snprintf(tmp, sizeof tmp, "%s.%d", path, (int)getpid());
    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fprintf(f, "%dx%d\n", w, h);
    fclose(f);
    rename(tmp, path);
}

__attribute__((unused)) static bool nokcandu_configure_program_renderer(const char *path, const char *state_dir) {
    if (!path || !*path || !state_dir || !*state_dir) return false;
    const char *name = path;
    for (const char *p = path; *p; ++p) if (*p == '/' || *p == '\\') name = p + 1;
    char file[4096];
    snprintf(file, sizeof file, "%s/program-renderers.tsv", state_dir);
    FILE *f = fopen(file, "r");
    if (!f) return false;
    char line[8192];
    bool done = false;
    while (!done && fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0;
        char *save = NULL, *field = strtok_r(line, "\t", &save);
        if (!field) continue;
        if (!strncmp(field, "steam:", 6)) {
            const char *id = getenv("SteamAppId");
            if (!id || strcmp(id, field + 6)) continue;
        } else if (strcasecmp(field, name)) continue;
        static const char *renderers[] = { "WINEDLLPATH_D9VK", "WINEDLLPATH_DXVK", "WINEDLLPATH_D3DMETAL", "WINEDLLPATH_DXMT", "WINEDLLPATH_CNCD" };
        for (size_t i = 0; i < sizeof renderers / sizeof *renderers; i++) unsetenv(renderers[i]);
        unsetenv("WINEDLLOVERRIDES");
        while ((field = strtok_r(NULL, "\t", &save))) {
            char *eq = strchr(field, '=');
            if (!eq || eq == field) continue;
            *eq = 0;
            if (!strcmp(field, "NOKCANDU_VIRTUAL_SCREEN")) nokcandu_set_virtual_screen(eq + 1);
            else setenv(field, eq + 1, 1);
        }
        done = true;
    }
    fclose(f);
    return done;
}
#endif
