#pragma once

// Dynamic HDR negotiation wire constants (Sunshine protocol extension).
// Keep these out of Limelight.h: object-like macros with these names can
// collide with host-side C++ enum members when both headers are included.
#define DYNAMIC_HDR_CAPS_HDR10_PLUS (1 << 0)
#define DYNAMIC_HDR_CAPS_VIVID_PQ (1 << 1)
#define DYNAMIC_HDR_CAPS_VIVID_HLG (1 << 2)
#define DYNAMIC_HDR_CAPS_DOLBY_VISION_81 (1 << 3)
#define DYNAMIC_HDR_CAPS_DOLBY_VISION_84 (1 << 4)

#define DYNAMIC_HDR_FORMAT_NONE 0
#define DYNAMIC_HDR_FORMAT_HDR10_PLUS 1
#define DYNAMIC_HDR_FORMAT_VIVID_PQ 2
#define DYNAMIC_HDR_FORMAT_VIVID_HLG 3
#define DYNAMIC_HDR_FORMAT_DOLBY_VISION_PROFILE_81 4
#define DYNAMIC_HDR_FORMAT_DOLBY_VISION_PROFILE_84 5

#define DYNAMIC_HDR_PREFERENCE_AUTO 0
#define DYNAMIC_HDR_PREFERENCE_DOLBY_VISION 1
#define DYNAMIC_HDR_PREFERENCE_HDR10_PLUS 2
#define DYNAMIC_HDR_PREFERENCE_HDR10 3

// Fallback 1 was retired by the host protocol; keep the numeric gap stable.
#define DYNAMIC_HDR_FALLBACK_NONE 0
#define DYNAMIC_HDR_FALLBACK_CODEC_UNSUPPORTED 2
#define DYNAMIC_HDR_FALLBACK_COLORSPACE_UNSUPPORTED 3
#define DYNAMIC_HDR_FALLBACK_CLIENT_CAPS_MISSING 4
#define DYNAMIC_HDR_FALLBACK_DIRECT_SURFACE_MISSING 5
#define DYNAMIC_HDR_FALLBACK_PREFERENCE 6

// Parse the numeric value carried by X-SS-Dynamic-HDR. Invalid, missing, or
// unknown values are treated as DYNAMIC_HDR_FORMAT_NONE. The parser accepts
// the enum names as a compatibility aid for hosts that expose textual values.
int parseDynamicHdrFormatValue(const char* value);

// Parse X-SS-Dynamic-HDR-Fallback. Sunshine normally sends enum names, but
// accepting the stable numeric identities keeps the client interoperable with
// hosts that serialize enums as integers. Unknown values map to NONE.
int parseDynamicHdrFallbackValue(const char* value);
