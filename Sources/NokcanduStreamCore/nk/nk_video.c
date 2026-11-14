// SPDX-License-Identifier: GPL-3.0-only
// A minimal AV1 sequence header reader (AV1 spec 5.5) for VideoToolbox's format description, in place of
// FFmpeg's bitstream parser that VoidLink uses on iOS.
#include "nk_video.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

typedef struct { const uint8_t* p; size_t len; size_t bit; int overrun; } nk_bits;

static uint32_t nk_f(nk_bits* b, int n) {
    uint32_t v = 0;
    for (int i = 0; i < n; i++) {
        size_t byte = b->bit >> 3;
        if (byte >= b->len) { b->overrun = 1; return 0; }
        v = (v << 1) | ((b->p[byte] >> (7 - (b->bit & 7))) & 1);
        b->bit++;
    }
    return v;
}

static uint32_t nk_uvlc(nk_bits* b) {
    int zeros = 0;
    while (!b->overrun && !nk_f(b, 1)) { if (++zeros >= 32) return UINT32_MAX; }
    if (zeros >= 32) return UINT32_MAX;
    return nk_f(b, zeros) + ((1u << zeros) - 1);
}

static int nk_leb128(const uint8_t* p, size_t len, size_t* consumed, uint64_t* value) {
    uint64_t v = 0;
    for (size_t i = 0; i < 8 && i < len; i++) {
        v |= (uint64_t)(p[i] & 0x7f) << (i * 7);
        if (!(p[i] & 0x80)) { *consumed = i + 1; *value = v; return 0; }
    }
    return -1;
}

static int nk_parse_sequence_header(const uint8_t* p, size_t len, nk_av1_sequence* s) {
    nk_bits b = { p, len, 0, 0 };
    s->profile = (int)nk_f(&b, 3);
    nk_f(&b, 1);                                    // still_picture
    int reduced = (int)nk_f(&b, 1);
    int decoderModelInfo = 0, bufferDelayLength = 0;
    if (reduced) {
        s->level = (int)nk_f(&b, 5);
        s->tier = 0;
    } else {
        int timingInfo = (int)nk_f(&b, 1);
        if (timingInfo) {
            nk_f(&b, 32); nk_f(&b, 32);                 // num_units_in_display_tick, time_scale
            if (nk_f(&b, 1)) nk_uvlc(&b);               // equal_picture_interval → num_ticks_per_picture_minus_1
            decoderModelInfo = (int)nk_f(&b, 1);
            if (decoderModelInfo) {
                bufferDelayLength = (int)nk_f(&b, 5) + 1;
                nk_f(&b, 32);                           // num_units_in_decoding_tick
                nk_f(&b, 5); nk_f(&b, 5);               // buffer_removal_time_length, frame_presentation_time_length
            }
        }
        int initialDisplayDelay = (int)nk_f(&b, 1);
        int opCount = (int)nk_f(&b, 5) + 1;
        for (int i = 0; i < opCount; i++) {
            nk_f(&b, 12);                               // operating_point_idc
            int level = (int)nk_f(&b, 5);
            int tier = level > 7 ? (int)nk_f(&b, 1) : 0;
            if (i == 0) { s->level = level; s->tier = tier; }
            if (decoderModelInfo && nk_f(&b, 1)) {
                nk_f(&b, bufferDelayLength); nk_f(&b, bufferDelayLength); nk_f(&b, 1);
            }
            if (initialDisplayDelay && nk_f(&b, 1)) nk_f(&b, 4);
        }
    }
    int wBits = (int)nk_f(&b, 4) + 1, hBits = (int)nk_f(&b, 4) + 1;
    s->width = (int)nk_f(&b, wBits) + 1;
    s->height = (int)nk_f(&b, hBits) + 1;
    int frameIDs = reduced ? 0 : (int)nk_f(&b, 1);
    if (frameIDs) { nk_f(&b, 4); nk_f(&b, 3); }
    nk_f(&b, 1); nk_f(&b, 1); nk_f(&b, 1);             // 128x128 superblock, filter intra, intra edge filter
    if (!reduced) {
        nk_f(&b, 1); nk_f(&b, 1); nk_f(&b, 1); nk_f(&b, 1);  // interintra, masked compound, warped motion, dual filter
        int orderHint = (int)nk_f(&b, 1);
        if (orderHint) { nk_f(&b, 1); nk_f(&b, 1); }   // jnt_comp, ref_frame_mvs
        int forceScreenContent = nk_f(&b, 1) ? 2 : (int)nk_f(&b, 1);
        if (forceScreenContent > 0) { if (!nk_f(&b, 1)) nk_f(&b, 1); }
        if (orderHint) nk_f(&b, 3);
    }
    nk_f(&b, 1); nk_f(&b, 1); nk_f(&b, 1);             // superres, cdef, restoration

    // color_config()
    int highBitDepth = (int)nk_f(&b, 1);
    int twelve = 0;
    if (s->profile == 2 && highBitDepth) twelve = (int)nk_f(&b, 1);
    s->bitDepth = twelve ? 12 : highBitDepth ? 10 : 8;
    s->monochrome = s->profile == 1 ? 0 : (int)nk_f(&b, 1);
    if (nk_f(&b, 1)) {
        s->colorPrimaries = (int)nk_f(&b, 8);
        s->transferCharacteristics = (int)nk_f(&b, 8);
        s->matrixCoefficients = (int)nk_f(&b, 8);
    } else {
        s->colorPrimaries = s->transferCharacteristics = s->matrixCoefficients = 2;
    }
    if (s->monochrome) {
        s->fullRange = (int)nk_f(&b, 1);
        s->subsamplingX = s->subsamplingY = 1;
        s->chromaSamplePosition = 0;
    } else if (s->colorPrimaries == 1 && s->transferCharacteristics == 13 && s->matrixCoefficients == 0) {
        s->fullRange = 1; s->subsamplingX = s->subsamplingY = 0;
    } else {
        s->fullRange = (int)nk_f(&b, 1);
        if (s->profile == 0) { s->subsamplingX = s->subsamplingY = 1; }
        else if (s->profile == 1) { s->subsamplingX = s->subsamplingY = 0; }
        else if (s->bitDepth == 12) {
            s->subsamplingX = (int)nk_f(&b, 1);
            s->subsamplingY = s->subsamplingX ? (int)nk_f(&b, 1) : 0;
        } else { s->subsamplingX = 1; s->subsamplingY = 0; }
        if (s->subsamplingX && s->subsamplingY) s->chromaSamplePosition = (int)nk_f(&b, 2);
    }
    return b.overrun ? -1 : 0;
}

int nk_av1_parse(const uint8_t* data, size_t len, nk_av1_sequence* out) {
    memset(out, 0, sizeof *out);
    size_t off = 0;
    while (off < len) {
        uint8_t header = data[off];
        int type = (header >> 3) & 0xf;
        int ext = (header >> 2) & 1, hasSize = (header >> 1) & 1;
        size_t hdrLen = 1 + (size_t)ext;
        if (off + hdrLen > len) return -1;
        uint64_t payload = len - off - hdrLen;
        size_t sizeLen = 0;
        if (hasSize) {
            if (nk_leb128(data + off + hdrLen, len - off - hdrLen, &sizeLen, &payload) != 0) return -1;
        }
        size_t start = off + hdrLen + sizeLen;
        if (start + payload > len) return -1;
        if (type == 1) {      // OBU_SEQUENCE_HEADER
            if (nk_parse_sequence_header(data + start, (size_t)payload, out) != 0) return -1;
            out->found = 1;
            // AV1CodecConfigurationRecord: marker+version, profile/level, tier/depth/chroma, no presentation delay,
            // then the sequence header OBU itself (written with its size field).
            uint8_t* c = out->av1c;
            c[0] = 0x81;
            c[1] = (uint8_t)((out->profile << 5) | (out->level & 0x1f));
            c[2] = (uint8_t)((out->tier << 7) | ((out->bitDepth > 8) << 6) | ((out->bitDepth == 12) << 5) | (out->monochrome << 4)
                             | (out->subsamplingX << 3) | (out->subsamplingY << 2) | (out->chromaSamplePosition & 3));
            c[3] = 0;
            size_t n = 4;
            // OBU header with has_size_field set and no extension, then the leb128 size and the payload.
            if (n + 1 + 8 + payload > sizeof out->av1c) return -1;
            c[n++] = (uint8_t)((1 << 3) | (1 << 1));
            uint64_t v = payload;
            do { uint8_t byte = v & 0x7f; v >>= 7; if (v) byte |= 0x80; c[n++] = byte; } while (v);
            memcpy(c + n, data + start, (size_t)payload); n += (size_t)payload;
            out->av1cLength = n;
            return 0;
        }
        if (!hasSize) break;
        off = start + (size_t)payload;
    }
    return -1;
}

static void (*nk_log_handler)(const char*) = NULL;

void nk_set_log_handler(void (*handler)(const char* line)) { nk_log_handler = handler; }

void nk_log_message(const char* format, ...) {
    if (!nk_log_handler) return;
    char line[1024];
    va_list ap; va_start(ap, format);
    vsnprintf(line, sizeof line, format, ap);
    va_end(ap);
    nk_log_handler(line);
}

#include "../moonlight/src/Limelight.h"
void nk_install_log(void* callbacks) { ((PCONNECTION_LISTENER_CALLBACKS)callbacks)->logMessage = nk_log_message; }

#include "../moonlight/src/PlatformCrypto.h"
/// Self-test for the core's AES-CBC path (audio): decrypts NIST SP 800-38A F.2.1's first block plus PKCS7 padding.
int nk_selftest_cbc(unsigned char* out, int* outLen, const unsigned char* key, const unsigned char* iv, const unsigned char* in, int inLen) {
    PPLT_CRYPTO_CONTEXT ctx = PltCreateCryptoContext();
    unsigned char ivCopy[16]; memcpy(ivCopy, iv, 16);
    bool ok = PltDecryptMessage(ctx, ALGORITHM_AES_CBC, CIPHER_FLAG_RESET_IV | CIPHER_FLAG_FINISH, (unsigned char*)key, 16, ivCopy, 16, NULL, 0,
                                (unsigned char*)in, inLen, out, outLen);
    PltDestroyCryptoContext(ctx);
    return ok ? 0 : -1;
}
int nk_selftest_cbc_encrypt(unsigned char* out, int* outLen, const unsigned char* key, const unsigned char* iv, const unsigned char* in, int inLen) {
    PPLT_CRYPTO_CONTEXT ctx = PltCreateCryptoContext();
    unsigned char ivCopy[16]; memcpy(ivCopy, iv, 16);
    bool ok = PltEncryptMessage(ctx, ALGORITHM_AES_CBC, CIPHER_FLAG_RESET_IV | CIPHER_FLAG_FINISH | CIPHER_FLAG_PAD_TO_BLOCK_SIZE, (unsigned char*)key, 16, ivCopy, 16, NULL, 0,
                                (unsigned char*)in, inLen, out, outLen);
    PltDestroyCryptoContext(ctx);
    return ok ? 0 : -1;
}
