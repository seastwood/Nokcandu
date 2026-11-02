/* Regression for Wine's native WinPcap path. Uses only a self-addressed test
 * Ethernet frame (experimental type 0x88b5), never game traffic or peer files.
 * Requires temporary packet access and a matching Wine wpcap module.
 * Usage: native-capture.exe en0 5e:cd:64:63:1c:b8
 * Build against the upstream WinPcap headers used by IPXWrapper. */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#define HAVE_REMOTE
#include <pcap.h>
#define API(type, name) type name = (type)GetProcAddress(module, #name)
typedef int (__cdecl *find_fn)(char*,struct pcap_rmtauth*,pcap_if_t**,char*);
typedef pcap_t* (__cdecl *open_fn)(const char*,int,int,int,struct pcap_rmtauth*,char*);
typedef HANDLE (__cdecl *event_fn)(pcap_t*);
typedef int (__cdecl *compile_fn)(pcap_t*,struct bpf_program*,const char*,int,bpf_u_int32);
typedef int (__cdecl *filter_fn)(pcap_t*,struct bpf_program*);
typedef void (__cdecl *freecode_fn)(struct bpf_program*);
typedef int (__cdecl *send_fn)(pcap_t*,const u_char*,int);
typedef int (__cdecl *next_fn)(pcap_t*,struct pcap_pkthdr**,const u_char**);
typedef void (__cdecl *close_fn)(pcap_t*);
typedef void (__cdecl *free_fn)(pcap_if_t*);
int main(int argc,char **argv) {
 setvbuf(stdout,NULL,_IONBF,0);
 if(argc!=3){puts("Supply the adapter description and its physical MAC address.");return 2;}
 HMODULE module=LoadLibraryA("wpcap.dll");if(!module){printf("Load failed: %lu\n",GetLastError());return 3;}
 API(find_fn,pcap_findalldevs_ex); API(open_fn,pcap_open); API(event_fn,pcap_getevent);
 API(compile_fn,pcap_compile);API(filter_fn,pcap_setfilter);API(freecode_fn,pcap_freecode);
 API(send_fn,pcap_sendpacket);API(next_fn,pcap_next_ex);API(close_fn,pcap_close);API(free_fn,pcap_freealldevs);
 if(!pcap_findalldevs_ex||!pcap_open||!pcap_getevent||!pcap_compile||!pcap_setfilter||!pcap_freecode||!pcap_sendpacket||!pcap_next_ex||!pcap_close||!pcap_freealldevs)return 4;
 char error[PCAP_ERRBUF_SIZE]={0};pcap_if_t *list=NULL,*adapter=NULL;
 if(pcap_findalldevs_ex("rpcap://",NULL,&list,error)){puts(error);return 5;}
 for(pcap_if_t*i=list;i;i=i->next)if(i->description&&!strcmp(i->description,argv[1])){adapter=i;break;}
 if(!adapter){puts("Adapter not found");return 6;}
 unsigned int mac[6];if(sscanf(argv[2],"%x:%x:%x:%x:%x:%x",&mac[0],&mac[1],&mac[2],&mac[3],&mac[4],&mac[5])!=6)return 7;
 unsigned char frame[60]={0};for(int i=0;i<6;i++){if(mac[i]>255)return 7;frame[i]=frame[i+6]=(unsigned char)mac[i];}frame[12]=0x88;frame[13]=0xb5;memcpy(frame+14,"Nokcandu capture regression",26);
 for(int cycle=0;cycle<3;cycle++){
  pcap_t *capture=pcap_open(adapter->name,2048,PCAP_OPENFLAG_MAX_RESPONSIVENESS,-1,NULL,error);
  if(!capture){puts(error);return 8;}
  struct bpf_program filter;
  if(pcap_compile(capture,&filter,"ether proto 0x88b5",1,0)){puts("Compile failed");return 9;}
  int filtered=pcap_setfilter(capture,&filter);pcap_freecode(&filter);if(filtered)return 10;
  HANDLE event=pcap_getevent(capture);if(!event||event==INVALID_HANDLE_VALUE)return 11;
  if(pcap_getevent(capture)!=event){puts("Event handle changed");return 12;}
  if(pcap_sendpacket(capture,frame,sizeof(frame))){puts("Send failed");return 13;}
  if(WaitForSingleObject(event,3000)!=WAIT_OBJECT_0){puts("Packet notification timed out");return 14;}
  struct pcap_pkthdr *hdr=NULL;const u_char *data=NULL;int found=0,ret;
  while((ret=pcap_next_ex(capture,&hdr,&data))==1)if(hdr->caplen>=sizeof(frame)&&!memcmp(data,frame,sizeof(frame)))found=1;
  if(ret!=0||!found){puts("Packet payload or nonblocking read failed");return 15;}
  /* Drain/reset the notification before closing; close must also work while
   * the event worker is waiting and must not leave the process hanging. */
  pcap_close(capture);Sleep(150);
  printf("Cycle %d: immediate capture, event, payload and close passed\n",cycle+1);
 }
 pcap_freealldevs(list);FreeLibrary(module);return 0;
}
