/* macOS can report POLLPRI|POLLHUP for TCP EOF when poll() requests urgent
 * data. Wine maps POLLPRI to Winsock's exception set; normal EOF belongs in
 * the read set. Normalize only confirmed clean TCP closes in wineserver.
 * No server protocol changes, endpoint rewrites or game-process hooks. */
#include <poll.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <netinet/tcp_fsm.h>
#include <mach-o/dyld.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>

#ifndef NOKCANDU_SOCKET_TEST
extern void nokcandu_record_loaded_helper(void);
#endif
static int socket_server_process;
__attribute__((constructor)) static void identify_socket_server(void)
{
    char path[4096];
    uint32_t size = sizeof(path);
    if (!_NSGetExecutablePath(path, &size)) {
        const char *name = strrchr(path, '/');
        socket_server_process = name && !strcmp(name + 1, "wineserver");
    }
}

static int clean_tcp_close(int fd)
{
    struct tcp_connection_info info;
    socklen_t size = sizeof(info);
    if (getsockopt(fd, IPPROTO_TCP, TCP_CONNECTION_INFO, &info, &size) ||
        size < offsetof(struct tcp_connection_info, tcpi_state) + sizeof(info.tcpi_state) ||
        info.tcpi_state != TCPS_CLOSE_WAIT) return 0;

    /* A peer may send real urgent data before FIN. PEEK preserves it and never
     * logs data. Do not consume SO_ERROR: the application still needs its error. */
    char urgent;
    ssize_t n = recv(fd, &urgent, 1, MSG_OOB | MSG_PEEK | MSG_DONTWAIT);
    return n == 0 || (n < 0 && (errno == EINVAL || errno == EAGAIN || errno == EWOULDBLOCK));
}

static int socket_event_poll(struct pollfd *fds, nfds_t count, int timeout)
{
    int before = errno;
#ifndef NOKCANDU_SOCKET_TEST
    // The server can daemonize after constructors ran. Record the child too;
    // this is a cheap PID comparison after the first call in each process.
    if (socket_server_process) nokcandu_record_loaded_helper();
#endif
    errno = before;
    int result = poll(fds, count, timeout), saved = errno;
    if (socket_server_process && result > 0) {
        for (nfds_t i = 0; i < count; i++) {
            short events = fds[i].revents;
            if (!(events & POLLERR) && (events & (POLLPRI | POLLHUP)) != (POLLPRI | POLLHUP)) continue;
            if (clean_tcp_close(fds[i].fd)) fds[i].revents = (events & ~(POLLERR | POLLPRI)) | POLLIN;
        }
    }
    errno = saved;
    return result;
}

#ifndef NOKCANDU_SOCKET_TEST
__attribute__((used)) static const struct { const void *replacement, *original; } socket_interpose
    __attribute__((section("__DATA,__interpose"))) = { socket_event_poll, poll };
#endif
