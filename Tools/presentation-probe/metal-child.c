#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Separate-process renderer targeting a child HWND owned by this process. */
static char logpath[MAX_PATH];
static void report(const char *name,HRESULT hr) {
 FILE *f=fopen(logpath,"a"); if(f){fprintf(f,"%s: %08lx\n",name,(unsigned long)hr);fclose(f);}
}
static LRESULT CALLBACK proc(HWND w,UINT m,WPARAM a,LPARAM b){
 if(m==WM_DESTROY){PostQuitMessage(0);return 0;}return DefWindowProcA(w,m,a,b);
}
int main(int argc,char **argv){
 GetModuleFileNameA(NULL,logpath,sizeof(logpath));
 char *dot=strrchr(logpath,'.');if(dot)strcpy(dot,".log");
 if(argc>1 && strcmp(argv[1],"--root")){
  HWND child=(HWND)(UINT_PTR)strtoull(argv[1],NULL,16);
  DXGI_SWAP_CHAIN_DESC d={0};ID3D11Device *dev=NULL;ID3D11DeviceContext *ctx=NULL;
  IDXGISwapChain *swap=NULL;ID3D11Texture2D *tex=NULL;ID3D11RenderTargetView *view=NULL;
  d.BufferDesc.Width=480;d.BufferDesc.Height=300;d.BufferDesc.Format=DXGI_FORMAT_R8G8B8A8_UNORM;
  d.SampleDesc.Count=1;d.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT;d.BufferCount=2;
  d.OutputWindow=child;d.Windowed=TRUE;d.SwapEffect=DXGI_SWAP_EFFECT_DISCARD;
  HRESULT hr=D3D11CreateDeviceAndSwapChain(NULL,D3D_DRIVER_TYPE_HARDWARE,NULL,0,NULL,0,D3D11_SDK_VERSION,&d,&swap,&dev,NULL,&ctx);
  report("foreign target swapchain",hr);if(FAILED(hr))return 2;
  hr=IDXGISwapChain_GetBuffer(swap,0,&IID_ID3D11Texture2D,(void**)&tex);report("backbuffer",hr);
  if(SUCCEEDED(hr))hr=ID3D11Device_CreateRenderTargetView(dev,(ID3D11Resource*)tex,NULL,&view);
  report("target view",hr);if(FAILED(hr))return 3;
  for(int i=0;i<90;i++){float color[4]={i<45?1.0f:0.2f,0.2f,i<45?0.2f:1.0f,1.0f};
   ID3D11DeviceContext_ClearRenderTargetView(ctx,view,color);hr=IDXGISwapChain_Present(swap,0,0);if(FAILED(hr))break;Sleep(16);}
  report("present",hr);ID3D11RenderTargetView_Release(view);ID3D11Texture2D_Release(tex);
  IDXGISwapChain_Release(swap);ID3D11DeviceContext_Release(ctx);ID3D11Device_Release(dev);return FAILED(hr)?4:0;
 }
 FILE *f=fopen(logpath,"w");if(f)fclose(f);
 WNDCLASSA wc={0};wc.lpfnWndProc=proc;wc.hInstance=GetModuleHandleA(NULL);wc.lpszClassName="NokMetalChildProbe";
 RegisterClassA(&wc);
 HWND root=CreateWindowExA(0,wc.lpszClassName,"Nokcandu cross-process Metal probe",WS_OVERLAPPEDWINDOW|WS_VISIBLE,100,100,640,480,NULL,NULL,wc.hInstance,NULL);
 HWND child=CreateWindowExA(0,wc.lpszClassName,"Render target",WS_CHILD|WS_VISIBLE,40,40,480,300,root,NULL,wc.hInstance,NULL);
 char exe[MAX_PATH],cmd[2*MAX_PATH];GetModuleFileNameA(NULL,exe,sizeof(exe));snprintf(cmd,sizeof(cmd),"\"%s\" %llx",exe,(unsigned long long)(UINT_PTR)(argc>1 ? root : child));
 STARTUPINFOA si={0};PROCESS_INFORMATION pi={0};si.cb=sizeof(si);
 if(!CreateProcessA(NULL,cmd,NULL,NULL,FALSE,0,NULL,NULL,&si,&pi)){report("worker launch",HRESULT_FROM_WIN32(GetLastError()));return 5;}
 DWORD start=GetTickCount();MSG msg;
 while(WaitForSingleObject(pi.hProcess,0)==WAIT_TIMEOUT&&GetTickCount()-start<20000){while(PeekMessageA(&msg,NULL,0,0,PM_REMOVE)){TranslateMessage(&msg);DispatchMessageA(&msg);}Sleep(10);}
 DWORD code=9;GetExitCodeProcess(pi.hProcess,&code);if(code==STILL_ACTIVE){TerminateProcess(pi.hProcess,9);code=9;}
 report("worker exit",code);CloseHandle(pi.hProcess);CloseHandle(pi.hThread);DestroyWindow(root);return (int)code;
}
