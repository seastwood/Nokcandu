#include <windows.h>
int main(void);
void mainCRTStartup(void) {
 int status=main();
 char path[MAX_PATH],result[64];GetModuleFileNameA(NULL,path,sizeof(path));
 int i=lstrlenA(path);while(i>0 && path[i-1]!='\\')i--;lstrcpyA(path+i,"probe-result.txt");
 HANDLE file=CreateFileA(path,GENERIC_WRITE,0,NULL,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
 DWORD n;int size=wsprintfA(result,"IPX loopback result: %d\r\n",status);
 if(file!=INVALID_HANDLE_VALUE){WriteFile(file,result,size,&n,NULL);CloseHandle(file);}ExitProcess(status);
}

void __main(void) {}
