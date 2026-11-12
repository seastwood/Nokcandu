"""Compile the production gate and verify wired-only vendor-interface scope."""
import pathlib, subprocess, tempfile
root=pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as t:
 p=pathlib.Path(t);(p/'scope.c').write_text('''#include "steam-hid-interface.h"
int main(void){
 if(!nok_steam_wired_interface(0x28de,0x1102,1,0xff00,1))return 1;
 if(nok_steam_wired_interface(0x28de,0x1102,1,1,2))return 2;
 if(nok_steam_wired_interface(0x28de,0x1102,1,1,6))return 3;
 if(nok_steam_wired_interface(0x28de,0x1142,1,0xff00,1))return 4;
 if(nok_steam_wired_interface(0x28de,0x1102,0,0xff00,1))return 5;
 if(nok_steam_wired_interface(0x28de,0x1205,1,0xff00,1))return 6;
 if(nok_steam_wired_interface(0,0x1102,1,0xff00,1))return 7;
 return 0;
}''')
 subprocess.run(['xcrun','clang','-Wall','-Wextra','-Werror','-I',str(root/'Engine/controller-hid'),str(p/'scope.c'),'-o',str(p/'scope')],check=True)
 subprocess.run([str(p/'scope')],check=True)
 print('Steam wired allow/deny scope passed')
