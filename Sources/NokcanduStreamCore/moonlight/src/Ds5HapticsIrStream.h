#pragma once

#include "Limelight.h"

#define DS5_HAPTICS_IR_STREAM_PROTOCOL_VERSION 2
#define DS5_HAPTICS_IR_STREAM_WIRE_SIZE 72

typedef void(*Ds5HapticsIrStreamCallback)(const LI_DS5_HAPTICS_IR_FRAME_V2* frame,
                                          void* context);

bool processDs5HapticsIrStreamPacket(const uint8_t* payload,
                                     int payloadLength,
                                     Ds5HapticsIrStreamCallback callback,
                                     void* context);
