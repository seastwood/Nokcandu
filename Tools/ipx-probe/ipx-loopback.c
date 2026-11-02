/* A minimal Winsock 1 IPX bind/send/receive regression. No game or account data. */
#include <winsock.h>
#include <wsipx.h>
#include <stdio.h>
#include <string.h>
int main(void) {
 WSADATA w; if(WSAStartup(MAKEWORD(1,1),&w)){puts("WSAStartup failed");return 1;}
 SOCKET rx=socket(AF_IPX,SOCK_DGRAM,NSPROTO_IPX),tx=INVALID_SOCKET;
 int status=1; const char payload[]="Nokcandu IPX probe";
 if(rx==INVALID_SOCKET){printf("IPX socket unsupported: WSA error %d\n",WSAGetLastError());WSACleanup();return 2;}
 SOCKADDR_IPX address={0};address.sa_family=AF_IPX;
 if(bind(rx,(struct sockaddr*)&address,sizeof(address))){printf("IPX bind failed: %d\n",WSAGetLastError());goto done;}
 int length=sizeof(address);
 if(getsockname(rx,(struct sockaddr*)&address,&length)){puts("IPX address unavailable");goto done;}
 tx=socket(AF_IPX,SOCK_DGRAM,NSPROTO_IPX);
 if(tx==INVALID_SOCKET){puts("IPX sender unavailable");goto done;}
 SOCKADDR_IPX local={0};local.sa_family=AF_IPX;
 if(bind(tx,(struct sockaddr*)&local,sizeof(local))){printf("IPX sender bind failed: %d\n",WSAGetLastError());goto done;}
 if(sendto(tx,payload,sizeof(payload),0,(struct sockaddr*)&address,sizeof(address))!=sizeof(payload)){printf("IPX send failed: %d\n",WSAGetLastError());goto done;}
 fd_set read;FD_ZERO(&read);FD_SET(rx,&read);struct timeval timeout={3,0};
 if(select(0,&read,NULL,NULL,&timeout)!=1){puts("IPX receive timed out");goto done;}
 char received[64];int n=recv(rx,received,sizeof(received),0);
 if(n!=sizeof(payload)||memcmp(received,payload,sizeof(payload))){puts("IPX payload mismatch");goto done;}
 puts("IPX socket, bind, address, send and receive passed.");status=0;
done:
 if(tx!=INVALID_SOCKET)closesocket(tx);closesocket(rx);WSACleanup();return status;
}
