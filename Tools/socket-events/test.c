/* Hardware-free boundary test: no sockets are opened. */
#include <poll.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <netinet/tcp_fsm.h>
#include <mach-o/dyld.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
static int queries, reads;
static int fake_poll(struct pollfd *p,nfds_t n,int timeout){(void)p;(void)timeout;errno=EDOM;return (int)n;}
static int fake_info(int fd,int level,int option,void *data,socklen_t *size){(void)level;(void)option;queries++;if(fd==4){errno=ENOTSOCK;return -1;}struct tcp_connection_info *p=data;memset(p,0,sizeof(*p));p->tcpi_state=fd==2?TCPS_CLOSED:TCPS_CLOSE_WAIT;*size=fd==5?0:sizeof(*p);return 0;}
static ssize_t fake_recv(int fd,void *data,size_t size,int flags){(void)data;(void)size;(void)flags;reads++;if(fd==3)return 1;errno=fd==6?ECONNRESET:EINVAL;return -1;}
#define poll fake_poll
#define getsockopt fake_info
#define recv fake_recv
#define NOKCANDU_SOCKET_TEST 1
#include "socket-events.c"
#define CHECK(x) do{if(!(x)){fprintf(stderr,"line %d: %s\n",__LINE__,#x);return 1;}}while(0)
int main(void){
 struct pollfd p[]={{1,POLLIN|POLLPRI,POLLPRI|POLLHUP},{1,POLLIN,POLLERR},{2,POLLOUT,POLLERR},{3,POLLPRI,POLLPRI|POLLHUP},{4,POLLIN,POLLERR},{5,POLLIN,POLLERR},{6,POLLIN,POLLERR},{1,POLLIN,POLLIN}};
 socket_server_process=0;CHECK(socket_event_poll(p,8,0)==8);CHECK(queries==0&&reads==0);CHECK(errno==EDOM);CHECK(p[0].revents==(POLLPRI|POLLHUP));
 socket_server_process=1;CHECK(socket_event_poll(p,8,0)==8);CHECK(errno==EDOM);
 CHECK(p[0].revents==(POLLIN|POLLHUP));CHECK(p[1].revents==POLLIN);
 CHECK(p[2].revents==POLLERR);CHECK(p[3].revents==(POLLPRI|POLLHUP));CHECK(p[4].revents==POLLERR);CHECK(p[5].revents==POLLERR);CHECK(p[6].revents==POLLERR);CHECK(p[7].revents==POLLIN);
 puts("Closed TCP readiness normalized; real errors/OOB, non-sockets, game processes and errno preserved.");return 0;
}
