// SPDX-License-Identifier: GPL-3.0-only
#ifndef NK_VIDEO_H
#define NK_VIDEO_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/// What VideoToolbox needs from an AV1 sequence header OBU.
typedef struct {
    int found;
    int width, height;
    int profile, level, tier;
    int bitDepth;
    int monochrome, subsamplingX, subsamplingY, chromaSamplePosition;
    int colorPrimaries, transferCharacteristics, matrixCoefficients, fullRange;
    /// The av1C box contents (AV1CodecConfigurationRecord with the sequence header OBU).
    uint8_t av1c[512];
    size_t av1cLength;
} nk_av1_sequence;

/// Finds and parses the sequence header in an AV1 temporal unit (a stream of OBUs). Returns 0 when found.
int nk_av1_parse(const uint8_t* data, size_t len, nk_av1_sequence* out);

/// Moonlight's core logs through a printf-style callback; Swift can't make a C variadic function, so this
/// one formats and passes the line on.
void nk_set_log_handler(void (*handler)(const char* line));
void nk_log_message(const char* format, ...);
/// Points a CONNECTION_LISTENER_CALLBACKS' logMessage at nk_log_message.
void nk_install_log(void* callbacks);
int nk_selftest_cbc(unsigned char* out, int* outLen, const unsigned char* key, const unsigned char* iv, const unsigned char* in, int inLen);
int nk_selftest_cbc_encrypt(unsigned char* out, int* outLen, const unsigned char* key, const unsigned char* iv, const unsigned char* in, int inLen);

#ifdef __cplusplus
}
#endif
#endif
