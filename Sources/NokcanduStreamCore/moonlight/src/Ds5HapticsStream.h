#pragma once

#include "Limelight.h"

#define DS5_HAPTICS_STREAM_PROTOCOL_VERSION 1
#define DS5_HAPTICS_STREAM_WIRE_HEADER_SIZE 28
#define DS5_HAPTICS_STREAM_MAX_FRAMES 480

typedef void(*Ds5HapticsStreamCallback)(const LI_DS5_HAPTICS_PCM_FRAME* frame,
                                        void* context);

bool processDs5HapticsStreamPacket(const uint8_t* payload,
                                   int payloadLength,
                                   Ds5HapticsStreamCallback callback,
                                   void* context);
