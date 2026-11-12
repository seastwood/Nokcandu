/* Description-only reproduction of upstream HIDAPI's CM metadata chain.
 * No device handles or report I/O; no serials, paths or hardware-ID strings printed. */
#include <windows.h>
#include <setupapi.h>
#include <cfgmgr32.h>
#include <hidsdi.h>
#include <initguid.h>
#include <devpkey.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
static unsigned has(WCHAR *v, ULONG bytes,const WCHAR *token){
 for(ULONG i=0;i+1<bytes/sizeof(WCHAR);++i)if(v[i]>=L'a'&&v[i]<=L'z')v[i]-=L'a'-L'A';
 for(WCHAR *p=v;p<v+bytes/sizeof(WCHAR)&&*p;p+=wcslen(p)+1)if(wcsstr(p,token))return 1;
 return 0;
}
int main(void){GUID guid;HidD_GetHidGuid(&guid);HDEVINFO list=SetupDiGetClassDevsW(&guid,NULL,NULL,DIGCF_PRESENT|DIGCF_DEVICEINTERFACE);
 for(DWORD i=0;;++i){SP_DEVICE_INTERFACE_DATA item={0};item.cbSize=sizeof(item);if(!SetupDiEnumDeviceInterfaces(list,NULL,&guid,i,&item))break;
  DWORD size=0;SetupDiGetDeviceInterfaceDetailW(list,&item,NULL,0,&size,NULL);PSP_DEVICE_INTERFACE_DETAIL_DATA_W detail=calloc(1,size);if(!detail)continue;detail->cbSize=sizeof(*detail);
  SP_DEVINFO_DATA info={0};info.cbSize=sizeof(info);
  if(!SetupDiGetDeviceInterfaceDetailW(list,&item,detail,size,NULL,&info)){free(detail);continue;}
  for(WCHAR *p=detail->DevicePath;*p;++p)if(*p>=L'A'&&*p<=L'Z')*p+=L'a'-L'A';
  if(!wcsstr(detail->DevicePath,L"vid_28de&pid_1102")){free(detail);continue;}
  WCHAR value[2048]={0};ULONG n=sizeof(value);DEVPROPTYPE type=0;
  CONFIGRET r=CM_Get_Device_Interface_PropertyW(detail->DevicePath,&DEVPKEY_Device_InstanceId,&type,(BYTE*)value,&n,0);
  printf("Interface instance-property result=%lu type=%lu\n",r,type);DEVINST node=0;
  if(r==CR_SUCCESS){r=CM_Locate_DevNodeW(&node,value,CM_LOCATE_DEVNODE_NORMAL);printf("Locate instance result=%lu\n",r);}
  if(r!=CR_SUCCESS)node=info.DevInst;
  for(int depth=0;depth<4;++depth){
   n=sizeof(value);type=0;memset(value,0,sizeof(value));r=CM_Get_DevNode_PropertyW(node,&DEVPKEY_Device_CompatibleIds,&type,(BYTE*)value,&n,0);
   printf("Node depth=%d compatible-property result=%lu USB=%u\n",depth,r,r==CR_SUCCESS?has(value,n,L"USB"):0);
   n=sizeof(value);memset(value,0,sizeof(value));r=CM_Get_DevNode_PropertyW(node,&DEVPKEY_Device_HardwareIds,&type,(BYTE*)value,&n,0);
   printf("Node depth=%d hardware-property result=%lu interface2=%u\n",depth,r,r==CR_SUCCESS?has(value,n,L"MI_02"):0);
   DEVINST parent=0;r=CM_Get_Parent(&parent,node,0);printf("Parent query result=%lu\n",r);if(r!=CR_SUCCESS)break;node=parent;
  }
  free(detail);
 }
 SetupDiDestroyDeviceInfoList(list);return 0;
}
