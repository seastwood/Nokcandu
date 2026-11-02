#include <windows.h>
#include <stdio.h>
#define HAVE_REMOTE
#include <pcap.h>
int main(void){
 setvbuf(stdout,NULL,_IONBF,0);HMODULE m=LoadLibraryA("wpcap.dll");
 if(!m){printf("wpcap load failed: %lu\n",GetLastError());return 1;}
 typedef int(__cdecl *find_fn)(char*,struct pcap_rmtauth*,pcap_if_t**,char*);
 typedef pcap_t*(__cdecl *open_fn)(const char*,int,int,int,char*);
 typedef void(__cdecl *close_fn)(pcap_t*);
 typedef void(__cdecl *free_fn)(pcap_if_t*);
 find_fn find=(find_fn)GetProcAddress(m,"pcap_findalldevs_ex");open_fn open=(open_fn)GetProcAddress(m,"pcap_open_live");close_fn close=(close_fn)GetProcAddress(m,"pcap_close");free_fn release=(free_fn)GetProcAddress(m,"pcap_freealldevs");
 if(!find||!open||!close||!release){puts("Required packet-capture APIs missing");return 2;}
 pcap_if_t* list=NULL;char error[PCAP_ERRBUF_SIZE]={0};
 if(find("rpcap://",NULL,&list,error)){printf("enumeration failed: %s\n",error);return 3;}
 int n=0,opened=0;
 for(pcap_if_t*i=list;i;i=i->next){printf("Adapter: %s | %s\n",i->name,i->description?i->description:"");n++;pcap_t*p=open(i->name,2048,0,10,error);if(p){opened++;puts("Capture access available");close(p);}else printf("Capture access: %s\n",error);}
 release(list);FreeLibrary(m);printf("Adapters listed: %d; capture handles opened: %d\n",n,opened);return n?0:4;
}
