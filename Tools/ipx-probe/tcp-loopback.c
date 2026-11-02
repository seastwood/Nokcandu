/* Verifies that optional IPX shims preserve ordinary Winsock 1 TCP/IP. */
#include <winsock.h>
#include <stdio.h>
#include <string.h>
int main(void){
 WSADATA w;if(WSAStartup(MAKEWORD(1,1),&w))return 1;
 SOCKET server=socket(AF_INET,SOCK_STREAM,0),client=INVALID_SOCKET,peer=INVALID_SOCKET;
 int result=1;struct sockaddr_in address={0};address.sin_family=AF_INET;address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
 if(server==INVALID_SOCKET||bind(server,(void*)&address,sizeof(address))||listen(server,1))goto done;
 int size=sizeof(address);if(getsockname(server,(void*)&address,&size))goto done;
 client=socket(AF_INET,SOCK_STREAM,0);if(client==INVALID_SOCKET||connect(client,(void*)&address,sizeof(address)))goto done;
 peer=accept(server,NULL,NULL);if(peer==INVALID_SOCKET)goto done;
 const char message[]="Nokcandu TCP probe";DWORD timeout=3000;setsockopt(peer,SOL_SOCKET,SO_RCVTIMEO,(const char*)&timeout,sizeof(timeout));
 if(send(client,message,sizeof(message),0)!=sizeof(message))goto done;
 char bytes[64];int n=recv(peer,bytes,sizeof(bytes),0);if(n!=sizeof(message)||memcmp(bytes,message,sizeof(message)))goto done;
 puts("TCP/IP socket, bind, listen, connect, accept, send and receive passed.");result=0;
done:if(result)printf("TCP/IP probe failed: %d\n",WSAGetLastError());
 if(peer!=INVALID_SOCKET)closesocket(peer);if(client!=INVALID_SOCKET)closesocket(client);if(server!=INVALID_SOCKET)closesocket(server);WSACleanup();return result;
}
