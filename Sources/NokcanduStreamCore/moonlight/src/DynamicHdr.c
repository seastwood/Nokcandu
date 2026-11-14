#include "DynamicHdr.h"

#include <limits.h>
#include <stdbool.h>
#include <string.h>

static const char* skipAsciiSpace(const char* value) {
    while (*value == ' ' || *value == '\t') {
        value++;
    }
    return value;
}

// Parse a decimal enum without accepting prefixes (atoi("1junk") == 1) or
// overflow. RTSP option parsing normally removes surrounding whitespace, but
// accepting horizontal whitespace here makes this helper safe for direct use.
static bool parseUnsignedEnum(const char* value, int minValue, int maxValue, int* result) {
    unsigned long parsed;
    unsigned int digit;

    if (value == NULL) {
        return false;
    }

    value = skipAsciiSpace(value);
    if (*value < '0' || *value > '9') {
        return false;
    }

    parsed = 0;
    while (*value >= '0' && *value <= '9') {
        digit = (unsigned int)(*value - '0');
        if (parsed > ((unsigned long)INT_MAX - digit) / 10) {
            return false;
        }
        parsed = parsed * 10 + digit;
        value++;
    }

    value = skipAsciiSpace(value);
    if (*value != '\0' || parsed < (unsigned long)minValue || parsed > (unsigned long)maxValue) {
        return false;
    }

    *result = (int)parsed;
    return true;
}

static bool equals(const char* value, const char* expected) {
    return value != NULL && strcmp(value, expected) == 0;
}

int parseDynamicHdrFormatValue(const char* value) {
    int parsed;

    if (parseUnsignedEnum(value, DYNAMIC_HDR_FORMAT_NONE,
                          DYNAMIC_HDR_FORMAT_DOLBY_VISION_PROFILE_84, &parsed)) {
        return parsed;
    }

    // Numeric values are the protocol representation. Textual aliases are
    // harmless and useful with early Sunshine development builds.
    value = skipAsciiSpace(value == NULL ? "" : value);
    if (equals(value, "hdr10_plus") || equals(value, "hdr10+")) {
        return DYNAMIC_HDR_FORMAT_HDR10_PLUS;
    }
    if (equals(value, "vivid_pq")) {
        return DYNAMIC_HDR_FORMAT_VIVID_PQ;
    }
    if (equals(value, "vivid_hlg")) {
        return DYNAMIC_HDR_FORMAT_VIVID_HLG;
    }
    if (equals(value, "dolby_vision_profile_81") || equals(value, "dvh1")) {
        return DYNAMIC_HDR_FORMAT_DOLBY_VISION_PROFILE_81;
    }
    if (equals(value, "dolby_vision_profile_84") || equals(value, "dvhe")) {
        return DYNAMIC_HDR_FORMAT_DOLBY_VISION_PROFILE_84;
    }

    return DYNAMIC_HDR_FORMAT_NONE;
}

int parseDynamicHdrFallbackValue(const char* value) {
    int parsed;

    // Fallback 1 was intentionally retired by the host protocol. Keep it
    // outside the accepted numeric range so it cannot be mistaken for a
    // current reason if a future host sends it.
    if (parseUnsignedEnum(value, DYNAMIC_HDR_FALLBACK_NONE,
                          DYNAMIC_HDR_FALLBACK_PREFERENCE, &parsed) &&
            parsed != 1) {
        return parsed;
    }

    value = skipAsciiSpace(value == NULL ? "" : value);
    if (equals(value, "none")) {
        return DYNAMIC_HDR_FALLBACK_NONE;
    }
    if (equals(value, "codec_unsupported")) {
        return DYNAMIC_HDR_FALLBACK_CODEC_UNSUPPORTED;
    }
    if (equals(value, "colorspace_unsupported")) {
        return DYNAMIC_HDR_FALLBACK_COLORSPACE_UNSUPPORTED;
    }
    if (equals(value, "client_caps_missing")) {
        return DYNAMIC_HDR_FALLBACK_CLIENT_CAPS_MISSING;
    }
    if (equals(value, "direct_surface_missing")) {
        return DYNAMIC_HDR_FALLBACK_DIRECT_SURFACE_MISSING;
    }
    if (equals(value, "preference")) {
        return DYNAMIC_HDR_FALLBACK_PREFERENCE;
    }

    return DYNAMIC_HDR_FALLBACK_NONE;
}
