/* Isolated compatibility test. Creates only C:\NOKIPX01 and never opens a game. */
#include <windows.h>
#include "payload.h"
void __main(void) {}
void mainCRTStartup(void) {
 const char* folder="C:\\NOKIPX01";
 if(!CreateDirectoryA(folder,NULL)) {
  MessageBoxA(NULL,"C:\\NOKIPX01 already exists or cannot be created. Nothing was changed.","Nokcandu IPX compatibility test",MB_OK|MB_ICONINFORMATION);ExitProcess(1);
 }
 char path[MAX_PATH];DWORD written;
 for(unsigned i=0;i<sizeof(files)/sizeof(files[0]);i++){
  wsprintfA(path,"%s\\%s",folder,files[i].name);
  HANDLE file=CreateFileA(path,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
  if(file==INVALID_HANDLE_VALUE||!WriteFile(file,files[i].data,files[i].size,&written,NULL)||written!=files[i].size){MessageBoxA(NULL,"Test extraction failed. Game files were not touched.","Nokcandu",MB_OK);ExitProcess(2);}CloseHandle(file);
 }
 STARTUPINFOA startup={0};startup.cb=sizeof(startup);PROCESS_INFORMATION process={0};
 char command[]="C:\\NOKIPX01\\probe.exe";
 if(!CreateProcessA(NULL,command,NULL,NULL,FALSE,0,NULL,folder,&startup,&process)){wsprintfA(path,"Windows could not start the isolated test. Error %lu. Game files were not changed.",GetLastError());MessageBoxA(NULL,path,"Nokcandu",MB_OK);ExitProcess(3);}
 DWORD wait=WaitForSingleObject(process.hProcess,20000),status=0;
 if(wait==WAIT_OBJECT_0)GetExitCodeProcess(process.hProcess,&status);else status=999;
 CloseHandle(process.hThread);CloseHandle(process.hProcess);
 wsprintfA(path,"Isolated Windows 98 IPX test result: %lu\r\n\r\n0 means socket, bind, send and receive passed.\r\nResults and diagnostic files: C:\\NOKIPX01\r\nNo game or Windows DLL files were replaced.",status);
 MessageBoxA(NULL,path,"Nokcandu IPX compatibility test",MB_OK|MB_ICONINFORMATION);ExitProcess(status);
}
