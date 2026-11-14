// Nokcandu Streams: pairing crypto and the host's HTTP(S) requests, done with Mbed TLS so the client
// certificate never has to go into the keychain.
// SPDX-License-Identifier: GPL-3.0-only
#ifndef NK_NET_H
#define NK_NET_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Makes a new RSA-2048 key and a self-signed certificate for this Mac, both as PEM text (NUL-terminated).
/// Returns 0 on success.
int nk_generate_identity(char* certPem, size_t certCap, char* keyPem, size_t keyCap);

/// SHA-256 RSA signature of `data` with the PEM key. `*sigLen` is the capacity in and the length out.
int nk_sign_sha256(const char* keyPem, const uint8_t* data, size_t len, uint8_t* sig, size_t* sigLen);

/// Checks a SHA-256 RSA signature against the certificate (PEM or DER). Returns 0 when it matches.
int nk_verify_sha256(const uint8_t* cert, size_t certLen, const uint8_t* data, size_t len, const uint8_t* sig, size_t sigLen);

/// The certificate's own signature bytes (what GameStream pairing hashes). `*outLen` is capacity in, length out.
int nk_cert_signature(const uint8_t* cert, size_t certLen, uint8_t* out, size_t* outLen);

/// The certificate in DER form. `*outLen` is capacity in, length out.
int nk_cert_der(const uint8_t* cert, size_t certLen, uint8_t* out, size_t* outLen);

/// AES-128-ECB over whole 16-byte blocks (`len` must be a multiple of 16).
int nk_aes128_ecb(const uint8_t key[16], const uint8_t* in, size_t len, uint8_t* out, int encrypt);

/// Fills `out` with cryptographically random bytes.
int nk_random(uint8_t* out, size_t len);

typedef struct {
    int status;             // HTTP status, or 0 when the request never got an answer
    int error;              // 0, or a negative NK_HTTP_ERR_* value
    char* body;             // malloc'd, NUL-terminated; free with nk_http_free
    size_t bodyLen;
    uint8_t* peerCert;      // DER of the server's certificate on HTTPS (malloc'd), else NULL
    size_t peerCertLen;
    int tlsCode;            // Mbed TLS's error code when the handshake failed
    char tlsMessage[160];   // and its text
} nk_http_result;

enum {
    NK_HTTP_ERR_RESOLVE = -1,
    NK_HTTP_ERR_CONNECT = -2,
    NK_HTTP_ERR_TLS = -3,
    NK_HTTP_ERR_PINNED = -4,   // the server's certificate isn't the one it paired with
    NK_HTTP_ERR_IO = -5,
    NK_HTTP_ERR_TIMEOUT = -6,
    NK_HTTP_ERR_CANCELLED = -7,
};

/// GET `path` (with its query) from host:port. With `tls`, connects over TLS presenting the client
/// certificate and key; when `pinnedDer` is set the server must present exactly that certificate.
/// `cancel`, when set, is polled and aborts the request once it becomes non-zero.
nk_http_result nk_http_get(const char* host, uint16_t port, const char* path, int tls,
                           const char* certPem, const char* keyPem,
                           const uint8_t* pinnedDer, size_t pinnedLen,
                           int timeoutMs, volatile int* cancel);
/// Like nk_http_get with a method ("GET" or "POST") and, for POST, a body sent with Content-Length.
nk_http_result nk_http_request(const char* method, const char* host, uint16_t port, const char* path, int tls,
                               const char* certPem, const char* keyPem,
                               const uint8_t* pinnedDer, size_t pinnedLen,
                               const uint8_t* body, size_t bodyLen, const char* contentType,
                               int timeoutMs, volatile int* cancel);
void nk_http_free(nk_http_result* r);

#ifdef __cplusplus
}
#endif
#endif
