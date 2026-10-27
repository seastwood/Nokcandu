// Only changes visible, unowned game windows in the launched process. Never changes display modes.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <string.h>

static DWORD tracked_pid;
static unsigned changes;
static BOOL CALLBACK arrange(HWND w,LPARAM unused) {
    DWORD pid=0;GetWindowThreadProcessId(w,&pid);
    if(pid!=tracked_pid || !IsWindowVisible(w) || IsIconic(w) || GetWindow(w,GW_OWNER)) return TRUE;
    RECT client;GetClientRect(w,&client);
    if(client.right < 320 || client.bottom < 200 || (GetWindowLong(w,GWL_EXSTYLE)&WS_EX_TOOLWINDOW)) return TRUE;
    MONITORINFO m;ZeroMemory(&m,sizeof m);m.cbSize=sizeof m;
    if(!GetMonitorInfo(MonitorFromWindow(w,MONITOR_DEFAULTTOPRIMARY),&m))return TRUE;
    RECT r;GetWindowRect(w,&r);
    if(unused==1) {
        RECT c;GetClientRect(w,&c);
        printf("probe: client %ldx%ld window %ld,%ld %ldx%ld display %ld,%ld %ldx%ld\n",c.right-c.left,c.bottom-c.top,r.left,r.top,r.right-r.left,r.bottom-r.top,m.rcMonitor.left,m.rcMonitor.top,m.rcMonitor.right-m.rcMonitor.left,m.rcMonitor.bottom-m.rcMonitor.top);fflush(stdout);return TRUE;
    }
    LONG style=GetWindowLong(w,GWL_STYLE),ex=GetWindowLong(w,GWL_EXSTYLE);
    LONG desired=(style & ~(WS_CAPTION|WS_THICKFRAME|WS_MINIMIZEBOX|WS_MAXIMIZEBOX|WS_SYSMENU))|WS_POPUP;
    LONG de=ex & ~(WS_EX_DLGMODALFRAME|WS_EX_WINDOWEDGE|WS_EX_CLIENTEDGE|WS_EX_STATICEDGE);
    if(style==desired && ex==de && EqualRect(&r,&m.rcMonitor))return TRUE;
    if(changes<15) {
        printf("borderless: pid %lu window %ld,%ld %ldx%ld -> display %ld,%ld %ldx%ld\n",pid,r.left,r.top,r.right-r.left,r.bottom-r.top,m.rcMonitor.left,m.rcMonitor.top,m.rcMonitor.right-m.rcMonitor.left,m.rcMonitor.bottom-m.rcMonitor.top);fflush(stdout);
    }
    changes++;
    SetWindowLong(w,GWL_STYLE,desired);SetWindowLong(w,GWL_EXSTYLE,de);
    SetWindowPos(w,HWND_NOTOPMOST,m.rcMonitor.left,m.rcMonitor.top,m.rcMonitor.right-m.rcMonitor.left,m.rcMonitor.bottom-m.rcMonitor.top,SWP_NOACTIVATE|SWP_FRAMECHANGED|SWP_NOOWNERZORDER);
    return TRUE;
}
static DWORD WINAPI worker(void *unused) {
    (void)unused;SetProcessDPIAware();tracked_pid=GetCurrentProcessId();
    freopen("nokcandu-borderless.log","w",stdout);
    for(;;) { EnumWindows(arrange,0);Sleep(200); }
    return 0;
}
BOOL WINAPI DllMain(HINSTANCE instance,DWORD why,LPVOID reserved) {
    (void)reserved;
    if(why==DLL_PROCESS_ATTACH) { DisableThreadLibraryCalls(instance);HANDLE t=CreateThread(NULL,0,worker,NULL,0,NULL);if(t)CloseHandle(t); }
    return TRUE;
}
