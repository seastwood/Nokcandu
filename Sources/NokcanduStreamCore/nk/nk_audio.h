// SPDX-License-Identifier: GPL-3.0-only
#ifndef NK_AUDIO_H
#define NK_AUDIO_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct nk_opus_decoder nk_opus_decoder;
/// A multistream Opus decoder for the host's layout (stereo, 5.1 or 7.1).
nk_opus_decoder* nk_opus_create(int sampleRate, int channels, int streams, int coupledStreams, const unsigned char* mapping);
/// Decodes one packet into interleaved float samples; returns samples per channel, or a negative error.
/// A NULL packet conceals a lost one.
int nk_opus_decode(nk_opus_decoder* d, const unsigned char* data, int len, float* out, int maxSamplesPerChannel);
void nk_opus_destroy(nk_opus_decoder* d);
#ifdef __cplusplus
}
#endif
#endif
