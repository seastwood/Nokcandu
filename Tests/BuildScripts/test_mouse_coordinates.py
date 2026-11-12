"""Coordinate validation using the actual helper bridge header, without UI/device access."""
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
class MouseCoordinateTests(unittest.TestCase):
    def test_scaled_origin_retina_round_trip_and_validation(self):
        with tempfile.TemporaryDirectory(prefix="nok-mouse-space-") as tmp:
            work=Path(tmp); source=work/'test.m'; binary=work/'test'
            source.write_text(r'''
#import "mouse-coordinate-space.h"
#include "controller-mouse-button.h"
@interface Conversion : NSObject
@property double scale, x, y;
@end
@implementation Conversion
- (CGPoint)nokcanduWindowsMousePoint:(CGPoint)p { return CGPointMake((p.x-self.x)/self.scale,(p.y-self.y)/self.scale); }
- (CGPoint)nokcanduMacMousePoint:(CGPoint)p { return CGPointMake(p.x*self.scale+self.x,p.y*self.scale+self.y); }
@end
@interface Invalid : NSObject
@end
@implementation Invalid
- (CGPoint)nokcanduWindowsMousePoint:(CGPoint)p { (void)p;return CGPointMake(NAN,0); }
@end
int main(void) { @autoreleasepool {
 const double scales[]={0.5,0.75,1,1.25,2};
 for(unsigned i=0;i<5;++i)for(unsigned j=0;j<3;++j) {
  Conversion *c=[Conversion new];c.scale=scales[i];c.x=j==0?-1920:(j==1?240:0);c.y=j==2?-200:90;
  CGPoint mac=CGPointMake(c.x+333.5*c.scale,c.y+222.25*c.scale),game,back;
  if(!nokcandu_mouse_point(c,mac,true,&game))return 1;
  if(!nokcandu_mouse_position_matches(333,222,game,0))return 2;
  if(nokcandu_mouse_position_matches(340,222,game,2))return 3;
  if(!nokcandu_mouse_point(c,game,false,&back)||fabs(mac.x-back.x)>1e-9||fabs(mac.y-back.y)>1e-9)return 4;
 }
 Conversion *virtual=[Conversion new];virtual.scale=.5;virtual.x=300;virtual.y=200;
 CGPoint physical=CGPointMake(550,350),logical;
 if(nokcandu_mouse_position_matches(500,300,physical,2))return 5; // old validation rejects the correct virtual event
 if(!nokcandu_mouse_point(virtual,physical,true,&logical)||!nokcandu_mouse_position_matches(500,300,logical,2))return 6;
 CGPoint legacy;
 if(!nokcandu_mouse_point([NSObject new],physical,true,&legacy)||!CGPointEqualToPoint(physical,legacy))return 7;
 if(nokcandu_mouse_point([Invalid new],physical,true,&legacy))return 8;
 if(nokcandu_mouse_position_matches(0,0,CGPointMake(NAN,0),3))return 9;
 // Raw capture: a physical click while aiming loses its position only on a driver that can take it,
 // and decodes in the driver to the same button. Everything else is untouched.
 for(int b=0;b<5;++b) {
  int sent=nokcandu_click_button(b,true,true);
  if(sent>=0||nokcandu_controller_button(sent)!=b)return 10;
  if(nokcandu_click_button(b,false,true)!=b||nokcandu_click_button(b,true,false)!=b)return 11;
 }
 if(nokcandu_click_button(5,true,true)!=5||nokcandu_click_button(7,true,true)!=7)return 12;
 if(nokcandu_click_button(-1,true,true)!=-1)return 13;
 return 0;
}}
''')
            subprocess.run(['xcrun','clang','-Wall','-Wextra','-Werror','-fobjc-arc','-I',str(ROOT/'Resources/rawmouse'),'-I',str(ROOT/'Engine/winemac'),str(source),'-framework','Foundation','-framework','CoreGraphics','-o',str(binary)],check=True,capture_output=True,text=True)
            result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
if __name__=='__main__':unittest.main()
