/* Initialize D3D9 configuration only: no window, game, rendering or input. */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
int main(void) {
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    printf("D3D9 configuration probe initialized=%s\n", d3d ? "yes" : "no");
    if (!d3d) return 1;
    IDirect3D9_Release(d3d);
    return 0;
}
