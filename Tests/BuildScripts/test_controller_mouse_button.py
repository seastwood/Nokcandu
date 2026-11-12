"""Compile the actual patched Wine mouse handler against a counting input sink."""
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
class ControllerMouseButtonTests(unittest.TestCase):
 def test_real_mouse_stays_absolute_and_controller_click_cannot_move_cursor(self):
  for version,folder in [('10.0','patches'),('11.0','patches-11.0')]:
   with self.subTest(version=version), tempfile.TemporaryDirectory() as tmp:
    temp=Path(tmp)
    with tarfile.open(ROOT/'build/winemac-work'/('wine-'+version+'.tar.xz')) as archive:
     original=archive.extractfile('wine-'+version+'/dlls/winemac.drv/mouse.c').read().decode()
    file=temp/'mouse.c';file.write_text(original)
    patch=(ROOT/'Engine/winemac'/folder/'0014-controller-button-without-cursor-warp.patch').read_text()
    patch=patch[patch.index('--- a/dlls/winemac.drv/mouse.c'):]
    subprocess.run(['patch','--batch',str(file)],input=patch,text=True,check=True,capture_output=True)
    body=file.read_text().split('void macdrv_mouse_button(HWND hwnd, const macdrv_event *event)',1)[1].split('\n}\n',1)[0]+'\n}\n'
    harness=r'''
#include <assert.h>
#include <stdbool.h>
#include "controller-mouse-button.h"
typedef unsigned UINT; typedef unsigned short WORD; typedef int BOOL; typedef void* HWND;
#define FALSE 0
#define TRACE(...) ((void)0)
#define MOUSEEVENTF_LEFTDOWN 2
#define MOUSEEVENTF_LEFTUP 4
#define MOUSEEVENTF_RIGHTDOWN 8
#define MOUSEEVENTF_RIGHTUP 16
#define MOUSEEVENTF_MIDDLEDOWN 32
#define MOUSEEVENTF_MIDDLEUP 64
#define MOUSEEVENTF_XDOWN 128
#define MOUSEEVENTF_XUP 256
#define MOUSEEVENTF_ABSOLUTE 32768
#define MOUSEEVENTF_MOVE 1
typedef struct { void *window; struct { int button; bool pressed; int x,y; unsigned long time_ms; } mouse_button; } macdrv_event;
static UINT received; static int calls;
static void send_mouse_input(HWND hwnd,void *window,UINT flags,int x,int y,WORD data,BOOL drag,unsigned long time) { received=flags; ++calls; }
void macdrv_mouse_button(HWND hwnd,const macdrv_event *event)
'''
    harness+=body+r'''
int main(void) {
 macdrv_event event={0}; event.mouse_button.x=123; event.mouse_button.y=456;
 for(int b=0;b<5;++b)for(int down=0;down<2;++down) {
  event.mouse_button.pressed=down; event.mouse_button.button=b;
  macdrv_mouse_button(0,&event);
  assert((received & (MOUSEEVENTF_MOVE|MOUSEEVENTF_ABSOLUTE)) == (MOUSEEVENTF_MOVE|MOUSEEVENTF_ABSOLUTE));
  UINT ordinary=received;
  event.mouse_button.button=-b-1; macdrv_mouse_button(0,&event);
  assert(received == (ordinary & ~(MOUSEEVENTF_MOVE|MOUSEEVENTF_ABSOLUTE)));
 }
 int prior=calls; event.mouse_button.button=-6;macdrv_mouse_button(0,&event);assert(calls==prior);
 return 0;
}
'''
    (temp/'test.c').write_text(harness)
    subprocess.run(['xcrun','clang','-Werror','-I'+str(ROOT/'Engine/winemac'),str(temp/'test.c'),'-o',str(temp/'test')],check=True,capture_output=True)
    subprocess.run([str(temp/'test')],check=True)
if __name__=='__main__':unittest.main()
