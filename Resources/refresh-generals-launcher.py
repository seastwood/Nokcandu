from pathlib import Path
import hashlib,struct,zlib,sys,os
root=Path(sys.argv[1]).resolve()
source=root/'GeneralsOnlineZH.exe';b=source.read_bytes();digest=hashlib.sha256(b).hexdigest()
cache=root/'.wine-launcher-sha256'
required={'Launcher.dll','Launcher.runtimeconfig.json','Launcher.deps.json','Sentry.dll'}
if cache.exists() and cache.read_text().strip()==digest and all((root/n).is_file() for n in required):sys.exit(0)
sig=bytes.fromhex('8b1202b96a612038727b930214d7a03213f5b9e6efae3318ee3b2dce24b36aae');i=b.find(sig)
if i<8:raise SystemExit('Unsupported GeneralsOnline launcher bundle; setup needs updating.')
pos=struct.unpack_from('<q',b,i-8)[0]
def read(fmt):
 global pos
 if pos<0 or pos+struct.calcsize(fmt)>len(b):raise ValueError('Invalid bundle offset')
 v=struct.unpack_from(fmt,b,pos);pos+=struct.calcsize(fmt);return v[0] if len(v)==1 else v
def string():
 global pos
 n=0;shift=0
 while True:
  x=read('<B');n|=(x&127)<<shift
  if x<128:break
  shift+=7
  if shift>28:raise ValueError('Invalid bundle string')
 if pos+n>len(b):raise ValueError('Invalid bundle length')
 s=b[pos:pos+n].decode();pos+=n;return s
major,minor,count=read('<IIi');string()
if major!=6 or not 1<=count<=100:raise ValueError('Unsupported bundle format')
read('<qqqqQ');entries={}
for _ in range(count):
 off,size,compressed=read('<qqq');read('<B');name=string()
 if name not in required:raise ValueError('Unexpected launcher component: '+name)
 if off<0 or size<0 or compressed<0 or size>100_000_000 or off+(compressed or size)>len(b):raise ValueError('Invalid component bounds')
 data=b[off:off+(compressed or size)]
 if compressed:data=zlib.decompress(data,-15)
 if len(data)!=size:raise ValueError('Invalid component size')
 entries[name]=data
if set(entries)!=required:raise ValueError('Launcher components missing')
for name,data in entries.items():
 temp=root/(name+'.wine-tmp');temp.write_bytes(data);os.replace(temp,root/name)
cache.write_text(digest+'\n')
print('Refreshed unmodified .NET launcher components.')
