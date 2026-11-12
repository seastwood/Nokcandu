/* Read-only Windows enumeration: no acquire, state polling, output reports or rumble. */
#define COBJMACROS
#define DIRECTINPUT_VERSION 0x0800
#include <windows.h>
#include <dinput.h>
#include <xinput.h>
#include <stdio.h>
#include <setupapi.h>
#include <hidsdi.h>
#include <wchar.h>
#include <stdlib.h>
#include <string.h>
static unsigned count;
static BOOL CALLBACK found(const DIDEVICEINSTANCEA *d, void *context)
{
    (void)context;
    printf("DirectInput: %s; product=%s; vid=%04lx pid=%04lx\n", d->tszInstanceName,
           d->tszProductName, d->guidProduct.Data1 & 0xffff, d->guidProduct.Data1 >> 16);
    ++count;
    return DIENUM_CONTINUE;
}
static void valve_hid_inventory(void)
{
    GUID hid; HidD_GetHidGuid(&hid);
    HDEVINFO list = SetupDiGetClassDevsW(&hid, NULL, NULL, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
    if (list == INVALID_HANDLE_VALUE) { puts("Valve HID inventory unavailable"); return; }
    unsigned count = 0;
    for (DWORD index = 0;; ++index) {
        SP_DEVICE_INTERFACE_DATA iface = { .cbSize = sizeof(iface) };
        if (!SetupDiEnumDeviceInterfaces(list, NULL, &hid, index, &iface)) {
            if (GetLastError() != ERROR_NO_MORE_ITEMS) puts("HID interface enumeration incomplete");
            break;
        }
        DWORD bytes = 0;
        SetupDiGetDeviceInterfaceDetailW(list, &iface, NULL, 0, &bytes, NULL);
        if (bytes < sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W) || bytes > 65536) continue;
        SP_DEVICE_INTERFACE_DETAIL_DATA_W *detail = calloc(1, bytes);
        if (!detail) break;
        detail->cbSize = sizeof(*detail);
        if (SetupDiGetDeviceInterfaceDetailW(list, &iface, detail, bytes, NULL, NULL)) {
            /* Print only VID/PID, never device paths, serials or addresses. */
            for (WCHAR *p = detail->DevicePath; *p; ++p) if (*p >= L'A' && *p <= L'Z') *p += L'a' - L'A';
            const WCHAR *vendor = wcsstr(detail->DevicePath, L"vid_28de&pid_");
            unsigned pid;
            if (vendor && swscanf(vendor, L"vid_28de&pid_%4x", &pid) == 1) {
                ++count; printf("Valve HID interface: 28de:%04x interface2=%u (description only; not opened)\n", pid, wcsstr(detail->DevicePath,L"mi_02") != NULL);
            }
        }
        free(detail);
    }
    SetupDiDestroyDeviceInfoList(list);
    printf("Valve present HID interfaces=%u; receiver presence does not prove a connected controller\n", count);
}
int main(void)
{
    valve_hid_inventory();
    IDirectInput8A *di = NULL;
    HRESULT hr = DirectInput8Create(GetModuleHandleA(NULL), DIRECTINPUT_VERSION,
                                    &IID_IDirectInput8A, (void **)&di, NULL);
    if (FAILED(hr)) { printf("DirectInput initialization failed: %08lx\n", (unsigned long)hr); return 2; }
    /* Device arrival is asynchronous; report once after a bounded settling interval. */
    Sleep(3000);
    hr = IDirectInput8_EnumDevices(di, DI8DEVCLASS_GAMECTRL, found, NULL, DIEDFL_ATTACHEDONLY);
    printf("DirectInput attached=%u; result=%08lx\n", count, (unsigned long)hr);
    IDirectInput8_Release(di);
    HMODULE x = LoadLibraryA("xinput1_4.dll");
    typedef DWORD (WINAPI *get_caps)(DWORD,DWORD,XINPUT_CAPABILITIES *);
    get_caps caps = NULL;
    FARPROC proc = x ? GetProcAddress(x,"XInputGetCapabilities") : NULL;
    _Static_assert(sizeof(caps) == sizeof(proc), "Windows function pointer size");
    memcpy(&caps, &proc, sizeof(caps));
    unsigned n=0;
    if (caps) for (DWORD i=0;i<4;++i) { XINPUT_CAPABILITIES c; if (!caps(i,0,&c)) { ++n; printf("XInput slot=%lu type=%u subtype=%u\n", i,c.Type,c.SubType); } }
    printf("XInput connected=%u; API available=%u\n",n,caps!=NULL);
    if(x) FreeLibrary(x);
    return FAILED(hr) ? 2 : (count || n ? 0 : 1);
}
