// Per-program microphone policy: capture is blocked while Off. Legacy HAL input
// queries stay hidden to avoid duplex playback permission requests. In live mode,
// modern read-only discovery remains available because Wine caches endpoints.

#include <CoreAudio/CoreAudio.h>
#include "microphone-policy.h"
#include <stddef.h>
#include <crt_externs.h>
#include <dlfcn.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

// Apple's HAL audio unit still calls the legacy device APIs internally. Those
// functions call CoreAudio's own implementation, bypassing dyld interposition
// of AudioObjectGetPropertyData. Hide inputs at both public API boundaries.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static char microphone_program[PATH_MAX];
__attribute__((constructor(101))) static void remember_microphone_program(void)
{
    const char *program = nokcandu_microphone_program(*_NSGetArgc(), *_NSGetArgv());
    if (program && strlcpy(microphone_program, program, sizeof(microphone_program)) >= sizeof(microphone_program))
        microphone_program[0] = 0; // Unknown identities use the prefix's safe default.
}

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
                if (strlcat(file, "program-microphones.tsv", sizeof(file)) < sizeof(file)) {
                    int choice = microphone_program[0] ? nokcandu_microphone_route(file, microphone_program, getenv("SteamAppId")) : -1;
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

// Wine caches its endpoint list for the life of a process. Live mode keeps
// read-only device discovery available; capture itself remains denied below
// AudioUnit EnableIO/Start/Render. HAL's internal legacy queries stay hidden
// while Off so duplex playback does not ask for microphone permission.
static int microphone_live_mode(void)
{
    Dl_info info;
    char path[PATH_MAX];
    if (!dladdr((const void *)nokcandu_microphone_blocked, &info) || !info.dli_fname ||
        strlcpy(path, info.dli_fname, sizeof(path)) >= sizeof(path)) return 0;
    char *slash = strrchr(path, '/');
    if (!slash) return 0;
    slash[1] = 0;
    if (strlcat(path, "microphone-live", sizeof(path)) >= sizeof(path)) return 0;
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    int live = fgetc(f) == '1'; fclose(f); return live;
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

static AudioObjectPropertyAddress legacy_device_address(UInt32 channel, Boolean input, AudioDevicePropertyID property)
{
    return (AudioObjectPropertyAddress){property,
        input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput, channel};
}

static OSStatus my_AudioDeviceGetProperty(AudioDeviceID device, UInt32 channel, Boolean input,
                                         AudioDevicePropertyID property, UInt32 *size, void *data)
{
    AudioObjectPropertyAddress a = legacy_device_address(channel, input, property);
    if (is_input_query(device, &a)) return my_GetPropertyData(device, &a, 0, NULL, size, data);
    return AudioDeviceGetProperty(device, channel, input, property, size, data);
}

static OSStatus my_AudioDeviceGetPropertyInfo(AudioDeviceID device, UInt32 channel, Boolean input,
                                             AudioDevicePropertyID property, UInt32 *size, Boolean *writable)
{
    AudioObjectPropertyAddress a = legacy_device_address(channel, input, property);
    if (is_input_query(device, &a)) {
        if (writable) *writable = false;
        UInt32 ignored;
        return my_GetPropertyDataSize(device, &a, 0, NULL, size ? size : &ignored);
    }
    return AudioDeviceGetPropertyInfo(device, channel, input, property, size, writable);
}

static OSStatus my_AudioHardwareGetProperty(AudioHardwarePropertyID property, UInt32 *size, void *data)
{
    AudioObjectPropertyAddress a = {property, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (is_input_query(kAudioObjectSystemObject, &a)) return my_GetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, size, data);
    return AudioHardwareGetProperty(property, size, data);
}

static OSStatus my_AudioHardwareGetPropertyInfo(AudioHardwarePropertyID property, UInt32 *size, Boolean *writable)
{
    AudioObjectPropertyAddress a = {property, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (is_input_query(kAudioObjectSystemObject, &a)) {
        if (writable) *writable = false;
        UInt32 ignored;
        return my_GetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, size ? size : &ignored);
    }
    return AudioHardwareGetPropertyInfo(property, size, writable);
}

static OSStatus live_GetPropertyDataSize(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *size)
{
    if (microphone_live_mode()) return AudioObjectGetPropertyDataSize(obj, a, qs, q, size);
    return my_GetPropertyDataSize(obj, a, qs, q, size);
}
static OSStatus live_GetPropertyData(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *size, void *data)
{
    if (microphone_live_mode()) return AudioObjectGetPropertyData(obj, a, qs, q, size, data);
    return my_GetPropertyData(obj, a, qs, q, size, data);
}

#ifndef NOKCANDU_AUDIO_TEST
__attribute__((used)) static const struct { const void *replacement, *original; } mic_interpose[]
    __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)live_GetPropertyDataSize, (const void *)AudioObjectGetPropertyDataSize },
    { (const void *)live_GetPropertyData, (const void *)AudioObjectGetPropertyData },
    { (const void *)my_AudioDeviceGetProperty, (const void *)AudioDeviceGetProperty },
    { (const void *)my_AudioDeviceGetPropertyInfo, (const void *)AudioDeviceGetPropertyInfo },
    { (const void *)my_AudioHardwareGetProperty, (const void *)AudioHardwareGetProperty },
    { (const void *)my_AudioHardwareGetPropertyInfo, (const void *)AudioHardwareGetPropertyInfo },
};

#endif
#pragma clang diagnostic pop
