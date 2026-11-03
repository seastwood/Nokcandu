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
#include "microphone-policy.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <unistd.h>

#define MAX_UNITS 64

struct followed_unit
{
    AudioUnit unit;
    BOOL capture;     // input (microphone) unit
    BOOL follows;     // opened on the default device: follow it
    BOOL running;
    BOOL suspended;
};

static struct followed_unit units[MAX_UNITS];
static pthread_mutex_t units_lock = PTHREAD_MUTEX_INITIALIZER;
// Serialize unit changes and disposal, but never hold units_lock during HAL
// stop/start: HAL can wait for its realtime callback. Render uses only atomics.
static pthread_mutex_t operations_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic(AudioUnit) capture_units[MAX_UNITS];
static atomic_int capture_blocked;
static pthread_once_t monitor_once = PTHREAD_ONCE_INIT;
static pthread_once_t input_listen_once = PTHREAD_ONCE_INIT;
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
    if (capture && nokcandu_microphone_blocked()) return kAudioObjectUnknown;
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
    pthread_mutex_lock(&operations_lock);
    AudioDeviceID dev = default_device(capture);
    struct { AudioUnit unit; BOOL running; } todo[MAX_UNITS];
    int n = 0;

    if (dev == kAudioObjectUnknown) { pthread_mutex_unlock(&operations_lock); return; }
    pthread_mutex_lock(&units_lock);
    for (int i = 0; i < MAX_UNITS; i++)
    {
        if (units[i].unit && units[i].follows && units[i].capture == capture)
        {
            todo[n].unit = units[i].unit;
            todo[n].running = units[i].running && !units[i].suspended;
            n++;
        }
    }
    pthread_mutex_unlock(&units_lock);
    for (int i = 0; i < n; i++) move_unit(todo[i].unit, dev, todo[i].running);
    pthread_mutex_unlock(&operations_lock);
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

static void start_input_listener(void)
{
    AudioObjectPropertyAddress in = { kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &in, input_changed, NULL);
}
static void start_listening(void)
{
    AudioObjectPropertyAddress out = { kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &out, output_changed, NULL);
    if (!nokcandu_microphone_blocked()) pthread_once(&input_listen_once, start_input_listener);
    af_log("following the Mac's default sound devices");
}

// Called off the realtime thread. Off stops existing capture, On resumes only
// streams the game still wants running. Playback units are never touched.
static void update_microphone_policy(void)
{
    int blocked = nokcandu_microphone_blocked();
    atomic_store_explicit(&capture_blocked, blocked, memory_order_release);
    if (!blocked) pthread_once(&input_listen_once, start_input_listener);
    pthread_mutex_lock(&operations_lock);
    for (int i = 0; i < MAX_UNITS; i++) {
        struct followed_unit *u = &units[i];
        if (!u->unit || !u->capture || !u->running) continue;
        if (blocked && !u->suspended) {
            if (AudioOutputUnitStop(u->unit) == noErr) u->suspended = YES;
        } else if (!blocked && u->suspended) {
            if (AudioOutputUnitStart(u->unit) == noErr) u->suspended = NO;
        }
    }
    pthread_mutex_unlock(&operations_lock);
}
static void *monitor_microphone(void *unused)
{
    (void)unused;
    for (;;) { update_microphone_policy(); usleep(250000); }
    return NULL;
}
static void start_microphone_monitor(void)
{
    atomic_store(&capture_blocked, nokcandu_microphone_blocked());
#ifndef NOKCANDU_AUDIO_TEST
    pthread_t thread;
    if (!pthread_create(&thread, NULL, monitor_microphone, NULL)) pthread_detach(thread);
#endif
}
static OSStatus my_AudioUnitRender(AudioUnit unit, AudioUnitRenderActionFlags *flags,
    const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *data)
{
    if (atomic_load_explicit(&capture_blocked, memory_order_acquire)) {
        for (int i = 0; i < MAX_UNITS; i++) {
            if (atomic_load_explicit(&capture_units[i], memory_order_acquire) != unit) continue;
            if (data) for (UInt32 b = 0; b < data->mNumberBuffers; b++)
                if (data->mBuffers[b].mData) memset(data->mBuffers[b].mData, 0, data->mBuffers[b].mDataByteSize);
            if (flags) *flags |= kAudioUnitRenderAction_OutputIsSilence;
            return noErr;
        }
    }
    return AudioUnitRender(unit, flags, time, bus, frames, data);
}

static OSStatus my_AudioUnitSetProperty(AudioUnit unit, AudioUnitPropertyID prop, AudioUnitScope scope,
                                        AudioUnitElement elem, const void *data, UInt32 size)
{
    // Block before CoreAudio can request capture permission, including cached
    // Windows endpoints that bypass device enumeration. Output is unaffected.
    if (prop == kAudioOutputUnitProperty_EnableIO && scope == kAudioUnitScope_Input && elem == 1 &&
        data && size == sizeof(UInt32) && *(const UInt32 *)data && nokcandu_microphone_blocked())
        return kAudioUnitErr_CannotDoInCurrentContext;
    pthread_once(&monitor_once, start_microphone_monitor);
    pthread_mutex_lock(&operations_lock);
    if (prop == kAudioOutputUnitProperty_EnableIO && scope == kAudioUnitScope_Input && elem == 1 &&
        data && size == sizeof(UInt32) && *(const UInt32 *)data && !find_unit(unit, YES)) {
        pthread_mutex_unlock(&operations_lock);
        return kAudioUnitErr_CannotDoInCurrentContext; // Never allow untracked capture.
    }
    OSStatus sc = AudioUnitSetProperty(unit, prop, scope, elem, data, size);
    if (sc != noErr || !data) { pthread_mutex_unlock(&operations_lock); return sc; }

    if (prop == kAudioOutputUnitProperty_EnableIO && scope == kAudioUnitScope_Input && elem == 1 &&
        size == sizeof(UInt32))
    {
        pthread_mutex_lock(&units_lock);
        struct followed_unit *u = find_unit(unit, *(const UInt32 *)data != 0);
        if (u) {
            u->capture = *(const UInt32 *)data != 0;
            atomic_store_explicit(&capture_units[u - units], u->capture ? unit : NULL, memory_order_release);
        }
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
    pthread_mutex_unlock(&operations_lock);
    return sc;
}

static OSStatus my_AudioOutputUnitStart(AudioUnit unit)
{
    pthread_once(&monitor_once, start_microphone_monitor);
    pthread_mutex_lock(&operations_lock);
    struct followed_unit *u = find_unit(unit, NO);
    BOOL blocked = u && u->capture && nokcandu_microphone_blocked();
    OSStatus sc = blocked ? noErr : AudioOutputUnitStart(unit);
    if (u && sc == noErr) { u->running = YES; u->suspended = blocked; }
    pthread_mutex_unlock(&operations_lock);
    return sc;
}

static OSStatus my_AudioOutputUnitStop(AudioUnit unit)
{
    pthread_mutex_lock(&operations_lock);
    OSStatus sc = AudioOutputUnitStop(unit);
    struct followed_unit *u = find_unit(unit, NO);
    if (u && sc == noErr) { u->running = NO; u->suspended = NO; }
    pthread_mutex_unlock(&operations_lock);
    return sc;
}

static OSStatus my_AudioComponentInstanceDispose(AudioComponentInstance unit)
{
    pthread_mutex_lock(&operations_lock);
    struct followed_unit *u = find_unit(unit, NO);
    if (u) {
        atomic_store_explicit(&capture_units[u - units], NULL, memory_order_release);
        memset(u, 0, sizeof(*u));
    }
    OSStatus sc = AudioComponentInstanceDispose(unit);
    pthread_mutex_unlock(&operations_lock);
    return sc;
}

#ifndef NOKCANDU_AUDIO_TEST
__attribute__((used)) static const struct { const void *replacement, *original; } audio_interpose[]
    __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)my_AudioUnitRender, (const void *)AudioUnitRender },
    { (const void *)my_AudioUnitSetProperty, (const void *)AudioUnitSetProperty },
    { (const void *)my_AudioOutputUnitStart, (const void *)AudioOutputUnitStart },
    { (const void *)my_AudioOutputUnitStop, (const void *)AudioOutputUnitStop },
    { (const void *)my_AudioComponentInstanceDispose, (const void *)AudioComponentInstanceDispose },
};

#endif
