/* Read-only adapter identities as seen by Wine and the IPX capture module. */
#include <winsock2.h>
#include <windows.h>
#include <iphlpapi.h>
#include <stdio.h>
#include <stdlib.h>
int main(void){ULONG size=0;GetAdaptersInfo(NULL,&size);IP_ADAPTER_INFO*data=malloc(size);if(GetAdaptersInfo(data,&size))return 1;for(IP_ADAPTER_INFO*i=data;i;i=i->Next){printf("%s|%s|",i->Description,i->AdapterName);for(unsigned j=0;j<i->AddressLength;j++)printf("%s%02X",j?":":"",i->Address[j]);printf("|%s\n",i->IpAddressList.IpAddress.String);}free(data);return 0;}
