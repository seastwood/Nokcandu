// SPDX-License-Identifier: GPL-3.0-only
#define MBEDTLS_ALLOW_PRIVATE_ACCESS 1   /* the certificate's signature field */
#include "nk_net.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <mbedtls/aes.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>
#include <mbedtls/md.h>
#include <mbedtls/pk.h>
#include <mbedtls/rsa.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/x509_csr.h>

static int nk_drbg(mbedtls_entropy_context* e, mbedtls_ctr_drbg_context* d) {
    mbedtls_entropy_init(e);
    mbedtls_ctr_drbg_init(d);
    static const char pers[] = "nokcandu-streams";
    return mbedtls_ctr_drbg_seed(d, mbedtls_entropy_func, e, (const unsigned char*)pers, sizeof pers - 1);
}

int nk_random(uint8_t* out, size_t len) {
    mbedtls_entropy_context e; mbedtls_ctr_drbg_context d;
    int rc = nk_drbg(&e, &d);
    if (rc == 0) rc = mbedtls_ctr_drbg_random(&d, out, len);
    mbedtls_ctr_drbg_free(&d); mbedtls_entropy_free(&e);
    return rc;
}

int nk_generate_identity(char* certPem, size_t certCap, char* keyPem, size_t keyCap) {
    mbedtls_entropy_context e; mbedtls_ctr_drbg_context d;
    mbedtls_pk_context key; mbedtls_x509write_cert crt;
    mbedtls_pk_init(&key); mbedtls_x509write_crt_init(&crt);
    int rc = nk_drbg(&e, &d);
    if (rc == 0) rc = mbedtls_pk_setup(&key, mbedtls_pk_info_from_type(MBEDTLS_PK_RSA));
    if (rc == 0) rc = mbedtls_rsa_gen_key(mbedtls_pk_rsa(key), mbedtls_ctr_drbg_random, &d, 2048, 65537);
    if (rc == 0) {
        mbedtls_x509write_crt_set_version(&crt, MBEDTLS_X509_CRT_VERSION_3);
        mbedtls_x509write_crt_set_md_alg(&crt, MBEDTLS_MD_SHA256);
        mbedtls_x509write_crt_set_subject_key(&crt, &key);
        mbedtls_x509write_crt_set_issuer_key(&crt, &key);
        rc = mbedtls_x509write_crt_set_subject_name(&crt, "CN=NVIDIA GameStream Client");
    }
    if (rc == 0) rc = mbedtls_x509write_crt_set_issuer_name(&crt, "CN=NVIDIA GameStream Client");
    if (rc == 0) {
        unsigned char serial[8];
        mbedtls_ctr_drbg_random(&d, serial, sizeof serial);
        serial[0] &= 0x7f; serial[0] |= 0x01;
        rc = mbedtls_x509write_crt_set_serial_raw(&crt, serial, sizeof serial);
    }
    if (rc == 0) {
        char from[16], to[16];
        time_t now = time(NULL); struct tm t; gmtime_r(&now, &t);
        strftime(from, sizeof from, "%Y%m%d%H%M%S", &t);
        t.tm_year += 20;
        strftime(to, sizeof to, "%Y%m%d%H%M%S", &t);
        rc = mbedtls_x509write_crt_set_validity(&crt, from, to);
    }
    if (rc == 0) rc = mbedtls_x509write_crt_pem(&crt, (unsigned char*)certPem, certCap, mbedtls_ctr_drbg_random, &d);
    if (rc == 0) rc = mbedtls_pk_write_key_pem(&key, (unsigned char*)keyPem, keyCap);
    mbedtls_x509write_crt_free(&crt); mbedtls_pk_free(&key);
    mbedtls_ctr_drbg_free(&d); mbedtls_entropy_free(&e);
    return rc;
}

/// Mbed TLS wants PEM text including its NUL; DER as is.
static int nk_parse_crt(mbedtls_x509_crt* crt, const uint8_t* cert, size_t len) {
    mbedtls_x509_crt_init(crt);
    if (len > 0 && cert[0] == '-') {
        // Copy so the PEM is NUL-terminated whatever the caller passed.
        unsigned char* buf = (unsigned char*)malloc(len + 1);
        if (!buf) return -1;
        memcpy(buf, cert, len); buf[len] = 0;
        int rc = mbedtls_x509_crt_parse(crt, buf, len + 1);
        free(buf);
        return rc;
    }
    return mbedtls_x509_crt_parse_der(crt, cert, len);
}

int nk_sign_sha256(const char* keyPem, const uint8_t* data, size_t len, uint8_t* sig, size_t* sigLen) {
    mbedtls_entropy_context e; mbedtls_ctr_drbg_context d; mbedtls_pk_context key;
    mbedtls_pk_init(&key);
    unsigned char hash[32];
    int rc = nk_drbg(&e, &d);
    if (rc == 0) rc = mbedtls_pk_parse_key(&key, (const unsigned char*)keyPem, strlen(keyPem) + 1, NULL, 0, mbedtls_ctr_drbg_random, &d);
    if (rc == 0) rc = mbedtls_md(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), data, len, hash);
    if (rc == 0) rc = mbedtls_pk_sign(&key, MBEDTLS_MD_SHA256, hash, sizeof hash, sig, *sigLen, sigLen, mbedtls_ctr_drbg_random, &d);
    mbedtls_pk_free(&key); mbedtls_ctr_drbg_free(&d); mbedtls_entropy_free(&e);
    return rc;
}

int nk_verify_sha256(const uint8_t* cert, size_t certLen, const uint8_t* data, size_t len, const uint8_t* sig, size_t sigLen) {
    mbedtls_x509_crt crt; unsigned char hash[32];
    int rc = nk_parse_crt(&crt, cert, certLen);
    if (rc == 0) rc = mbedtls_md(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), data, len, hash);
    if (rc == 0) rc = mbedtls_pk_verify(&crt.pk, MBEDTLS_MD_SHA256, hash, sizeof hash, sig, sigLen);
    mbedtls_x509_crt_free(&crt);
    return rc;
}

int nk_cert_signature(const uint8_t* cert, size_t certLen, uint8_t* out, size_t* outLen) {
    mbedtls_x509_crt crt;
    int rc = nk_parse_crt(&crt, cert, certLen);
    if (rc == 0) {
        if (crt.sig.len > *outLen) rc = -1;
        else { memcpy(out, crt.sig.p, crt.sig.len); *outLen = crt.sig.len; }
    }
    mbedtls_x509_crt_free(&crt);
    return rc;
}

int nk_cert_der(const uint8_t* cert, size_t certLen, uint8_t* out, size_t* outLen) {
    mbedtls_x509_crt crt;
    int rc = nk_parse_crt(&crt, cert, certLen);
    if (rc == 0) {
        if (crt.raw.len > *outLen) rc = -1;
        else { memcpy(out, crt.raw.p, crt.raw.len); *outLen = crt.raw.len; }
    }
    mbedtls_x509_crt_free(&crt);
    return rc;
}

int nk_aes128_ecb(const uint8_t key[16], const uint8_t* in, size_t len, uint8_t* out, int encrypt) {
    if (len % 16) return -1;
    mbedtls_aes_context aes; mbedtls_aes_init(&aes);
    int rc = encrypt ? mbedtls_aes_setkey_enc(&aes, key, 128) : mbedtls_aes_setkey_dec(&aes, key, 128);
    for (size_t i = 0; rc == 0 && i < len; i += 16)
        rc = mbedtls_aes_crypt_ecb(&aes, encrypt ? MBEDTLS_AES_ENCRYPT : MBEDTLS_AES_DECRYPT, in + i, out + i);
    mbedtls_aes_free(&aes);
    return rc;
}
