#ifndef NOKCANDU_WINDOWS_PROCESS_ROLE_H
#define NOKCANDU_WINDOWS_PROCESS_ROLE_H
#include <stdbool.h>
#include <string.h>
#include <strings.h>
// Background Windows services, elevation brokers and browser workers do not own game windows.
// They must not create a Mac game app or install input/display hooks during driver initialization.
static bool nokcandu_background_program(const char *path) {
    if (!path || !*path) return false;
    const char *name = path;
    for (const char *p = path; *p; ++p) if (*p == '/' || *p == '\\') name = p + 1;
    static const char *names[] = {
        "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe", "explorer.exe", "rpcss.exe",
        "conhost.exe", "start.exe", "wineboot.exe", "winemenubuilder.exe", "rundll32.exe", "tabtip.exe",
        "wineconsole.exe", "regedit.exe", "reg.exe", "msiexec.exe", "cmd.exe", "steamerrorreporter.exe",
        "steamservice.exe", "gldriverquery.exe", "gldriverquery64.exe", "vulkandriverquery.exe",
        "vulkandriverquery64.exe", "crashhandler.exe", "EAGEP.exe", "EABackgroundService.exe",
        "EALocalHostSvc.exe", "EACefSubProcess.exe", "EACrashReporter.exe", "EAErrorReporter.exe",
        "steamwebhelper.exe", "QtWebEngineProcess.exe", "CefSharp.BrowserSubprocess.exe", NULL
    };
    for (unsigned i = 0; names[i]; ++i) if (!strcasecmp(name, names[i])) return true;
    return false;
}
#endif
