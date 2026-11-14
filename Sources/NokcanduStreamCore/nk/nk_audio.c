// SPDX-License-Identifier: GPL-3.0-only
#include "nk_audio.h"
#include <opus_multistream.h>
#include <stdlib.h>

struct nk_opus_decoder { OpusMSDecoder* ms; int channels; };

nk_opus_decoder* nk_opus_create(int sampleRate, int channels, int streams, int coupledStreams, const unsigned char* mapping) {
    int err = 0;
    OpusMSDecoder* ms = opus_multistream_decoder_create(sampleRate, channels, streams, coupledStreams, mapping, &err);
    if (!ms || err != OPUS_OK) return NULL;
    nk_opus_decoder* d = (nk_opus_decoder*)malloc(sizeof *d);
    if (!d) { opus_multistream_decoder_destroy(ms); return NULL; }
    d->ms = ms; d->channels = channels;
    return d;
}

int nk_opus_decode(nk_opus_decoder* d, const unsigned char* data, int len, float* out, int maxSamplesPerChannel) {
    return opus_multistream_decode_float(d->ms, data, data ? len : 0, out, maxSamplesPerChannel, 0);
}

void nk_opus_destroy(nk_opus_decoder* d) {
    if (!d) return;
    opus_multistream_decoder_destroy(d->ms);
    free(d);
}
