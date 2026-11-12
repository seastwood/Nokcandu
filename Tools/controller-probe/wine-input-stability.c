/* Nonexclusive, bounded DirectInput receipt. No rumble, properties, mode writes or input injection. */
#define COBJMACROS
#define DIRECTINPUT_VERSION 0x0800
#include <windows.h>
#include <dinput.h>
#include <stdio.h>
#include <string.h>
static IDirectInput8A *di;
static GUID pro;
static int found;
static BOOL CALLBACK find_pro(const DIDEVICEINSTANCEA *d, void *context) {
    (void)context;
    if (LOWORD(d->guidProduct.Data1)==0x057e && HIWORD(d->guidProduct.Data1)==0x2009) { pro=d->guidInstance;found=1;return DIENUM_STOP; }
    return DIENUM_CONTINUE;
}
int main(void) {
    HRESULT hr=DirectInput8Create(GetModuleHandleA(NULL),DIRECTINPUT_VERSION,&IID_IDirectInput8A,(void**)&di,NULL);
    if(FAILED(hr)){printf("DirectInput initialization=%08lx\n",(unsigned long)hr);return 2;}
    IDirectInput8_EnumDevices(di,DI8DEVCLASS_GAMECTRL,find_pro,NULL,DIEDFL_ATTACHEDONLY);
    if(!found){puts("No attached native Pro Controller in DirectInput; no device was acquired");IDirectInput8_Release(di);return 1;}
    IDirectInputDevice8A *device=NULL;
    hr=IDirectInput8_CreateDevice(di,&pro,&device,NULL);
    HWND window=CreateWindowExA(0,"STATIC","Nokcandu receipt diagnostic",0,0,0,0,0,HWND_MESSAGE,NULL,GetModuleHandleA(NULL),NULL);
    if(SUCCEEDED(hr))hr=IDirectInputDevice8_SetDataFormat(device,&c_dfDIJoystick2);
    if(SUCCEEDED(hr))hr=IDirectInputDevice8_SetCooperativeLevel(device,window,DISCL_BACKGROUND|DISCL_NONEXCLUSIVE);
    if(SUCCEEDED(hr))hr=IDirectInputDevice8_Acquire(device);
    printf("Native Pro Controller nonexclusive acquire=%08lx\n",(unsigned long)hr);
    DIDEVCAPS caps={0};caps.dwSize=sizeof(caps);
    if(device&&SUCCEEDED(IDirectInputDevice8_GetCapabilities(device,&caps)))
        printf("Native reported controls: buttons=%lu axes=%lu\n",(unsigned long)caps.dwButtons,(unsigned long)caps.dwAxes);
    unsigned samples=0,failed=0,transitions=0;DIJOYSTATE2 prior={0};unsigned per_button[32]={0};
    if(SUCCEEDED(hr))for(unsigned i=0;i<375;++i){DIJOYSTATE2 current={0};IDirectInputDevice8_Poll(device);
        HRESULT state=IDirectInputDevice8_GetDeviceState(device,sizeof(current),&current);
        if(SUCCEEDED(state)){if(samples)for(unsigned b=0;b<32;++b)if((prior.rgbButtons[b]&0x80)!=(current.rgbButtons[b]&0x80)){++transitions;++per_button[b];}prior=current;++samples;}else ++failed;
        Sleep(8);
    }
    printf("Window API samples=%u failures=%u button transitions=%u over approximately 3 seconds\n",samples,failed,transitions);
    for(unsigned b=0;b<32;++b)if(per_button[b])printf("button %u transitions=%u\n",b,per_button[b]);
    unsigned held=0;for(unsigned b=0;b<32;++b)if(prior.rgbButtons[b]&0x80)++held;
    printf("Final held button count=%u (physical activity not controlled)\n",held);
    if(device){IDirectInputDevice8_Unacquire(device);IDirectInputDevice8_Release(device);}if(window)DestroyWindow(window);IDirectInput8_Release(di);
    puts("Aggregate receipt only; physical activity and other readers must be controlled before judging validity.");return samples?0:2;
}
