#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
__attribute__((constructor))static void inspect(void){if(!getenv("VPHONE_B31_LAUNCH_INSPECT"))return;@autoreleasepool{void *h=dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",RTLD_NOW);Class c=NSClassFromString(@"FBSOpenApplicationOptions");for(unsigned z=0;z<2;z++){unsigned n=0;Method *list=class_copyMethodList(z?object_getClass(c):c,&n);for(unsigned i=0;i<n;i++)fprintf(stderr,"B31_OPTIONS %c %s %s\n",z?'+':'-',sel_getName(method_getName(list[i])),method_getTypeEncoding(list[i]));free(list);}for(const char **s=(const char *[]){"FBSOpenApplicationOptionKeyEnvironmentVariables","FBSOpenApplicationOptionKeyArguments","FBSOpenApplicationOptionKeyDebuggingOptions","FBSOpenApplicationOptionKeyUnlockDevice","FBSOpenApplicationOptionKeyActivateSuspended",NULL};*s;s++){NSString *__unsafe_unretained *v=(NSString *__unsafe_unretained *)dlsym(h,*s);fprintf(stderr,"B31_OPTIONKEY %s value=%s\n",*s,v?[*v UTF8String]:"missing");}fprintf(stderr,"B31_LAUNCH_INSPECT_DONE pid=%d\n",getpid());fflush(stderr);}}
