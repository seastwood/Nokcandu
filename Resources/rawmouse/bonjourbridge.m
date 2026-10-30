// Nokcandu: Bonjour for Windows games, answered by the Mac's own Bonjour.
//
// Windows programs reach Bonjour through Apple's client library (dnssd.dll, or a copy built into the game, as in
// Blizzard's games), which talks to the Bonjour service over a local TCP connection on 127.0.0.1:5354. On the
// Mac the same service (mDNSResponder) is already running, reached over a Unix socket, and speaks the same
// protocol. This part of Nokcandu's helper library, loaded into every Wine process, listens on 127.0.0.1:5354
// and relays each connection to the Mac's mDNSResponder, so games advertise and find each other with macOS's own
// Bonjour: no Windows Bonjour service needed.
//
// The protocol is identical except for one thing: some requests carry a separate socket for their result code.
// A Windows client puts the TCP port of a socket it listens on in front of the request data and waits for the
// service to connect to it; a Mac client sends the socket itself (SCM_RIGHTS) and an empty name instead. The
// relay translates those requests.
//
// Every Wine process tries to listen; one gets the port and serves everyone (games share the Mac's loopback).
// When that process quits, another takes over within seconds.

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define BRIDGE_PORT 5354
#define DAEMON_PATH "/var/run/mDNSResponder"
#define HDR_SIZE 28                 // version, datalen, ipc_flags, op, client_context (8), reg_index
#define IPC_FLAGS_NOERRSD (1u << 2)
#define CANCEL_REQUEST 63
#define MAX_DATA 70000

static void bb_log(const char *fmt, ...)
{
    if (!getenv("NOKCANDU_BONJOUR_DEBUG")) return;
    va_list a;
    va_start(a, fmt);
    fprintf(stderr, "nokcandu-bonjour[%d]: ", (int)getpid());
    vfprintf(stderr, fmt, a);
    fputc('\n', stderr);
    va_end(a);
}

static int read_all(int fd, void *buf, size_t len)
{
    char *p = buf;
    while (len)
    {
        ssize_t n = read(fd, p, len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

static int write_all(int fd, const void *buf, size_t len)
{
    const char *p = buf;
    while (len)
    {
        ssize_t n = write(fd, p, len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

static void no_sigpipe(int fd)
{
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
}

// Every socket here stays in this process: a program this process starts must not inherit them (an inherited
// listening socket would hold the port with nobody answering, and games would wait forever).
static int cloexec(int fd)
{
    if (fd >= 0) fcntl(fd, F_SETFD, FD_CLOEXEC);
    return fd;
}

struct pipe_args { int from, to, owns; };

// Copies one direction until either side closes. A result relay owns its two sockets and closes them.
static void *pump(void *arg)
{
    struct pipe_args a = *(struct pipe_args *)arg;
    char buf[16384];
    ssize_t n;
    free(arg);
    while ((n = read(a.from, buf, sizeof(buf))) > 0 || (n < 0 && errno == EINTR))
        if (n > 0 && write_all(a.to, buf, (size_t)n)) break;
    shutdown(a.to, SHUT_WR);
    shutdown(a.from, SHUT_RD);
    if (a.owns) { close(a.from); close(a.to); }
    return NULL;
}

static int start_pump(int from, int to, int owns, pthread_t *joinable)
{
    pthread_t t;
    struct pipe_args *a = malloc(sizeof(*a));
    if (!a) return -1;
    a->from = from;
    a->to = to;
    a->owns = owns;
    if (pthread_create(&t, NULL, pump, a)) { free(a); return -1; }
    if (joinable) *joinable = t;
    else pthread_detach(t);
    return 0;
}

static int connect_daemon(void)
{
    struct sockaddr_un sa = { .sun_family = AF_UNIX };
    int fd = cloexec(socket(AF_UNIX, SOCK_STREAM, 0));
    if (fd < 0) return -1;
    strlcpy(sa.sun_path, DAEMON_PATH, sizeof(sa.sun_path));
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) { close(fd); return -1; }
    no_sigpipe(fd);
    return fd;
}

static int connect_loopback(uint16_t port_be)
{
    struct sockaddr_in sa = { .sin_len = sizeof(sa), .sin_family = AF_INET, .sin_port = port_be };
    int fd = cloexec(socket(AF_INET, SOCK_STREAM, 0));
    if (fd < 0) return -1;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) { close(fd); return -1; }
    no_sigpipe(fd);
    return fd;
}

// Sends a request with its separate result socket the Mac way: the data minus its last byte, then the last
// byte together with the socket.
static int send_with_fd(int daemon, const uint8_t *msg, size_t len, int fd)
{
    struct iovec vec = { (void *)(msg + len - 1), 1 };
    char cbuf[CMSG_SPACE(sizeof(int))];
    struct msghdr m = { 0 };
    struct cmsghdr *c;

    if (write_all(daemon, msg, len - 1)) return -1;
    memset(cbuf, 0, sizeof(cbuf));
    m.msg_iov = &vec;
    m.msg_iovlen = 1;
    m.msg_control = cbuf;
    m.msg_controllen = CMSG_LEN(sizeof(int));
    c = CMSG_FIRSTHDR(&m);
    c->cmsg_len = CMSG_LEN(sizeof(int));
    c->cmsg_level = SOL_SOCKET;
    c->cmsg_type = SCM_RIGHTS;
    memcpy(CMSG_DATA(c), &fd, sizeof(int));
    while (sendmsg(daemon, &m, 0) < 0)
        if (errno != EINTR) return -1;
    return 0;
}

static uint32_t get32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return ntohl(v); }
static void put32(uint8_t *p, uint32_t v) { v = htonl(v); memcpy(p, &v, 4); }

struct client_args { int client; };

// One Windows client connection: requests from the game go to the daemon (translated where needed); the
// daemon's replies go straight back.
static void *serve_client(void *arg)
{
    int client = ((struct client_args *)arg)->client, daemon;
    pthread_t replies;
    uint8_t *msg = NULL;
    int first = 1;
    free(arg);

    no_sigpipe(client);
    if ((daemon = connect_daemon()) < 0)
    {
        bb_log("can't reach the Mac's Bonjour service (%s)", strerror(errno));
        close(client);
        return NULL;
    }
    // Replies (and the daemon closing) flow back on their own.
    if (start_pump(daemon, client, 0, &replies)) { close(daemon); close(client); return NULL; }

    for (;;)
    {
        uint8_t hdr[HDR_SIZE];
        uint32_t datalen, flags, op;
        int separate;

        if (read_all(client, hdr, HDR_SIZE)) break;
        datalen = get32(hdr + 4);
        flags = get32(hdr + 8);
        op = get32(hdr + 12);
        if (get32(hdr) != 1 || datalen > MAX_DATA) { bb_log("bad request header"); break; }
        free(msg);
        if (!(msg = malloc(HDR_SIZE + datalen + 1))) break;
        memcpy(msg, hdr, HDR_SIZE);
        if (datalen && read_all(client, msg + HDR_SIZE, datalen)) break;

        // The daemon expects a separate result socket for every request after a connection's first one
        // (records added to a registration, operations on a shared connection), except cancels and requests
        // flagged as having none.
        separate = !first && op != CANCEL_REQUEST && !(flags & IPC_FLAGS_NOERRSD) && datalen >= 2;
        first = 0;
        bb_log("request op %u, %u bytes%s", op, datalen, separate ? ", separate result socket" : "");

        if (!separate)
        {
            if (write_all(daemon, msg, HDR_SIZE + datalen)) break;
            continue;
        }
        else
        {
            uint16_t port_be;
            int sp[2], back;
            uint32_t newlen = datalen - 1;     // 2-byte port becomes a 1-byte empty name

            memcpy(&port_be, msg + HDR_SIZE, 2);
            memmove(msg + HDR_SIZE + 1, msg + HDR_SIZE + 2, datalen - 2);
            msg[HDR_SIZE] = 0;
            put32(msg + 4, newlen);
            if (socketpair(AF_UNIX, SOCK_STREAM, 0, sp) < 0) break;
            cloexec(sp[0]);
            cloexec(sp[1]);
            no_sigpipe(sp[0]);
            if (send_with_fd(daemon, msg, HDR_SIZE + newlen, sp[1])) { close(sp[0]); close(sp[1]); break; }
            close(sp[1]);
            // The game waits for the result on the port it gave: connect to it and pass the result along.
            if ((back = connect_loopback(port_be)) < 0)
            {
                bb_log("can't connect back to the game's result port %u", ntohs(port_be));
                close(sp[0]);
                continue;
            }
            if (start_pump(sp[0], back, 1, NULL)) { close(sp[0]); close(back); }
        }
    }
    free(msg);
    shutdown(daemon, SHUT_RDWR);
    shutdown(client, SHUT_RDWR);
    pthread_join(replies, NULL);
    close(daemon);
    close(client);
    return NULL;
}

static void *listen_loop(void *unused)
{
    for (;;)
    {
        struct sockaddr_in sa = { .sin_len = sizeof(sa), .sin_family = AF_INET, .sin_port = htons(BRIDGE_PORT) };
        int fd = cloexec(socket(AF_INET, SOCK_STREAM, 0)), on = 1;

        sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (fd >= 0)
        {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
            if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) == 0 && listen(fd, 16) == 0)
            {
                bb_log("relaying Windows Bonjour (127.0.0.1:%d) to the Mac's Bonjour", BRIDGE_PORT);
                for (;;)
                {
                    int c = cloexec(accept(fd, NULL, NULL));
                    if (c < 0)
                    {
                        if (errno == EINTR || errno == ECONNABORTED) continue;
                        break;
                    }
                    {
                        pthread_t t;
                        struct client_args *a = malloc(sizeof(*a));
                        if (!a) { close(c); continue; }
                        a->client = c;
                        if (pthread_create(&t, NULL, serve_client, a) == 0) pthread_detach(t);
                        else { free(a); close(c); }
                    }
                }
            }
            close(fd);
        }
        // Another process has the port (or it failed): try again later, in case that process quits.
        sleep(3);
    }
    return unused;
}

__attribute__((constructor))
static void bonjour_bridge_init(void)
{
    pthread_t t;
    const char *name = getprogname();
    if (getenv("NOKCANDU_NO_BONJOUR")) return;
    // Not in Wine's server; any of the game's processes will do.
    if (name && !strcmp(name, "wineserver")) return;
    if (pthread_create(&t, NULL, listen_loop, NULL) == 0) pthread_detach(t);
}
