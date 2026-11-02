/* Tests legacy DirectPlay host session and player creation. No argument: legacy IPX;
 * ipx: COM IPX; tcp: COM TCP/IP with explicit loopback address;
 * scan: legacy IPX session enumeration across all application GUIDs. */
#define COBJMACROS
#include <windows.h>
#include <objbase.h>
#include <dplay.h>
#include <dplobby.h>
#include <stdio.h>
#include <string.h>
static BOOL FAR PASCAL found_session(LPCDPSESSIONDESC2 desc, LPDWORD timeout, DWORD flags, LPVOID context) {
 (void)timeout; (void)context;
 if(flags & DPESC_TIMEDOUT)return FALSE;
 printf("Session: %s\n",desc->lpszSessionNameA?desc->lpszSessionNameA:"(unnamed)");return TRUE;
}
int main(int argc, char **argv) {
 setvbuf(stdout,NULL,_IONBF,0);
 GUID ipx={0x685bc400,0x9d2c,0x11cf,{0xa9,0xcd,0,0xaa,0,0x68,0x86,0xe3}};
 if(argc>1 && !strcmp(argv[1], "tcp")) ipx=(GUID){0x36e95ee0,0x8577,0x11cf,{0x96,0x0c,0,0x80,0xc7,0x53,0x4e,0x82}};
 puts("Starting DirectPlay probe"); CoInitialize(NULL); puts("COM initialized"); HMODULE lib=LoadLibraryA("dplayx.dll"); puts("DirectPlay library loaded");
 typedef HRESULT(WINAPI *create_fn)(LPGUID,LPDIRECTPLAY*,IUnknown*);
 create_fn create=(create_fn)GetProcAddress(lib,"DirectPlayCreate"); LPDIRECTPLAY old=NULL; LPDIRECTPLAY4A dp=NULL;
 int tcp=argc>1 && !strcmp(argv[1], "tcp"), useCOM=argc>1 && strcmp(argv[1],"scan");
 HRESULT hr=useCOM?CoCreateInstance(&CLSID_DirectPlay,NULL,CLSCTX_INPROC_SERVER,&IID_IDirectPlay4A,(void**)&dp):create(&ipx,&old,NULL); printf("Initialize %08lx\n",hr); if(FAILED(hr))return 1;
 if(!useCOM) { hr=IDirectPlay_QueryInterface(old,&IID_IDirectPlay4A,(void**)&dp); IDirectPlay_Release(old); } printf("Interface %08lx\n",hr); if(FAILED(hr))return 2;
 if(useCOM) {
  typedef HRESULT(WINAPI *lobby_fn)(LPGUID,LPDIRECTPLAYLOBBYA*,IUnknown*,LPVOID,DWORD);
  lobby_fn makeLobby=(lobby_fn)GetProcAddress(lib,"DirectPlayLobbyCreateA");
  LPDIRECTPLAYLOBBYA first=NULL; LPDIRECTPLAYLOBBY3A lobby=NULL;
  hr=makeLobby(NULL,&first,NULL,NULL,0);if(FAILED(hr))return 5;
  hr=IDirectPlayLobby_QueryInterface(first,&IID_IDirectPlayLobby3A,(void**)&lobby);IDirectPlayLobby_Release(first);if(FAILED(hr))return 6;
  char address[]="127.0.0.1";DPCOMPOUNDADDRESSELEMENT elements[2]={{DPAID_ServiceProvider,sizeof(ipx),&ipx},{DPAID_INet,sizeof(address),address}};
  DWORD size=0;IDirectPlayLobby_CreateCompoundAddress(lobby,elements,tcp?2:1,NULL,&size);void* data=malloc(size);
  hr=IDirectPlayLobby_CreateCompoundAddress(lobby,elements,tcp?2:1,data,&size);if(FAILED(hr))return 7;
  hr=IDirectPlayX_InitializeConnection(dp,data,0);free(data);IDirectPlayLobby_Release(lobby);printf("Provider connection %08lx\n",hr);if(FAILED(hr))return 8;
 }
 if(argc>1 && !strcmp(argv[1],"scan")) {
  DPSESSIONDESC2 query={0};query.dwSize=sizeof(query);
  hr=IDirectPlayX_EnumSessions(dp,&query,4000,found_session,NULL,DPENUMSESSIONS_ALL);
  printf("IPX session scan %08lx\n",hr);IDirectPlayX_Release(dp);CoUninitialize();return FAILED(hr)?9:0;
 }
 DPSESSIONDESC2 desc={0};desc.dwSize=sizeof(desc);desc.dwMaxPlayers=4;desc.lpszSessionNameA="Nokcandu regression";desc.guidApplication=(GUID){0x6c70786e,0x0192,0x4ffe,{0x88,0,0,0,0,0,0,1}};
 hr=IDirectPlayX_Open(dp,&desc,DPOPEN_CREATE);printf("Host session %08lx\n",hr); if(FAILED(hr))return 3;
 DPNAME name={0};name.dwSize=sizeof(name);name.lpszShortNameA="Host";DPID id;
 hr=IDirectPlayX_CreatePlayer(dp,&id,&name,NULL,NULL,0,0);printf("Create host player %08lx\n",hr);if(FAILED(hr))return 4;
 IDirectPlayX_DestroyPlayer(dp,id);IDirectPlayX_Close(dp);IDirectPlayX_Release(dp);CoUninitialize();puts("DirectPlay hosting passed");return 0;
}
