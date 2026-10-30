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
    if (strcasecmp(name, "steamwebhelper.exe")) return false;
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
