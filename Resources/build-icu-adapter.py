from pathlib import Path
import struct,re
import argparse
parser=argparse.ArgumentParser(description='Create the x86 ICU API adapter used by the validated Generals recipe.')
parser.add_argument('icu_directory',type=Path,help='Microsoft ICU 72.1 x86 native DLL directory')
parser.add_argument('output',type=Path,help='Output icu.dll path')
args=parser.parse_args()
names=sorted(['ucal_close','ucal_get','ucal_getCanonicalTimeZoneID','ucal_getDefaultTimeZone','ucal_getTimeZoneDisplayName','ucal_getTimeZoneTransitionDate','ucal_getTZDataVersion','ucal_inDaylightTime','ucal_open','ucal_openTimeZoneIDEnumeration','ucal_setMillis','uenum_close','uenum_count','uenum_unext'])
libs={p.stem:p.read_bytes() for p in args.icu_directory.glob('*.dll')}
forward={}
for name in names:
    module='icuuc72' if name.startswith('uenum_') else 'icuin72'
    symbol=name+'_72'
    if module not in libs or symbol.encode()+b'\0' not in libs[module]:
        raise ValueError('Required ICU 72 symbol missing: '+module+'.'+symbol)
    forward[name]=module+'.'+symbol
n=len(names);data=bytearray(40+n*10)
def add(s):
 off=len(data);data.extend(s.encode()+b'\0');return 0x1000+off
module=add('icu.dll');nameptr=[add(s) for s in names];funcptr=[add(forward[s]) for s in names]
struct.pack_into('<IIHHIIIIIII',data,0,0,0,0,0,module,1,n,n,0x1028,0x1028+n*4,0x1028+n*8)
for i in range(n):
 struct.pack_into('<I',data,40+i*4,funcptr[i]);struct.pack_into('<I',data,40+n*4+i*4,nameptr[i]);struct.pack_into('<H',data,40+n*8+i*2,i)
headers=bytearray(512);headers[:2]=b'MZ';struct.pack_into('<I',headers,60,128);headers[128:132]=b'PE\0\0'
struct.pack_into('<HHIIIHH',headers,132,0x14c,1,0,0,0,224,0x2102)
o=152;struct.pack_into('<H',headers,o,0x10b);struct.pack_into('<I',headers,o+8,len(data));struct.pack_into('<I',headers,o+24,0x1000)
struct.pack_into('<III',headers,o+28,0x10000000,0x1000,512);struct.pack_into('<HH',headers,o+40,6,0);struct.pack_into('<HH',headers,o+48,6,0)
struct.pack_into('<II',headers,o+56,8192,512);struct.pack_into('<HH',headers,o+68,3,0x100)
struct.pack_into('<IIIIII',headers,o+72,0x100000,4096,0x100000,4096,0,16)
struct.pack_into('<II',headers,o+96,0x1000,len(data))
raw=(len(data)+511)//512*512
struct.pack_into('<8sIIIIIIHHI',headers,376,b'.edata\0\0',len(data),0x1000,raw,512,0,0,0,0,0x40000040)
args.output.write_bytes(headers+data+bytes(raw-len(data)))
print('Created ICU API forwarder for',n,'time-zone functions')
