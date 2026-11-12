// Describe the installed engine's SDL devices. No controller opens, outputs,
// report capture, rumble, discovery/pairing calls or profile changes.
#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc,char **argv) { @autoreleasepool {
 if(argc!=2)return 2;
 [NSApplication sharedApplication];
 void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
 if(!lib){puts("SDL load failed");return 2;}
 int(*init)(uint32_t)=dlsym(lib,"SDL_InitSubSystem");
 void(*quit)(uint32_t)=dlsym(lib,"SDL_QuitSubSystem");
 int(*count)(void)=dlsym(lib,"SDL_NumJoysticks");
 const char *(*name)(int)=dlsym(lib,"SDL_JoystickNameForIndex");
 uint16_t(*vendor)(int)=dlsym(lib,"SDL_JoystickGetDeviceVendor");
 uint16_t(*product)(int)=dlsym(lib,"SDL_JoystickGetDeviceProduct");
 int(*controller)(int)=dlsym(lib,"SDL_IsGameController");
 void(*pump)(void)=dlsym(lib,"SDL_PumpEvents");
 void(*version)(void*)=dlsym(lib,"SDL_GetVersion");
 if(!init||!quit||!count||!name||!vendor||!product||!controller||!pump)return 2;
 uint8_t v[3]={0};if(version)version(v);
 printf("SDL %u.%u.%u MFI=%s\n",v[0],v[1],v[2],getenv("SDL_JOYSTICK_MFI")?:"default");fflush(stdout);
 if(init(0x2000|0x200)!=0){puts("SDL initialization failed");return 2;}
 NSDate *end=[NSDate dateWithTimeIntervalSinceNow:4];
 while([end timeIntervalSinceNow]>0){pump();[[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];}
 int n=count();printf("SDL enumerated=%d\n",n);
 for(int i=0;i<n;++i)printf("device[%d] vid=%04x pid=%04x controllerMapping=%d name=%s\n",i,vendor(i),product(i),controller(i),name(i)?:"unknown");
 quit(0x2000|0x200);return 0;
}}
