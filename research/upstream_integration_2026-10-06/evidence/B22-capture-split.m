#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <mach/mach.h>
#include <unistd.h>
OBJC_EXTERN UIImage *_UICreateScreenUIImage(void) NS_RETURNS_RETAINED;
static unsigned long long memory(void){task_vm_info_data_t i={0};mach_msg_type_number_t n=TASK_VM_INFO_COUNT;if(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&i,&n))return 0;return i.phys_footprint;}
int main(int argc,char **argv){if(argc!=2)return 64;int mode=atoi(argv[1]);setvbuf(stdout,NULL,_IOLBF,0);@autoreleasepool{
 printf("MODE %d BEFORE %llu\n",mode,memory());
 for(int i=0;i<22;i++){@autoreleasepool{
  UIImage *raw=_UICreateScreenUIImage(); if(!raw)return 1;
  if(mode>=1){UIImage *image=[UIImage imageWithCGImage:raw.CGImage scale:raw.scale orientation:UIImageOrientationUp];
   if(mode>=2){NSData *data=UIImageJPEGRepresentation(image,.8);
    if(mode>=3){UIImage *decoded=[UIImage imageWithData:data];printf("WIDTH %zu\n",CGImageGetWidth(decoded.CGImage));}
   }
  }
 }printf("CAPTURE %d footprint=%llu\n",i,memory()); if(i==1)printf("BASELINE %llu\n",memory());}
 for(int i=0;i<3;i++){sleep(5);printf("SETTLED %llu\n",memory());}
 }return 0;}
