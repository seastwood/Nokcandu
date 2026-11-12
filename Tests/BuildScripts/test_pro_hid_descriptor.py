"""Exact-descriptor USB correction: synthetic packets only, no device access."""
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
def fields(data):
    i=0; report=0; size=0; count=0; page=0; offsets={}; output=[]
    while i<len(data):
        b=data[i];i+=1
        n=(0,1,2,4)[b&3];v=int.from_bytes(data[i:i+n],'little');i+=n
        kind=(b>>2)&3;tag=b>>4
        if kind==1:
            if tag==0:page=v
            elif tag==7:size=v
            elif tag==8:report=v
            elif tag==9:count=v
        elif kind==0 and tag in (8,9,11):
            offset=offsets.get((report,tag),0);offsets[report,tag]=offset+size*count
            output.append((report,tag,offset,size,count,page,v))
    return output,offsets
class ProHIDDescriptorTests(unittest.TestCase):
    def test_scope_layout_and_noninput_reports(self):
        with tempfile.TemporaryDirectory(prefix='nok-pro-descriptor-') as t:
            work=Path(t); src=work/'probe.c'; exe=work/'probe'
            src.write_text(r'''
#include "pro-hid-descriptor.h"
#include <stdio.h>
int main(void){size_t n;const unsigned char *p;
 p=nok_pro_descriptor(0x057e,0x2009,true,nok_pro_original,sizeof(nok_pro_original),&n);
 if(p!=nok_pro_full_state||n!=sizeof(nok_pro_full_state))return 1;
 for(unsigned i=0;i<4;++i){
  p=nok_pro_descriptor(i==0?0:0x057e,i==1?0:0x2009,i!=2,nok_pro_original,sizeof(nok_pro_original)-(i==3),&n);
  if(p!=nok_pro_original)return 2;
 }
 unsigned char changed[sizeof(nok_pro_original)];memcpy(changed,nok_pro_original,sizeof(changed));changed[10]^=1;
 if(nok_pro_descriptor(0x057e,0x2009,true,changed,sizeof(changed),&n)!=changed)return 3;
 FILE *a=fopen("original.bin","wb"),*b=fopen("corrected.bin","wb");
 if(!a||!b)return 4;
 fwrite(nok_pro_original,1,sizeof(nok_pro_original),a);fwrite(nok_pro_full_state,1,sizeof(nok_pro_full_state),b);fclose(a);fclose(b);return 0;
}
''')
            subprocess.run(['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror','-I',str(ROOT/'Engine/controller-hid'),str(src),'-o',str(exe)],check=True,capture_output=True,text=True)
            subprocess.run([str(exe)],cwd=work,check=True,timeout=10)
            old,old_sizes=fields((work/'original.bin').read_bytes());new,new_sizes=fields((work/'corrected.bin').read_bytes())
            self.assertEqual(new_sizes,old_sizes,'All report byte lengths remain unchanged')
            self.assertEqual([f for f in old if f[0]!=0x30],[f for f in new if f[0]!=0x30],'Vendor input/output field shapes preserved')
            buttons=[f for f in new if f[0]==0x30 and f[5]==9 and f[6]==2]
            axes=next(f for f in new if f[0]==0x30 and f[5]==1 and f[6]==2)
            self.assertEqual([f[2:5] for f in buttons],[(16,1,4),(22,1,8),(32,1,4),(38,1,2)])
            def decode(bits):
                value=0; shift=0
                for f in buttons:
                    value|=((bits>>f[2])&((1<<f[4])-1))<<shift
                    shift+=f[4]
                return value
            self.assertEqual(axes[2:5],(40,12,4))
            # Packet counter/battery variations must not become button transitions.
            states=[];old_states=[]
            for timer in range(256):
                payload=bytes([timer,0x91,0x80,0x02,0x40])+bytes(58)
                bits=int.from_bytes(payload,'little')
                states.append(decode(bits));old_states.append(bits&0x3fff)
            self.assertEqual(len(set(states)),1)
            self.assertGreater(len(set(old_states)),1,'Old descriptor reproduces false buttons from timer')
            # Every actual button survives independently; reserved status bits do not.
            active=[16,17,18,19,22,23,24,25,26,27,28,29,32,33,34,35,38,39]
            for index,offset in enumerate(active):self.assertEqual(decode(1<<offset),1<<index)
            for offset in [20,21,30,31,36,37]:self.assertEqual(decode(1<<offset),0)
            values=[0,4095,2048,1234]
            packed=sum(value<<(40+12*i) for i,value in enumerate(values))
            self.assertEqual([(packed>>(axes[2]+12*i))&4095 for i in range(4)],values)
if __name__=='__main__':unittest.main()
