/* Nokcandu: stands in for a game's Windows "Bonjour Service".
 *
 * Some games (Blizzard's) install their own copy of Apple's Bonjour service and start it before using Bonjour.
 * On the Mac, Nokcandu's helper relays Windows Bonjour requests to macOS's own Bonjour (see
 * Resources/rawmouse/bonjourbridge.m), so the Windows service has nothing to do; it couldn't work under Wine
 * anyway. This service starts, reports itself running so the game carries on, and waits to be stopped.
 *
 * Build: x86_64-w64-mingw32-clang -O2 -municode -o nokcandu-bonjour-service.exe bonjour-service.c -ladvapi32
 */
#include <windows.h>

static SERVICE_STATUS_HANDLE handle;
static SERVICE_STATUS status;
static HANDLE stop_event;

static DWORD WINAPI control(DWORD code, DWORD type, void *data, void *context)
{
    switch (code)
    {
    case SERVICE_CONTROL_STOP:
    case SERVICE_CONTROL_SHUTDOWN:
    case SERVICE_CONTROL_PRESHUTDOWN:
        status.dwCurrentState = SERVICE_STOP_PENDING;
        SetServiceStatus(handle, &status);
        SetEvent(stop_event);
        return NO_ERROR;
    case SERVICE_CONTROL_INTERROGATE:
        SetServiceStatus(handle, &status);
        return NO_ERROR;
    default:
        return ERROR_CALL_NOT_IMPLEMENTED;
    }
}

static void WINAPI service_main(DWORD argc, WCHAR **argv)
{
    handle = RegisterServiceCtrlHandlerExW(argc ? argv[0] : L"Bonjour Service", control, NULL);
    if (!handle) return;
    status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    status.dwControlsAccepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN;
    status.dwCurrentState = SERVICE_RUNNING;
    SetServiceStatus(handle, &status);
    WaitForSingleObject(stop_event, INFINITE);
    status.dwCurrentState = SERVICE_STOPPED;
    SetServiceStatus(handle, &status);
}

int wmain(int argc, WCHAR **argv)
{
    SERVICE_TABLE_ENTRYW table[] = { { (WCHAR *)L"Bonjour Service", service_main }, { NULL, NULL } };
    stop_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    /* Run from a command line (e.g. "-install" by a game's installer): nothing to do, report success. */
    if (!StartServiceCtrlDispatcherW(table)) return 0;
    return 0;
}
