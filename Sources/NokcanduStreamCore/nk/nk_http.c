// SPDX-License-Identifier: GPL-3.0-only
// A small blocking HTTP/1.1 GET over a plain or TLS socket, for the GameStream host API (Sunshine and
// compatible hosts). HTTPS presents this Mac's client certificate and pins the host's certificate.
#include "nk_net.h"

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <mbedtls/ctr_drbg.h>
#include <mbedtls/error.h>
#include <mbedtls/entropy.h>
#include <mbedtls/net_sockets.h>
#include <mbedtls/pk.h>
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>

static long long nk_now_ms(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return (long long)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

/// Connects with a deadline, trying each address in turn. Returns the socket or a negative error.
static int nk_connect(const char* host, uint16_t port, long long deadline, volatile int* cancel) {
    char portStr[8]; snprintf(portStr, sizeof portStr, "%u", port);
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_socktype = SOCK_STREAM; hints.ai_family = AF_UNSPEC;
    if (getaddrinfo(host, portStr, &hints, &res) != 0 || !res) return NK_HTTP_ERR_RESOLVE;
    int result = NK_HTTP_ERR_CONNECT;
    for (struct addrinfo* a = res; a; a = a->ai_next) {
        int fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd < 0) continue;
        int one = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        int flags = fcntl(fd, F_GETFL, 0); fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        int rc = connect(fd, a->ai_addr, a->ai_addrlen);
        if (rc < 0 && errno == EINPROGRESS) {
            for (;;) {
                if (cancel && *cancel) { close(fd); freeaddrinfo(res); return NK_HTTP_ERR_CANCELLED; }
                long long left = deadline - nk_now_ms();
                if (left <= 0) { rc = -1; result = NK_HTTP_ERR_TIMEOUT; break; }
                struct pollfd p = { fd, POLLOUT, 0 };
                int n = poll(&p, 1, left < 100 ? (int)left : 100);
                if (n > 0) {
                    int err = 0; socklen_t el = sizeof err;
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);
                    rc = err ? -1 : 0;
                    break;
                }
                if (n < 0 && errno != EINTR) { rc = -1; break; }
            }
        }
        if (rc == 0) {
            fcntl(fd, F_SETFL, flags);
            freeaddrinfo(res);
            return fd;
        }
        close(fd);
    }
    freeaddrinfo(res);
    return result;
}

typedef struct {
    int fd;
    int tls;
    mbedtls_ssl_context* ssl;
    long long deadline;
    volatile int* cancel;
} nk_conn;

/// Waits until the socket is readable (or writable), honouring the deadline and cancellation.
static int nk_wait(nk_conn* c, short events) {
    for (;;) {
        if (c->cancel && *c->cancel) return NK_HTTP_ERR_CANCELLED;
        long long left = c->deadline - nk_now_ms();
        if (left <= 0) return NK_HTTP_ERR_TIMEOUT;
        struct pollfd p = { c->fd, events, 0 };
        int n = poll(&p, 1, left < 100 ? (int)left : 100);
        if (n > 0) return 0;
        if (n < 0 && errno != EINTR) return NK_HTTP_ERR_IO;
    }
}

static int nk_bio_send(void* ctx, const unsigned char* buf, size_t len) {
    nk_conn* c = (nk_conn*)ctx;
    int w = nk_wait(c, POLLOUT);
    if (w) return MBEDTLS_ERR_NET_SEND_FAILED;
    ssize_t n = send(c->fd, buf, len, 0);
    if (n < 0) return (errno == EAGAIN || errno == EINTR) ? MBEDTLS_ERR_SSL_WANT_WRITE : MBEDTLS_ERR_NET_SEND_FAILED;
    return (int)n;
}

static int nk_bio_recv(void* ctx, unsigned char* buf, size_t len) {
    nk_conn* c = (nk_conn*)ctx;
    int w = nk_wait(c, POLLIN);
    if (w) return w == NK_HTTP_ERR_TIMEOUT ? MBEDTLS_ERR_SSL_TIMEOUT : MBEDTLS_ERR_NET_RECV_FAILED;
    ssize_t n = recv(c->fd, buf, len, 0);
    if (n < 0) return (errno == EAGAIN || errno == EINTR) ? MBEDTLS_ERR_SSL_WANT_READ : MBEDTLS_ERR_NET_RECV_FAILED;
    if (n == 0) return MBEDTLS_ERR_NET_CONN_RESET;
    return (int)n;
}

static int nk_write_all(nk_conn* c, const char* data, size_t len) {
    size_t off = 0;
    while (off < len) {
        int n;
        if (c->tls) {
            n = mbedtls_ssl_write(c->ssl, (const unsigned char*)data + off, len - off);
            if (n == MBEDTLS_ERR_SSL_WANT_WRITE || n == MBEDTLS_ERR_SSL_WANT_READ) continue;
        } else {
            n = nk_bio_send(c, (const unsigned char*)data + off, len - off);
            if (n == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        }
        if (n <= 0) return NK_HTTP_ERR_IO;
        off += (size_t)n;
    }
    return 0;
}

/// Reads one chunk. Returns bytes read, 0 at end of stream, or a negative error.
static int nk_read(nk_conn* c, char* buf, size_t cap) {
    for (;;) {
        int n;
        if (c->tls) {
            n = mbedtls_ssl_read(c->ssl, (unsigned char*)buf, cap);
            if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
            if (n == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET) continue;
            if (n == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY || n == MBEDTLS_ERR_NET_CONN_RESET) return 0;
            if (n == MBEDTLS_ERR_SSL_TIMEOUT) return NK_HTTP_ERR_TIMEOUT;
        } else {
            n = nk_bio_recv(c, (unsigned char*)buf, cap);
            if (n == MBEDTLS_ERR_SSL_WANT_READ) continue;
            if (n == MBEDTLS_ERR_NET_CONN_RESET) return 0;
            if (n == MBEDTLS_ERR_SSL_TIMEOUT) return NK_HTTP_ERR_TIMEOUT;
        }
        if (n < 0) return (c->cancel && *c->cancel) ? NK_HTTP_ERR_CANCELLED : NK_HTTP_ERR_IO;
        return n;
    }
}

/// Decodes a chunked body in place. Returns the decoded length, or -1 if it is malformed.
static long nk_dechunk(char* body, size_t len) {
    size_t in = 0, out = 0;
    while (in < len) {
        char* end = NULL;
        unsigned long size = strtoul(body + in, &end, 16);
        if (end == body + in) return -1;
        char* nl = memchr(end, '\n', len - (size_t)(end - body));
        if (!nl) return -1;
        in = (size_t)(nl - body) + 1;
        if (size == 0) break;
        if (in + size > len) size = len - in;
        memmove(body + out, body + in, size);
        out += size; in += size;
        if (in < len && body[in] == '\r') in++;
        if (in < len && body[in] == '\n') in++;
    }
    body[out] = 0;
    return (long)out;
}

nk_http_result nk_http_get(const char* host, uint16_t port, const char* path, int tls,
                           const char* certPem, const char* keyPem,
                           const uint8_t* pinnedDer, size_t pinnedLen,
                           int timeoutMs, volatile int* cancel) {
    return nk_http_request("GET", host, port, path, tls, certPem, keyPem, pinnedDer, pinnedLen, NULL, 0, NULL, timeoutMs, cancel);
}

nk_http_result nk_http_request(const char* method, const char* host, uint16_t port, const char* path, int tls,
                               const char* certPem, const char* keyPem,
                               const uint8_t* pinnedDer, size_t pinnedLen,
                               const uint8_t* reqBody, size_t reqBodyLen, const char* contentType,
                               int timeoutMs, volatile int* cancel) {
    nk_http_result r = {0};
    long long deadline = nk_now_ms() + (timeoutMs > 0 ? timeoutMs : 10000);
    int fd = nk_connect(host, port, deadline, cancel);
    if (fd < 0) { r.error = fd; return r; }

    nk_conn c = { fd, tls, NULL, deadline, cancel };
    mbedtls_ssl_context ssl; mbedtls_ssl_config conf; mbedtls_x509_crt own; mbedtls_pk_context key;
    mbedtls_entropy_context ent; mbedtls_ctr_drbg_context drbg;
    char* buf = NULL; size_t used = 0, cap = 0;

    if (tls) {
        mbedtls_ssl_init(&ssl); mbedtls_ssl_config_init(&conf); mbedtls_x509_crt_init(&own); mbedtls_pk_init(&key);
        mbedtls_entropy_init(&ent); mbedtls_ctr_drbg_init(&drbg);
        int rc = mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &ent, (const unsigned char*)"nk-https", 8);
        if (rc == 0) rc = mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
        if (rc == 0) {
            // GameStream hosts use self-signed certificates: trust comes from pinning the paired certificate.
            mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_NONE);
            mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &drbg);
            // Sunshine speaks TLS 1.2 and 1.3; stay on 1.2 for the widest compatibility with older hosts.
            mbedtls_ssl_conf_max_tls_version(&conf, MBEDTLS_SSL_VERSION_TLS1_2);
        }
        if (rc == 0 && certPem && keyPem) {
            rc = mbedtls_x509_crt_parse(&own, (const unsigned char*)certPem, strlen(certPem) + 1);
            if (rc == 0) rc = mbedtls_pk_parse_key(&key, (const unsigned char*)keyPem, strlen(keyPem) + 1, NULL, 0, mbedtls_ctr_drbg_random, &drbg);
            if (rc == 0) rc = mbedtls_ssl_conf_own_cert(&conf, &own, &key);
        }
        if (rc == 0) rc = mbedtls_ssl_setup(&ssl, &conf);
        if (rc == 0) {
            mbedtls_ssl_set_bio(&ssl, &c, nk_bio_send, nk_bio_recv, NULL);
            c.ssl = &ssl;
            do { rc = mbedtls_ssl_handshake(&ssl); } while (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE);
        }
        if (rc != 0) {
            r.error = (cancel && *cancel) ? NK_HTTP_ERR_CANCELLED : NK_HTTP_ERR_TLS;
            r.tlsCode = rc;
            mbedtls_strerror(rc, r.tlsMessage, sizeof r.tlsMessage);
            goto done;
        }
        const mbedtls_x509_crt* peer = mbedtls_ssl_get_peer_cert(&ssl);
        if (peer) {
            r.peerCert = (uint8_t*)malloc(peer->raw.len);
            if (r.peerCert) { memcpy(r.peerCert, peer->raw.p, peer->raw.len); r.peerCertLen = peer->raw.len; }
        }
        if (pinnedDer && pinnedLen && (!peer || peer->raw.len != pinnedLen || memcmp(peer->raw.p, pinnedDer, pinnedLen) != 0)) {
            r.error = NK_HTTP_ERR_PINNED; goto done;
        }
    }

    {
        size_t reqCap = strlen(path) + strlen(host) + 320;
        char* req = (char*)malloc(reqCap);
        if (!req) { r.error = NK_HTTP_ERR_IO; goto done; }
        int bracket = strchr(host, ':') != NULL;
        int post = strcmp(method, "POST") == 0;
        char extra[160] = "";
        if (post) snprintf(extra, sizeof extra, "Content-Type: %s\r\nContent-Length: %zu\r\n", contentType ? contentType : "text/plain; charset=utf-8", reqBodyLen);
        snprintf(req, reqCap, "%s %s HTTP/1.1\r\nHost: %s%s%s:%u\r\nUser-Agent: Nokcandu\r\nAccept: */*\r\n%sConnection: close\r\n\r\n",
                 method, path, bracket ? "[" : "", host, bracket ? "]" : "", port, extra);
        int w = nk_write_all(&c, req, strlen(req));
        free(req);
        if (!w && post && reqBodyLen > 0) w = nk_write_all(&c, (const char*)reqBody, reqBodyLen);
        if (w) { r.error = (cancel && *cancel) ? NK_HTTP_ERR_CANCELLED : w; goto done; }
    }

    for (;;) {
        if (cap - used < 16385) {
            size_t ncap = cap ? cap * 2 : 32768;
            char* nb = (char*)realloc(buf, ncap);
            if (!nb) { r.error = NK_HTTP_ERR_IO; goto done; }
            buf = nb; cap = ncap;
        }
        int n = nk_read(&c, buf + used, cap - used - 1);
        if (n == 0) break;
        if (n < 0) {
            // A response that already arrived in full still counts.
            if (used > 0 && n != NK_HTTP_ERR_CANCELLED) break;
            r.error = n; goto done;
        }
        used += (size_t)n;
        buf[used] = 0;
        // Stop at Content-Length when the host keeps the connection open.
        char* hdrEnd = strstr(buf, "\r\n\r\n");
        if (hdrEnd) {
            char* cl = strcasestr(buf, "\r\ncontent-length:");
            if (cl && cl < hdrEnd) {
                size_t want = (size_t)strtoul(cl + 17, NULL, 10);
                if (used - (size_t)(hdrEnd + 4 - buf) >= want) break;
            }
        }
    }
    if (!buf) { r.error = NK_HTTP_ERR_IO; goto done; }
    buf[used] = 0;
    {
        char* hdrEnd = strstr(buf, "\r\n\r\n");
        if (!hdrEnd || strncmp(buf, "HTTP/", 5) != 0) { r.error = NK_HTTP_ERR_IO; goto done; }
        char* sp = strchr(buf, ' ');
        r.status = sp ? atoi(sp + 1) : 0;
        char* body = hdrEnd + 4;
        size_t blen = used - (size_t)(body - buf);
        char* te = strcasestr(buf, "\r\ntransfer-encoding:");
        int chunked = te && te < hdrEnd && strcasestr(te, "chunked") && strcasestr(te, "chunked") < hdrEnd;
        char* cl = strcasestr(buf, "\r\ncontent-length:");
        if (!chunked && cl && cl < hdrEnd) {
            size_t want = (size_t)strtoul(cl + 17, NULL, 10);
            if (want < blen) blen = want;
        }
        r.body = (char*)malloc(blen + 1);
        if (!r.body) { r.error = NK_HTTP_ERR_IO; goto done; }
        memcpy(r.body, body, blen); r.body[blen] = 0;
        if (chunked) { long d = nk_dechunk(r.body, blen); blen = d < 0 ? blen : (size_t)d; }
        r.bodyLen = blen;
    }

done:
    free(buf);
    if (tls) {
        if (c.ssl) mbedtls_ssl_close_notify(&ssl);
        mbedtls_ssl_free(&ssl); mbedtls_ssl_config_free(&conf); mbedtls_x509_crt_free(&own); mbedtls_pk_free(&key);
        mbedtls_ctr_drbg_free(&drbg); mbedtls_entropy_free(&ent);
    }
    close(fd);
    return r;
}

void nk_http_free(nk_http_result* r) {
    free(r->body); free(r->peerCert);
    r->body = NULL; r->peerCert = NULL;
}
