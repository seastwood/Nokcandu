// Nokcandu: Windows games follow the Mac's default sound devices.
//
// Wine's Mac audio driver opens each sound stream on one specific device: the Mac's default at the moment the
// game opened it. Plug in headphones (or pick another output) while a game runs and its sound stays on the old
// device until the game restarts; Windows itself has no way to learn of the change either (Wine's device list is
// fixed at start). This part of Nokcandu's helper library, loaded into every Wine process, notices streams that
// were opened on the default device and moves them to the new default when macOS changes it — output and input
// (microphone) separately. Streams the game opened on a particular device it chose are left alone.
//
// It watches the Audio Unit calls Wine makes (interposed), and on a change stops the unit, points it at the new
// device and starts it again if it was running. The Audio Unit converts the game's format to the new device's,
// so nothing changes on the Windows side.

#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

#define MAX_UNITS 64

struct followed_unit
{
    AudioUnit unit;
    BOOL capture;     // input (microphone) unit
    BOOL follows;     // opened on the default device: follow it
    BOOL running;
};

static struct followed_unit units[MAX_UNITS];
static pthread_mutex_t units_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t listen_once = PTHREAD_ONCE_INIT;

static void af_log(const char *fmt, ...)
{
    if (!getenv("NOKCANDU_AUDIO_DEBUG")) return;
    va_list a;
    va_start(a, fmt);
    fprintf(stderr, "nokcandu-audio: ");
    vfprintf(stderr, fmt, a);
    fputc('\n', stderr);
    va_end(a);
}

static struct followed_unit *find_unit(AudioUnit unit, BOOL create)
{
    struct followed_unit *free_slot = NULL;
    for (int i = 0; i < MAX_UNITS; i++)
    {
        if (units[i].unit == unit) return &units[i];
        if (!units[i].unit && !free_slot) free_slot = &units[i];
    }
    if (create && free_slot)
    {
        memset(free_slot, 0, sizeof(*free_slot));
        free_slot->unit = unit;
        return free_slot;
    }
    return NULL;
}

static AudioDeviceID default_device(BOOL capture)
{
    AudioObjectPropertyAddress addr = {
        capture ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioDeviceID dev = kAudioObjectUnknown;
    UInt32 size = sizeof(dev);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &dev) != noErr)
        return kAudioObjectUnknown;
    return dev;
}


// Moves one unit to a device. Called without units_lock held (the unit's own calls can block on audio threads).
static void move_unit(AudioUnit unit, AudioDeviceID dev, BOOL was_running)
{
    OSStatus sc;
    if (was_running) AudioOutputUnitStop(unit);
    AudioUnitUninitialize(unit);
    sc = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, sizeof(dev));
    AudioUnitInitialize(unit);
    if (was_running) AudioOutputUnitStart(unit);
    af_log("moved unit %p to device %u (%d)", unit, (unsigned)dev, (int)sc);
}

static void default_changed(BOOL capture)
{
    AudioDeviceID dev = default_device(capture);
    struct { AudioUnit unit; BOOL running; } todo[MAX_UNITS];
    int n = 0;

    if (dev == kAudioObjectUnknown) return;
    pthread_mutex_lock(&units_lock);
    for (int i = 0; i < MAX_UNITS; i++)
    {
        if (units[i].unit && units[i].follows && units[i].capture == capture)
        {
            todo[n].unit = units[i].unit;
            todo[n].running = units[i].running;
            n++;
        }
    }
    pthread_mutex_unlock(&units_lock);
    for (int i = 0; i < n; i++) move_unit(todo[i].unit, dev, todo[i].running);
}

static OSStatus output_changed(AudioObjectID obj, UInt32 n, const AudioObjectPropertyAddress *a, void *ctx)
{
    default_changed(NO);
    return noErr;
}

static OSStatus input_changed(AudioObjectID obj, UInt32 n, const AudioObjectPropertyAddress *a, void *ctx)
{
    default_changed(YES);
    return noErr;
}

static void start_listening(void)
{
    AudioObjectPropertyAddress out = { kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectPropertyAddress in = { kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &out, output_changed, NULL);
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &in, input_changed, NULL);
    af_log("following the Mac's default sound devices");
}

static OSStatus my_AudioUnitSetProperty(AudioUnit unit, AudioUnitPropertyID prop, AudioUnitScope scope,
                                        AudioUnitElement elem, const void *data, UInt32 size)
{
    OSStatus sc = AudioUnitSetProperty(unit, prop, scope, elem, data, size);
    if (sc != noErr || !data) return sc;

    if (prop == kAudioOutputUnitProperty_EnableIO && scope == kAudioUnitScope_Input && elem == 1 &&
        size == sizeof(UInt32) && *(const UInt32 *)data)
    {
        pthread_mutex_lock(&units_lock);
        struct followed_unit *u = find_unit(unit, YES);
        if (u) u->capture = YES;
        pthread_mutex_unlock(&units_lock);
    }
    else if (prop == kAudioOutputUnitProperty_CurrentDevice && size == sizeof(AudioDeviceID))
    {
        pthread_mutex_lock(&units_lock);
        struct followed_unit *u = find_unit(unit, YES);
        if (u)
        {
            AudioDeviceID dev = *(const AudioDeviceID *)data;
            u->follows = dev == default_device(u->capture);
            af_log("%s unit %p on device %u%s", u->capture ? "input" : "output", unit, (unsigned)dev,
                   u->follows ? " (default: follows it)" : "");
        }
        pthread_mutex_unlock(&units_lock);
        pthread_once(&listen_once, start_listening);
    }
    return sc;
}

static OSStatus my_AudioOutputUnitStart(AudioUnit unit)
{
    OSStatus sc = AudioOutputUnitStart(unit);
    pthread_mutex_lock(&units_lock);
    struct followed_unit *u = find_unit(unit, NO);
    if (u && sc == noErr) u->running = YES;
    pthread_mutex_unlock(&units_lock);
    return sc;
}

static OSStatus my_AudioOutputUnitStop(AudioUnit unit)
{
    OSStatus sc = AudioOutputUnitStop(unit);
    pthread_mutex_lock(&units_lock);
    struct followed_unit *u = find_unit(unit, NO);
    if (u) u->running = NO;
    pthread_mutex_unlock(&units_lock);
    return sc;
}

static OSStatus my_AudioComponentInstanceDispose(AudioComponentInstance unit)
{
    pthread_mutex_lock(&units_lock);
    struct followed_unit *u = find_unit(unit, NO);
    if (u) memset(u, 0, sizeof(*u));
    pthread_mutex_unlock(&units_lock);
    return AudioComponentInstanceDispose(unit);
}

__attribute__((used)) static const struct { const void *replacement, *original; } audio_interpose[]
    __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)my_AudioUnitSetProperty, (const void *)AudioUnitSetProperty },
    { (const void *)my_AudioOutputUnitStart, (const void *)AudioOutputUnitStart },
    { (const void *)my_AudioOutputUnitStop, (const void *)AudioOutputUnitStop },
    { (const void *)my_AudioComponentInstanceDispose, (const void *)AudioComponentInstanceDispose },
};
