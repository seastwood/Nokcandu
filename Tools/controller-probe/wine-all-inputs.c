/* Bounded, nonexclusive controller receipt. Never sends rumble or injects input.
 * Counts state changes per enumerated device without logging device identifiers. */
#define COBJMACROS
#define DIRECTINPUT_VERSION 0x0800
#include <windows.h>
#include <dinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static IDirectInput8A *di;
static HWND window;
static struct receipt { IDirectInputDevice8A *device; DIJOYSTATE2 prior; unsigned samples,errors,buttons,axes; } devices[16];
static unsigned count;
static BOOL CALLBACK found(const DIDEVICEINSTANCEA *d,void *context) {
 (void)context;
 if(count==16)return DIENUM_STOP;
 struct receipt *r=&devices[count];
 HRESULT hr=IDirectInput8_CreateDevice(di,&d->guidInstance,&r->device,NULL);
 if(SUCCEEDED(hr))hr=IDirectInputDevice8_SetDataFormat(r->device,&c_dfDIJoystick2);
 if(SUCCEEDED(hr))hr=IDirectInputDevice8_SetCooperativeLevel(r->device,window,DISCL_BACKGROUND|DISCL_NONEXCLUSIVE);
 if(SUCCEEDED(hr))hr=IDirectInputDevice8_Acquire(r->device);
 printf("device[%u] name=%s vid=%04x pid=%04x acquire=%08lx\n",count,d->tszProductName,LOWORD(d->guidProduct.Data1),HIWORD(d->guidProduct.Data1),(unsigned long)hr);
 ++count; return DIENUM_CONTINUE;
}
int main(int argc,char **argv) {
 unsigned seconds=argc>1?(unsigned)atoi(argv[1]):180;
 if(seconds<1||seconds>300)return 2;
 if(FAILED(DirectInput8Create(GetModuleHandleA(NULL),DIRECTINPUT_VERSION,&IID_IDirectInput8A,(void**)&di,NULL)))return 2;
 window=CreateWindowExA(0,"STATIC","Controller receipt",0,0,0,0,0,HWND_MESSAGE,NULL,GetModuleHandleA(NULL),NULL);
 Sleep(3000);
 IDirectInput8_EnumDevices(di,DI8DEVCLASS_GAMECTRL,found,NULL,DIEDFL_ATTACHEDONLY);
 puts("READY: nonexclusive receipt; no injected input");fflush(stdout);
 ULONGLONG end=GetTickCount64()+seconds*1000ULL, report=GetTickCount64()+1000;
 unsigned reported[16]={0};
 while(GetTickCount64()<end) {
  for(unsigned n=0;n<count;++n) {
   struct receipt *r=&devices[n]; if(!r->device)continue;
   DIJOYSTATE2 state={0}; IDirectInputDevice8_Poll(r->device);
   if(FAILED(IDirectInputDevice8_GetDeviceState(r->device,sizeof(state),&state))){++r->errors;continue;}
   if(r->samples) {
    for(unsigned b=0;b<128;++b)if((state.rgbButtons[b]&128)!=(r->prior.rgbButtons[b]&128))++r->buttons;
    if(memcmp(&state.lX,&r->prior.lX,6*sizeof(LONG)))++r->axes;
   }
   r->prior=state;++r->samples;
  }
  if(GetTickCount64()>=report) {
   for(unsigned n=0;n<count;++n)if(devices[n].buttons!=reported[n]) {
    printf("live device[%u] buttonTransitions=%u axisChanges=%u errors=%u\n",n,devices[n].buttons,devices[n].axes,devices[n].errors);
    reported[n]=devices[n].buttons;
   }
   fflush(stdout);report=GetTickCount64()+1000;
  }
  Sleep(8);
 }
 for(unsigned n=0;n<count;++n) {
  struct receipt *r=&devices[n];
  printf("device[%u] samples=%u errors=%u buttonTransitions=%u axisChanges=%u\n",n,r->samples,r->errors,r->buttons,r->axes);
  if(r->device){IDirectInputDevice8_Unacquire(r->device);IDirectInputDevice8_Release(r->device);}
 }
 if(window)DestroyWindow(window);IDirectInput8_Release(di);
 return count?0:1;
}
