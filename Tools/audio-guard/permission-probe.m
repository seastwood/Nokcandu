// Optional manual privacy regression. Build with build-permission-probe.sh.
// Uses a fresh app identity; never records or queues sound. On may show an OS prompt.
#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#include <unistd.h>
@interface ProbeDelegate : NSObject <NSApplicationDelegate>
@end
@implementation ProbeDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return YES; }
@end
int main(void) { @autoreleasepool {
    BOOL enabled = [NSBundle mainBundle].infoDictionary[@"NSMicrophoneUsageDescription"] != nil;
    setenv("NOKCANDU_NO_MICROPHONE", enabled ? "0" : "1", 1);
    NSApplication *app = [NSApplication sharedApplication];
    ProbeDelegate *delegate = [ProbeDelegate new]; app.delegate = delegate;
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,560,160)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    window.title = enabled ? @"Nokcandu Audio On Check" : @"Nokcandu Audio Off Check";
    NSTextField *label = [NSTextField labelWithString:enabled ? @"Checking normal permission handling. No audio is recorded." : @"Checking playback with microphone Off. No audio is recorded."];
    label.frame = NSMakeRect(20,20,520,120); [window.contentView addSubview:label]; [window makeKeyAndOrderFront:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        AudioDeviceID input = kAudioObjectUnknown; UInt32 size = sizeof(input);
        AudioObjectPropertyAddress address = {kAudioHardwarePropertyDefaultInputDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        OSStatus queried = AudioObjectGetPropertyData(kAudioObjectSystemObject,&address,0,NULL,&size,&input);
        AudioComponentDescription description = {kAudioUnitType_Output,kAudioUnitSubType_HALOutput,kAudioUnitManufacturer_Apple,0,0};
        AudioUnit unit = NULL;
        OSStatus created = AudioComponentInstanceNew(AudioComponentFindNext(NULL,&description),&unit);
        NSString *result = [NSString stringWithFormat:@"Microphone %@; pid=%d\nInput device=%u; query=%d; playback unit=%d\n",enabled?@"On":@"Off",getpid(),input,queried,created];
        if (!created) {
            result = [result stringByAppendingFormat:@"Playback initialize=%d\n",AudioUnitInitialize(unit)];
            AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit);
        }
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSBundle mainBundle].bundleIdentifier stringByAppendingString:@".log"]];
        [result writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        dispatch_async(dispatch_get_main_queue(), ^{ label.stringValue = [result stringByAppendingString:@"No recording or sound playback was performed. Close this window to exit."]; });
    });
    [app run]; return 0;
}}
