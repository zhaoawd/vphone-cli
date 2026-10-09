#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <mach/mach.h>
#include <unistd.h>
OBJC_EXTERN UIImage *_UICreateScreenUIImage(void) NS_RETURNS_RETAINED;
static unsigned long long memory(void){task_vm_info_data_t i={0};mach_msg_type_number_t n=TASK_VM_INFO_COUNT;if(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&i,&n))return 0;return i.phys_footprint;}
int main(void){setvbuf(stdout,NULL,_IOLBF,0);@autoreleasepool{
 printf("BEFORE %llu\n",memory());
 for(int i=0;i<22;i++){@autoreleasepool{
  UIImage *raw=_UICreateScreenUIImage();if(!raw)return 1;
  size_t w=CGImageGetWidth(raw.CGImage),h=CGImageGetHeight(raw.CGImage);CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();CGContextRef ctx=CGBitmapContextCreate(NULL,w,h,8,w*4,space,kCGImageAlphaPremultipliedLast);CGColorSpaceRelease(space);if(!ctx)return 4;CGContextDrawImage(ctx,CGRectMake(0,0,w,h),raw.CGImage);CGImageRef copy=CGBitmapContextCreateImage(ctx);CGContextRelease(ctx);
  NSMutableData *data=[NSMutableData data];CGImageDestinationRef d=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,CFSTR("public.jpeg"),1,NULL);if(!d)return 2;
  CGImageDestinationAddImage(d,copy,(__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality:@.8});bool ok=CGImageDestinationFinalize(d);CFRelease(d);CGImageRelease(copy);if(!ok)return 3;
  UIImage *decoded=[UIImage imageWithData:data];printf("CAPTURE %d width=%zu bytes=%lu footprint=%llu\n",i,CGImageGetWidth(decoded.CGImage),(unsigned long)data.length,memory());
 }if(i==1)printf("BASELINE %llu\n",memory());}
 for(int i=0;i<3;i++){sleep(5);printf("SETTLED %llu\n",memory());}
 }return 0;}
