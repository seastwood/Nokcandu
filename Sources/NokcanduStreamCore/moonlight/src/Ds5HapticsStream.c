#include "Ds5HapticsStream.h"

#include <string.h>

static uint16_t readLe16(const uint8_t* data) {
    return (uint16_t)data[0] | ((uint16_t)data[1] << 8);
}

static uint32_t readLe32(const uint8_t* data) {
    return (uint32_t)data[0] |
           ((uint32_t)data[1] << 8) |
           ((uint32_t)data[2] << 16) |
           ((uint32_t)data[3] << 24);
}

static uint64_t readLe64(const uint8_t* data) {
    return (uint64_t)readLe32(data) | ((uint64_t)readLe32(data + 4) << 32);
}

bool processDs5HapticsStreamPacket(const uint8_t* payload,
                                   int payloadLength,
                                   Ds5HapticsStreamCallback callback,
                                   void* context) {
    LI_DS5_HAPTICS_PCM_FRAME frame;
    uint16_t headerSize;
    uint16_t reserved;
    uint32_t expectedPcmBytes;
    const uint8_t knownFlags = LI_DS5_HAPTICS_PCM_FLAG_STREAM_START |
                               LI_DS5_HAPTICS_PCM_FLAG_STREAM_END |
                               LI_DS5_HAPTICS_PCM_FLAG_DISCONTINUITY;

    if (payload == NULL || callback == NULL ||
            payloadLength < DS5_HAPTICS_STREAM_WIRE_HEADER_SIZE) {
        return false;
    }

    memset(&frame, 0, sizeof(frame));
    frame.flags = payload[1];
    headerSize = readLe16(payload + 2);
    frame.controllerNumber = readLe16(payload + 4);
    frame.frameCount = readLe16(payload + 6);
    frame.sequenceNumber = readLe32(payload + 8);
    frame.presentationTimeUs = readLe64(payload + 12);
    frame.sampleRate = readLe32(payload + 20);
    frame.channelCount = payload[24];
    frame.bitsPerSample = payload[25];
    reserved = readLe16(payload + 26);

    if (payload[0] != DS5_HAPTICS_STREAM_PROTOCOL_VERSION ||
            (frame.flags & ~knownFlags) != 0 || reserved != 0 ||
            headerSize < DS5_HAPTICS_STREAM_WIRE_HEADER_SIZE ||
            headerSize > (uint16_t)payloadLength ||
            frame.sampleRate != 48000 || frame.channelCount != 2 ||
            frame.bitsPerSample != 16 ||
            frame.frameCount > DS5_HAPTICS_STREAM_MAX_FRAMES) {
        return false;
    }

    expectedPcmBytes = (uint32_t)frame.frameCount * frame.channelCount *
                       (frame.bitsPerSample / 8);
    if ((uint32_t)payloadLength != (uint32_t)headerSize + expectedPcmBytes) {
        return false;
    }

    frame.pcmData = payload + headerSize;
    frame.pcmDataLength = expectedPcmBytes;
    callback(&frame, context);
    return true;
}
