// Repair only installer-added elevation tokens for registered EA games in this Wine prefix.
#ifndef UNICODE
#define UNICODE
#endif
#define _UNICODE
#include <windows.h>
#include <tlhelp32.h>
#include <wchar.h>
#include <wctype.h>
#include <stdio.h>
#define CAP 32768
static wchar_t roots[512][MAX_PATH * 4];
static unsigned root_count;
#include "compat-flags.h"
#ifndef NOK_COMPAT_TEST
static int read_string(HKEY key,const wchar_t *name,wchar_t *out,DWORD cap) {
    DWORD type=0,size=cap*sizeof(wchar_t);
    if (RegQueryValueExW(key,name,0,&type,(BYTE*)out,&size)!=ERROR_SUCCESS || type!=REG_SZ || size<2 || size>cap*sizeof(wchar_t)) return 0;
    if(size%sizeof(wchar_t) || out[size/sizeof(wchar_t)-1])return 0;
    return 1;
}
static void find_roots(REGSAM view) {
    HKEY key;
    if(RegOpenKeyExW(HKEY_LOCAL_MACHINE,L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall",0,KEY_READ|view,&key))return;
    for(DWORD i=0;i<10000;i++) {
        wchar_t name[512];DWORD count=512;
        LONG status=RegEnumKeyExW(key,i,name,&count,0,0,0,0);
        if(status==ERROR_NO_MORE_ITEMS)break;
        if(status)continue;
        HKEY item;if(RegOpenKeyExW(key,name,0,KEY_READ|view,&item))continue;
        wchar_t publisher[512],title[512],folder[MAX_PATH*4],full[MAX_PATH*4];
        if(read_string(item,L"Publisher",publisher,512) && ((!_wcsnicmp(publisher,L"Electronic Arts",15) && (!publisher[15]||publisher[15]==L','||publisher[15]==L' '))||!_wcsicmp(publisher,L"EA Games")) &&
           read_string(item,L"DisplayName",title,512) && _wcsicmp(title,L"EA app") && _wcsicmp(title,L"EA Desktop") &&
           read_string(item,L"InstallLocation",folder,MAX_PATH*4) && folder[0] && folder[1]==L':' && (folder[2]==L'\\'||folder[2]==L'/')) {
            DWORD n=GetFullPathNameW(folder,MAX_PATH*4,full,0);
            if(n>3 && n<MAX_PATH*4 && GetFileAttributesW(full)!=INVALID_FILE_ATTRIBUTES && root_count<512) {
                while(n>3 && (full[n-1]==L'\\'||full[n-1]==L'/'))full[--n]=0;
                if(n>3)wcscpy(roots[root_count++],full);
            }
        }
        RegCloseKey(item);
    }
    RegCloseKey(key);
}
static int owned(const wchar_t *path) {
    wchar_t full[MAX_PATH*4];DWORD n=GetFullPathNameW(path,MAX_PATH*4,full,0);
    if(!n||n>=MAX_PATH*4||GetFileAttributesW(full)==INVALID_FILE_ATTRIBUTES)return 0;
    for(unsigned i=0;i<root_count;i++) {
        size_t len=wcslen(roots[i]);
        if(!_wcsnicmp(full,roots[i],len) && full[len]==L'\\')return 1;
    }
    return 0;
}
static void repair(HKEY hive,REGSAM view,const wchar_t *backup_name) {
    HKEY key;
    if(RegOpenKeyExW(hive,L"Software\\Microsoft\\Windows NT\\CurrentVersion\\AppCompatFlags\\Layers",0,KEY_QUERY_VALUE|KEY_SET_VALUE|view,&key))return;
    HKEY backup=0;wchar_t backup_path[512];
    swprintf(backup_path,512,L"Software\\Nokcandu\\CompatibilityBackups\\%ls",backup_name);
    for(DWORD i=0;i<10000;) {
        wchar_t name[CAP],value[CAP],clean[CAP];DWORD names=CAP,bytes=sizeof(value),type=0;
        LONG status=RegEnumValueW(key,i,name,&names,0,&type,(BYTE*)value,&bytes);
        if(status==ERROR_NO_MORE_ITEMS)break;
        ++i;
        if(status||type!=REG_SZ||bytes<2||bytes>sizeof(value))continue;
        if(bytes%sizeof(wchar_t) || value[bytes/sizeof(wchar_t)-1])continue;
        if(!owned(name)||!remove_admin(value,clean,CAP))continue;
        if(!backup && RegCreateKeyExW(HKEY_CURRENT_USER,backup_path,0,0,0,KEY_QUERY_VALUE|KEY_SET_VALUE,0,&backup,0))continue;
        // Keep the first original value, before any edit. Never change flags if the backup fails.
        DWORD old_type=0,old_size=0;
        status=RegQueryValueExW(backup,name,0,&old_type,0,&old_size);
        if(status!=ERROR_SUCCESS && (status!=ERROR_FILE_NOT_FOUND || RegSetValueExW(backup,name,0,REG_SZ,(BYTE*)value,bytes)))continue;
        if(RegFlushKey(backup))continue;
        if(!*clean || !wcscmp(clean,L"~")) {if(!RegDeleteValueW(key,name))--i;}
        else RegSetValueExW(key,name,0,REG_SZ,(BYTE*)clean,(DWORD)((wcslen(clean)+1)*2));
    }
    if(backup)RegCloseKey(backup);
    RegCloseKey(key);
}
static void scan(void) {
    root_count=0;find_roots(KEY_WOW64_32KEY);find_roots(KEY_WOW64_64KEY);
    if(!root_count)return;
    repair(HKEY_CURRENT_USER,KEY_WOW64_32KEY,L"HKCU-32");repair(HKEY_CURRENT_USER,KEY_WOW64_64KEY,L"HKCU-64");
    repair(HKEY_LOCAL_MACHINE,KEY_WOW64_32KEY,L"HKLM-32");repair(HKEY_LOCAL_MACHINE,KEY_WOW64_64KEY,L"HKLM-64");
}
static int ea_running(void) {
    HANDLE snapshot=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);if(snapshot==INVALID_HANDLE_VALUE)return 0;
    PROCESSENTRY32W entry={0};entry.dwSize=sizeof(entry);int found=0;
    if(Process32FirstW(snapshot,&entry))do {if(!_wcsicmp(entry.szExeFile,L"EADesktop.exe")){found=1;break;}}while(Process32NextW(snapshot,&entry));
    CloseHandle(snapshot);return found;
}
int wmain(int argc,wchar_t **argv) {
    if(argc==2&&!wcscmp(argv[1],L"--watch")) {
        HANDLE mutex=CreateMutexW(0,FALSE,L"Local\\NokcanduEACompatibility");
        if(!mutex)return 1;
        if(GetLastError()==ERROR_ALREADY_EXISTS){CloseHandle(mutex);return 0;}
        unsigned absent=0; int seen=0;
        do {scan();Sleep(2000);if(ea_running()){seen=1;absent=0;}else ++absent;}while(absent<(seen?2:30));
        CloseHandle(mutex);
    }else scan();
    return 0;
}
#endif
