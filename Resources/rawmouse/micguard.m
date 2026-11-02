// Nokcandu: games without microphone access (Settings ▸ Sound ▸ Microphone off, NOKCANDU_NO_MICROPHONE=1) see no
// audio input devices at all, so they never open one and macOS never asks for microphone permission for them.
// Wine's audio driver finds inputs by asking each device for its input streams; here that answer is "none".

#include <CoreAudio/CoreAudio.h>
#include "microphone-policy.h"
#include <stddef.h>
#include <crt_externs.h>
#include <dlfcn.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

int nokcandu_microphone_blocked(void)
{
    // Per-program settings can be applied during loader initialization. Do not
    // cache an earlier inherited launcher value before those settings arrive.
    Dl_info info;
    if (dladdr((const void *)nokcandu_microphone_blocked, &info) && info.dli_fname) {
        char file[PATH_MAX];
        if (strlcpy(file, info.dli_fname, sizeof(file)) < sizeof(file)) {
            char *slash = strrchr(file, '/');
            if (slash) {
                slash[1] = 0;
                char directory[PATH_MAX]; strlcpy(directory, file, sizeof(directory));
                int argc = *_NSGetArgc(); char **argv = *_NSGetArgv();
                if (strlcat(file, "program-microphones.tsv", sizeof(file)) < sizeof(file)) {
                    int choice = argc > 1 ? nokcandu_microphone_route(file, argv[1], getenv("SteamAppId")) : -1;
                    if (choice >= 0) return choice;
                }
                strlcpy(file, directory, sizeof(file));
                if (strlcat(file, "microphone-policy", sizeof(file)) < sizeof(file)) {
                    FILE *policy = fopen(file, "r");
                    if (policy) { int value = fgetc(policy); fclose(policy); return value != '0'; }
                }
            }
        }
    }
    const char *v = getenv("NOKCANDU_NO_MICROPHONE");
    return v && !strcmp(v, "1");
}

static int is_input_query(AudioObjectID obj, const AudioObjectPropertyAddress *a)
{
    if (!a) return 0;
    int input = obj == kAudioObjectSystemObject ? a->mSelector == kAudioHardwarePropertyDefaultInputDevice :
        a->mScope == kAudioObjectPropertyScopeInput &&
        (a->mSelector == kAudioDevicePropertyStreamConfiguration || a->mSelector == kAudioDevicePropertyStreams);
    return input && nokcandu_microphone_blocked();
}

static OSStatus my_GetPropertyDataSize(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *size)
{
    if (is_input_query(obj, a))
    {
        if (!size) return kAudioHardwareBadPropertySizeError;
        if (obj == kAudioObjectSystemObject) *size = sizeof(AudioObjectID);
        else *size = a->mSelector == kAudioDevicePropertyStreams ? 0 : (UInt32)offsetof(AudioBufferList, mBuffers);
        return noErr;
    }
    return AudioObjectGetPropertyDataSize(obj, a, qs, q, size);
}

static OSStatus my_GetPropertyData(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *size, void *data)
{
    if (is_input_query(obj, a))
    {
        if (!size || (!data && a->mSelector != kAudioDevicePropertyStreams)) return kAudioHardwareBadPropertySizeError;
        if (obj == kAudioObjectSystemObject)
        {
            if (*size < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            *(AudioObjectID *)data = kAudioObjectUnknown;
            *size = sizeof(AudioObjectID);
        }
        else if (a->mSelector == kAudioDevicePropertyStreams) *size = 0;
        else
        {
            if (*size < offsetof(AudioBufferList, mBuffers)) return kAudioHardwareBadPropertySizeError;
            ((AudioBufferList *)data)->mNumberBuffers = 0;
            *size = (UInt32)offsetof(AudioBufferList, mBuffers);
        }
        return noErr;
    }
    return AudioObjectGetPropertyData(obj, a, qs, q, size, data);
}

#ifndef NOKCANDU_AUDIO_TEST
__attribute__((used)) static const struct { const void *replacement, *original; } mic_interpose[]
    __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)my_GetPropertyDataSize, (const void *)AudioObjectGetPropertyDataSize },
    { (const void *)my_GetPropertyData, (const void *)AudioObjectGetPropertyData },
};

#endif
