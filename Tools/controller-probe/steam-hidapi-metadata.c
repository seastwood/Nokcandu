/* Link against pinned upstream HIDAPI for discovery only; never print serial/path
 * or open an input stream, send features, reset settings or alter firmware. */
#include <stdio.h>
#include "hidapi.h"
int main(void){
 if(hid_init())return 2;
 struct hid_device_info *head=hid_enumerate(0x28de,0x1102);unsigned count=0;
 for(struct hid_device_info *d=head;d;d=d->next){++count;
  printf("Upstream HIDAPI wired Valve: usage=%04x:%04x interface=%d bus=%d\n",d->usage_page,d->usage,d->interface_number,(int)d->bus_type);
 }
 hid_free_enumeration(head);hid_exit();printf("Wired vendor entries=%u\n",count);return count?0:1;
}
