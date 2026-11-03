// Manual test host for capture-switch.c. The managed game's switch prepares its Info.plist/policy.
#import <AppKit/AppKit.h>
@interface CaptureHostDelegate : NSObject <NSApplicationDelegate>
@end
@implementation CaptureHostDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return YES; }
@end
int main(void) { @autoreleasepool {
    NSString *contents=[[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"Contents"];
    NSString *support=[contents stringByAppendingPathComponent:@"SharedSupport"];
    NSString *config=[support stringByAppendingPathComponent:@"nokcandu/game.json"];
    NSDictionary *settings=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:config] options:0 error:NULL];
    BOOL on=[settings[@"microphone"] boolValue];
    NSApplication *app=[NSApplication sharedApplication];CaptureHostDelegate *delegate=[CaptureHostDelegate new];app.delegate=delegate;
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSWindow *window=[[NSWindow alloc]initWithContentRect:NSMakeRect(100,100,700,360) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    window.title=@"Nokcandu Microphone Switch Check";
    NSTextField *label=[NSTextField wrappingLabelWithString:on?@"Microphone On: approve this diagnostic's macOS prompt locally. Testing four seconds of input; only levels are retained.":@"Microphone Off: attempting to open input. The stream should be refused. No samples will be recorded."];
    label.frame=NSMakeRect(20,20,660,320);[window.contentView addSubview:label];[window makeKeyAndOrderFront:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_MSEC),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:@"/bin/bash"];
        task.arguments=@[[contents stringByAppendingPathComponent:@"MacOS/game-launcher"]];
        NSMutableDictionary *environment=[NSProcessInfo.processInfo.environment mutableCopy];environment[@"NOKCANDU_NO_GAME_APP"]=@"1";task.environment=environment;
        NSError *error=nil;BOOL launched=[task launchAndReturnError:&error];if(launched)[task waitUntilExit];
        NSString *log=[NSString stringWithContentsOfFile:[support stringByAppendingPathComponent:@"Logs/launch.log"] encoding:NSUTF8StringEncoding error:NULL]?:@"";
        NSMutableArray *summary=[NSMutableArray array];
        for(NSString *line in [log componentsSeparatedByString:@"\n"])if([line hasPrefix:@"MIC_SWITCH"]||[line hasPrefix:@"Input "])[summary addObject:line];
        NSString *result=[NSString stringWithFormat:@"Switch %@; launcher status=%d\n%@\n%@",on?@"On":@"Off",launched?task.terminationStatus:-1,[summary componentsJoinedByString:@"\n"],error?:@""];
        [result writeToFile:[support stringByAppendingPathComponent:@"nokcandu/capture-result.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        dispatch_async(dispatch_get_main_queue(),^{label.stringValue=[result stringByAppendingString:@"\nClose this window when finished. No recording was saved."];});
    });[app run];return 0;
}}
