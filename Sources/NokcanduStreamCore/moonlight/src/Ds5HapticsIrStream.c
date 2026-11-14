#include "Ds5HapticsIrStream.h"

#include <math.h>
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

static float readLeFloat(const uint8_t* data) {
    uint32_t bits = readLe32(data);
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static bool isNormalized(float value) {
    return isfinite(value) && value >= 0.0f && value <= 1.0f;
}

bool processDs5HapticsIrStreamPacket(const uint8_t* payload,
                                     int payloadLength,
                                     Ds5HapticsIrStreamCallback callback,
                                     void* context) {
    LI_DS5_HAPTICS_IR_FRAME_V2 frame;
    const uint8_t knownFlags = LI_DS5_HAPTICS_IR_FLAG_DISCONTINUITY |
                               LI_DS5_HAPTICS_IR_FLAG_PARTIAL |
                               LI_DS5_HAPTICS_IR_FLAG_STREAM_END |
                               LI_DS5_HAPTICS_IR_FLAG_SILENT;
    int lane;

    if (payload == NULL || callback == NULL ||
            payloadLength != DS5_HAPTICS_IR_STREAM_WIRE_SIZE ||
            payload[0] != DS5_HAPTICS_IR_STREAM_PROTOCOL_VERSION ||
            (payload[1] & ~knownFlags) != 0 ||
            readLe16(payload + 2) != DS5_HAPTICS_IR_STREAM_WIRE_SIZE ||
            readLe16(payload + 6) != 0 || readLe32(payload + 68) != 0) {
        return false;
    }

    memset(&frame, 0, sizeof(frame));
    frame.flags = payload[1];
    frame.controllerNumber = readLe16(payload + 4);
    frame.sourceSequenceNumber = readLe32(payload + 8);
    frame.timestampUs = readLe64(payload + 12);
    frame.sourceFrameCount = readLe32(payload + 20);

    for (lane = 0; lane < 2; lane++) {
        const uint8_t* wireLane = payload + 24 + lane * 20;
        LI_DS5_HAPTICS_IR_LANE_V2* outLane = &frame.lanes[lane];
        outLane->rmsAmplitude = readLeFloat(wireLane);
        outLane->peakAmplitude = readLeFloat(wireLane + 4);
        outLane->transientStrength = readLeFloat(wireLane + 8);
        outLane->lowBandRatio = readLeFloat(wireLane + 12);
        outLane->zeroCrossingRateHz = readLeFloat(wireLane + 16);
        if (!isNormalized(outLane->rmsAmplitude) ||
                !isNormalized(outLane->peakAmplitude) ||
                outLane->rmsAmplitude > outLane->peakAmplitude ||
                !isNormalized(outLane->transientStrength) ||
                !isNormalized(outLane->lowBandRatio) ||
                !isfinite(outLane->zeroCrossingRateHz) ||
                outLane->zeroCrossingRateHz < 0.0f ||
                outLane->zeroCrossingRateHz > 48000.0f) {
            return false;
        }
    }

    frame.laneCorrelation = readLeFloat(payload + 64);
    if (!isfinite(frame.laneCorrelation) ||
            frame.laneCorrelation < -1.0f || frame.laneCorrelation > 1.0f) {
        return false;
    }

    callback(&frame, context);
    return true;
}
