// Nokcandu borderless launcher. Built from source for each Windows architecture.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <string.h>
static WCHAR target_name[MAX_PATH], restart_name[MAX_PATH];
static DWORD game_pid(void) {
 HANDLE s=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);if(s==INVALID_HANDLE_VALUE)return 0;
 PROCESSENTRY32W e={0};e.dwSize=sizeof e;DWORD p=0;
 if(Process32FirstW(s,&e))do{if(!_wcsicmp(e.szExeFile,target_name)||(restart_name[0]&&!_wcsicmp(e.szExeFile,restart_name))){p=e.th32ProcessID;break;}}while(Process32NextW(s,&e));
 CloseHandle(s);return p;
}
static BOOL load_helper(HANDLE process,DWORD pid,const char *dll) {
 FARPROC load=GetProcAddress(GetModuleHandleA("kernel32.dll"),"LoadLibraryA");HMODULE local=NULL;
 if(!load || !GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,(LPCSTR)load,&local))return FALSE;
 char path[MAX_PATH];GetModuleFileNameA(local,path,sizeof path);const char *name=strrchr(path,'\\');name=name?name+1:path;
 LPVOID remote_load=NULL;
 for(int tries=0;tries<50&&!remote_load;tries++){
  HANDLE snap=CreateToolhelp32Snapshot(TH32CS_SNAPMODULE|TH32CS_SNAPMODULE32,pid);
  if(snap!=INVALID_HANDLE_VALUE){MODULEENTRY32 m={0};m.dwSize=sizeof m;
   if(Module32First(snap,&m))do{if(!_stricmp(m.szModule,name)){remote_load=m.modBaseAddr+((BYTE*)load-(BYTE*)local);break;}}while(Module32Next(snap,&m));CloseHandle(snap);
  }
  if(!remote_load)Sleep(100);
 }
 if(!remote_load)return FALSE;
 SIZE_T len=strlen(dll)+1;LPVOID memory=VirtualAllocEx(process,NULL,len,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);
 if(!memory)return FALSE;
 if(!WriteProcessMemory(process,memory,dll,len,NULL)){VirtualFreeEx(process,memory,0,MEM_RELEASE);return FALSE;}
 HANDLE t=CreateRemoteThread(process,NULL,0,(LPTHREAD_START_ROUTINE)remote_load,memory,0,NULL);
 if(!t){VirtualFreeEx(process,memory,0,MEM_RELEASE);return FALSE;}
 DWORD wait=WaitForSingleObject(t,15000),result=0;
 if(wait==WAIT_OBJECT_0){GetExitCodeThread(t,&result);VirtualFreeEx(process,memory,0,MEM_RELEASE);}
 CloseHandle(t);return wait==WAIT_OBJECT_0 && result!=0;
}
int main(int argc,char **argv){
 freopen("nokcandu-borderless-launch.log","w",stdout);
 WCHAR command[32768],target[MAX_PATH]; char dll[MAX_PATH];
 if(!GetEnvironmentVariableW(L"NOKCANDU_BORDERLESS_TARGET",target,MAX_PATH) ||
    !GetEnvironmentVariableA("NOKCANDU_BORDERLESS_DLL",dll,sizeof dll))return 2;
 const WCHAR *name=wcsrchr(target,L'\\');name=name?name+1:target;
 wcsncpy(target_name,name,MAX_PATH-1);
 // A verified menu/display copy may restart the original program when changing mods.
 // Follow that alternate process within this Wine environment and reapply the same window helper.
 WCHAR restart[MAX_PATH];
 if(GetEnvironmentVariableW(L"NOKCANDU_BORDERLESS_RESTART_TARGET",restart,MAX_PATH)){
  const WCHAR *other=wcsrchr(restart,L'\\');other=other?other+1:restart;
  wcsncpy(restart_name,other,MAX_PATH-1);
 }

 // Forward the original Windows command line verbatim; reparsing argv loses quotes/backslashes.
 const WCHAR *args=GetCommandLineW();
 if(*args=='"'){args++;while(*args&&*args!='"')args++;if(*args)args++;}
 else while(*args&&*args!=' '&&*args!='\t')args++;
 if(wcslen(target)+wcslen(args)+4>=32768)return 2;
 swprintf(command,32768,L"\"%ls\"%ls",target,args);
 SetEnvironmentVariableA("NOKCANDU_NO_GAME_APP",NULL);
 STARTUPINFOW si={0};PROCESS_INFORMATION pi={0};si.cb=sizeof si;
 if(!CreateProcessW(NULL,command,NULL,NULL,FALSE,0,NULL,NULL,&si,&pi)){printf("launch failed %lu\n",GetLastError());return 1;}
 CloseHandle(pi.hThread);DWORD last=pi.dwProcessId;HANDLE process=pi.hProcess;DWORD exit_code=0;
 for(;;){
  printf("window helper for pid %lu: %s\n",last,load_helper(process,last,dll)?"loaded":"FAILED");fflush(stdout);
  WaitForSingleObject(process,INFINITE);GetExitCodeProcess(process,&exit_code);CloseHandle(process);
  DWORD next=0;for(int i=0;i<30;i++){next=game_pid();if(next&&next!=last)break;next=0;Sleep(200);}
  if(!next)break;
  last=next;process=OpenProcess(PROCESS_ALL_ACCESS,FALSE,last);if(!process)break;
 }
 return (int)exit_code;
}
