/* Valve vendor receipt. Default has no writes; --attributes sends only the documented
 * GET_ATTRIBUTES query via feature transport. No settings, pairing or mode commands. */
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0600
#endif
#include <windows.h>
#include <setupapi.h>
#include <hidsdi.h>
#include <hidpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc,char **argv) {
    BOOL attributes=argc>1&&!strcmp(argv[1],"--attributes");
    GUID guid;HidD_GetHidGuid(&guid);unsigned found=0,opened=0;
    HDEVINFO list=SetupDiGetClassDevsA(&guid,NULL,NULL,DIGCF_PRESENT|DIGCF_DEVICEINTERFACE);
    if(list==INVALID_HANDLE_VALUE)return 2;
    for(DWORD i=0;;++i){SP_DEVICE_INTERFACE_DATA item={0};item.cbSize=sizeof(item);
        if(!SetupDiEnumDeviceInterfaces(list,NULL,&guid,i,&item))break;
        DWORD n=0;SetupDiGetDeviceInterfaceDetailA(list,&item,NULL,0,&n,NULL);
        PSP_DEVICE_INTERFACE_DETAIL_DATA_A detail=malloc(n);if(!detail)continue;detail->cbSize=sizeof(*detail);
        if(!SetupDiGetDeviceInterfaceDetailA(list,&item,detail,n,NULL,NULL)){free(detail);continue;}
        /* Description filter first; don't open keyboard/mouse or unrelated HID interfaces. */
        if(!strstr(detail->DevicePath,"vid_28de&pid_1102")){free(detail);continue;}
        printf("USB interface 2 present in HID identity=%u\n",strstr(detail->DevicePath,"mi_02")!=NULL||strstr(detail->DevicePath,"MI_02")!=NULL);
        HANDLE h=CreateFileA(detail->DevicePath,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_EXISTING,FILE_FLAG_OVERLAPPED,NULL);
        free(detail);++found;if(h==INVALID_HANDLE_VALUE){printf("Vendor open error=%lu\n",GetLastError());continue;}
        PHIDP_PREPARSED_DATA pp=NULL;HIDP_CAPS caps={0};
        if(!HidD_GetPreparsedData(h,&pp)){CloseHandle(h);continue;}
        NTSTATUS status=HidP_GetCaps(pp,&caps);HidD_FreePreparsedData(pp);
        if(status!=HIDP_STATUS_SUCCESS||caps.UsagePage!=0xff00||caps.Usage!=1){CloseHandle(h);continue;}
        ++opened;printf("Valve vendor HID opened: input=%u feature=%u output=%u\n",caps.InputReportByteLength,caps.FeatureReportByteLength,caps.OutputReportByteLength);
        unsigned char data[256]={0};
        BOOL feature=caps.FeatureReportByteLength<=sizeof(data)&&HidD_GetFeature(h,data,caps.FeatureReportByteLength);
        printf("Feature read only success=%u error=%lu\n",feature,feature?0:GetLastError());
        if(attributes&&caps.FeatureReportByteLength==65){
            memset(data,0,sizeof(data));data[1]=0x83;
            BOOL sent=HidD_SetFeature(h,data,65);DWORD error=sent?0:GetLastError();
            Sleep(30);memset(data,0,sizeof(data));
            BOOL received=sent&&HidD_GetFeature(h,data,65);
            printf("Read-only attributes query sent=%u error=%lu response=%u expected-header=%u declared-length=%u\n",
                sent,error,received,received&&data[1]==0x83,received?data[2]:0);
        }
        HANDLE event=CreateEventA(NULL,TRUE,FALSE,NULL);OVERLAPPED ov={0};ov.hEvent=event;DWORD bytes=0;
        BOOL read=ReadFile(h,data,min(caps.InputReportByteLength,sizeof(data)),&bytes,&ov);
        if(!read&&GetLastError()==ERROR_IO_PENDING){if(WaitForSingleObject(event,1500)==WAIT_OBJECT_0)read=GetOverlappedResult(h,&ov,&bytes,FALSE);else {CancelIo(h);GetOverlappedResult(h,&ov,&bytes,TRUE);}}
        printf("Input receipt success=%u bytes=%lu\n",read,bytes);
        CloseHandle(event);CloseHandle(h);
    }
    SetupDiDestroyDeviceInfoList(list);printf("Wired Valve interfaces found=%u opened=%u\n",found,opened);return opened?0:1;
}
