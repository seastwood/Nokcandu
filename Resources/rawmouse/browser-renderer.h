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
#endif
