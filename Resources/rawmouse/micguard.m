// Nokcandu: games without microphone access (Settings ▸ Sound ▸ Microphone off, NOKCANDU_NO_MICROPHONE=1) see no
// audio input devices at all, so they never open one and macOS never asks for microphone permission for them.
// Wine's audio driver finds inputs by asking each device for its input streams; here that answer is "none".

#include <CoreAudio/CoreAudio.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

static int mic_blocked(void)
{
    static int blocked = -1;
    if (blocked < 0) { const char *v = getenv("NOKCANDU_NO_MICROPHONE"); blocked = v && !strcmp(v, "1"); }
    return blocked;
}

static int is_input_query(AudioObjectID obj, const AudioObjectPropertyAddress *a)
{
    if (!a || !mic_blocked()) return 0;
    if (obj == kAudioObjectSystemObject)
        return a->mSelector == kAudioHardwarePropertyDefaultInputDevice;
    return a->mScope == kAudioObjectPropertyScopeInput &&
           (a->mSelector == kAudioDevicePropertyStreamConfiguration || a->mSelector == kAudioDevicePropertyStreams);
}

static OSStatus my_GetPropertyDataSize(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *size)
{
    if (is_input_query(obj, a) && size)
    {
        if (obj == kAudioObjectSystemObject) *size = sizeof(AudioObjectID);
        else *size = a->mSelector == kAudioDevicePropertyStreams ? 0 : (UInt32)offsetof(AudioBufferList, mBuffers);
        return noErr;
    }
    return AudioObjectGetPropertyDataSize(obj, a, qs, q, size);
}

static OSStatus my_GetPropertyData(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *size, void *data)
{
    if (is_input_query(obj, a) && size && data)
    {
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

__attribute__((used)) static const struct { const void *replacement, *original; } mic_interpose[]
    __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)my_GetPropertyDataSize, (const void *)AudioObjectGetPropertyDataSize },
    { (const void *)my_GetPropertyData, (const void *)AudioObjectGetPropertyData },
};
