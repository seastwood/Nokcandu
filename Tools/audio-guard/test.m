// No audio hardware is accessed: every CoreAudio/AudioUnit boundary is mocked.
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
static int input_queries, output_queries, input_listeners, output_listeners, capture_enables, output_sets;
static OSStatus fake_data(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *size, void *data) {
    (void)obj;(void)qs;(void)q;
    if(a->mSelector==kAudioHardwarePropertyDefaultInputDevice)input_queries++;else output_queries++;
    if(data && *size>=sizeof(AudioDeviceID)){*(AudioDeviceID*)data=47;*size=sizeof(AudioDeviceID);}return noErr;
}
static OSStatus fake_size(AudioObjectID obj,const AudioObjectPropertyAddress*a,UInt32 qs,const void*q,UInt32*size){(void)obj;(void)a;(void)qs;(void)q;*size=sizeof(AudioDeviceID);return noErr;}
static OSStatus fake_listener(AudioObjectID obj,const AudioObjectPropertyAddress*a,AudioObjectPropertyListenerProc p,void*c){(void)obj;(void)p;(void)c;if(a->mSelector==kAudioHardwarePropertyDefaultInputDevice)input_listeners++;else output_listeners++;return noErr;}
static OSStatus fake_set(AudioUnit u,AudioUnitPropertyID p,AudioUnitScope s,AudioUnitElement e,const void*d,UInt32 n){(void)u;if(p==kAudioOutputUnitProperty_EnableIO&&s==kAudioUnitScope_Input&&e==1&&n==sizeof(UInt32)&&*(const UInt32*)d)capture_enables++;else output_sets++;return noErr;}
static OSStatus fake_unit(AudioUnit u){(void)u;return noErr;}
static OSStatus fake_legacy_device(AudioDeviceID d,UInt32 c,Boolean input,AudioDevicePropertyID p,UInt32*n,void*v){(void)c;(void)p;if(input)input_queries++;else output_queries++;if(v&&n&&*n>=sizeof(AudioDeviceID)){*(AudioDeviceID*)v=47;*n=sizeof(AudioDeviceID);}return noErr;}
static OSStatus fake_legacy_info(AudioDeviceID d,UInt32 c,Boolean input,AudioDevicePropertyID p,UInt32*n,Boolean*w){(void)d;(void)c;(void)p;if(input)input_queries++;else output_queries++;if(n)*n=sizeof(AudioDeviceID);if(w)*w=true;return noErr;}
static OSStatus fake_hardware(AudioHardwarePropertyID p,UInt32*n,void*v){AudioObjectPropertyAddress a={p,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};return fake_data(kAudioObjectSystemObject,&a,0,NULL,n,v);}
static OSStatus fake_hardware_info(AudioHardwarePropertyID p,UInt32*n,Boolean*w){if(p==kAudioHardwarePropertyDefaultInputDevice)input_queries++;else output_queries++;if(n)*n=sizeof(AudioDeviceID);if(w)*w=true;return noErr;}
#define AudioDeviceGetProperty fake_legacy_device
#define AudioDeviceGetPropertyInfo fake_legacy_info
#define AudioHardwareGetProperty fake_hardware
#define AudioHardwareGetPropertyInfo fake_hardware_info
#define NOKCANDU_AUDIO_TEST 1
#define AudioObjectGetPropertyData fake_data
#define AudioObjectGetPropertyDataSize fake_size
#define AudioObjectAddPropertyListener fake_listener
#define AudioUnitSetProperty fake_set
#define AudioOutputUnitStart fake_unit
#define AudioOutputUnitStop fake_unit
#define AudioUnitUninitialize fake_unit
#define AudioUnitInitialize fake_unit
#define AudioComponentInstanceDispose fake_unit
#include "micguard.m"
#include "audiofollow.m"
#define CHECK(x) do{if(!(x)){fprintf(stderr,"Failure at line %d: %s\n",__LINE__,#x);return 1;}}while(0)
int main(int argc,char**argv){
    CHECK(argc==2);int stripped=!strcmp(argv[1],"stripped");int off=strcmp(argv[1],"on")!=0;
    if(stripped)unsetenv("NOKCANDU_NO_MICROPHONE");else setenv("NOKCANDU_NO_MICROPHONE",off?"1":"0",1);
    AudioObjectPropertyAddress a={kAudioHardwarePropertyDefaultInputDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    AudioDeviceID device=99;UInt32 size=sizeof(device),enabled=1;
    CHECK(my_GetPropertyData(kAudioObjectSystemObject,&a,0,NULL,&size,&device)==noErr);
    CHECK(device==(off?kAudioObjectUnknown:47));CHECK(input_queries==(off?0:1));
    if(off){CHECK(my_GetPropertyData(kAudioObjectSystemObject,&a,0,NULL,NULL,NULL)!=noErr);CHECK(input_queries==0);}
    CHECK(default_device(YES)==(off?kAudioObjectUnknown:47));
    CHECK(my_AudioUnitSetProperty((AudioUnit)1,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Input,1,&enabled,sizeof(enabled))==(off?kAudioUnitErr_CannotDoInCurrentContext:noErr));
    CHECK(capture_enables==(off?0:1));
    device=47;CHECK(my_AudioUnitSetProperty((AudioUnit)2,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&device,sizeof(device))==noErr);
    CHECK(output_sets==1);CHECK(output_queries>0);CHECK(output_listeners==1);CHECK(input_listeners==(off?0:1));
    CHECK(my_AudioOutputUnitStart((AudioUnit)2)==noErr);CHECK(my_AudioOutputUnitStop((AudioUnit)2)==noErr);
    CHECK(my_AudioComponentInstanceDispose((AudioUnit)2)==noErr);
    // The HAL component uses legacy APIs internally; On forwards unchanged, Off never calls them.
    int before_inputs=input_queries,before_outputs=output_queries;
    AudioBufferList buffers={0};size=sizeof(buffers);Boolean writable=true;
    CHECK(my_AudioDeviceGetProperty(47,0,true,kAudioDevicePropertyStreamConfiguration,&size,&buffers)==noErr);
    if(off)CHECK(buffers.mNumberBuffers==0);
    CHECK(my_AudioDeviceGetPropertyInfo(47,0,true,kAudioDevicePropertyStreams,&size,&writable)==noErr);
    CHECK(writable==!off);
    device=99;size=sizeof(device);CHECK(my_AudioHardwareGetProperty(kAudioHardwarePropertyDefaultInputDevice,&size,&device)==noErr);
    CHECK(device==(off?kAudioObjectUnknown:47));
    CHECK(my_AudioHardwareGetPropertyInfo(kAudioHardwarePropertyDefaultInputDevice,&size,&writable)==noErr);
    CHECK(input_queries==before_inputs+(off?0:4));
    size=sizeof(device);CHECK(my_AudioDeviceGetProperty(47,0,false,kAudioDevicePropertyStreams,&size,&device)==noErr);
    CHECK(my_AudioHardwareGetProperty(kAudioHardwarePropertyDefaultOutputDevice,&size,&device)==noErr);
    CHECK(output_queries==before_outputs+2);
    // A policy applied after loader initialization must supersede an inherited value.
    setenv("NOKCANDU_NO_MICROPHONE",off?"0":"1",1);CHECK(nokcandu_microphone_blocked()==(stripped?1:!off));
    printf("Microphone %s: capture policy enforced, output preserved, no hardware calls.\n",off?"off":"on");return 0;
}
