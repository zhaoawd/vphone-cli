#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
static IMP originalSet,originalGet;
static long raw(id object){return originalGet?((long(*)(id,SEL))originalGet)(object,sel_registerName("activeInterfaceOrientation")):-1;}
static long getOrientation(id object,SEL selector){long value=((long(*)(id,SEL))originalGet)(object,selector);fprintf(stderr,"B30_AX_READ pid=%d monotonic=%.6f raw=%ld\n",getpid(),CACurrentMediaTime(),value);return value;}
static void setOrientation(id object,SEL selector,long value){fprintf(stderr,"B30_AX_SET pid=%d monotonic=%.6f requested_raw=%ld before_raw=%ld\n",getpid(),CACurrentMediaTime(),value,raw(object));((void(*)(id,SEL,long))originalSet)(object,selector,value);fprintf(stderr,"B30_AX_RETURN pid=%d monotonic=%.6f after_raw=%ld\n",getpid(),CACurrentMediaTime(),raw(object));fflush(stderr);}
__attribute__((constructor)) static void install(void){
 if(!getenv("VPHONE_B30_ROTATION"))return;
 dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities",RTLD_NOW);
 Class cls=NSClassFromString(@"AXSpringBoardServer");
 Method setter=class_getInstanceMethod(cls,sel_registerName("setOrientation:"));Method getter=class_getInstanceMethod(cls,sel_registerName("activeInterfaceOrientation"));
 fprintf(stderr,"B30_AX_LOADED pid=%d class=%d setter=%d getter=%d\n",getpid(),cls!=Nil,setter!=NULL,getter!=NULL);
 if(setter&&getter){originalGet=method_setImplementation(getter,(IMP)getOrientation);originalSet=method_setImplementation(setter,(IMP)setOrientation);}
}
