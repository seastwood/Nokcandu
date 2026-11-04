#include <windows.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    HMODULE module = LoadLibraryA("nok-scoped-test.dll");
    if (argc == 2 && !strcmp(argv[1], "child")) {
        if (!module) { printf("game native module missing: %lu\n", GetLastError()); return 3; }
        int (__cdecl *marker)(void) = (int (__cdecl *)(void))GetProcAddress(module, "marker");
        if (!marker || marker() != 1942) return 4;
        puts("game received scoped DLL rules"); return 0;
    }
    if (module) { puts("client incorrectly received game DLL rules"); return 5; }
    if (argc != 2) return 6;
    char command[4096];
    if (snprintf(command, sizeof(command), "\"%s\" child", argv[1]) >= (int)sizeof(command)) return 7;
    STARTUPINFOA startup = {0}; startup.cb = sizeof(startup);
    PROCESS_INFORMATION process = {0};
    if (!CreateProcessA(argv[1], command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process)) {
        printf("child launch failed: %lu\n", GetLastError()); return 8;
    }
    if (WaitForSingleObject(process.hProcess, 30000) != WAIT_OBJECT_0) return 9;
    DWORD result = 10; GetExitCodeProcess(process.hProcess, &result);
    CloseHandle(process.hThread); CloseHandle(process.hProcess);
    if (result) return (int)result;
    if (LoadLibraryA("nok-scoped-test.dll")) { puts("client settings changed after game launch"); return 11; }
    puts("client retained its original DLL rules"); return 0;
}
