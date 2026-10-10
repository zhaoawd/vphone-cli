#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static id obj(id x,const char *s){SEL v=sel_registerName(s);return [x respondsToSelector:v]?((id(*)(id,SEL))objc_msgSend)(x,v):nil;}
static void methods(id x){if(!x)return;Class c=object_getClass(x);unsigned n=0;Method *m=class_copyMethodList(c,&n);for(unsigned i=0;i<n;i++)fprintf(stderr,"B31_OBJECT_METHOD %s %s %s\n",class_getName(c),sel_getName(method_getName(m[i])),method_getTypeEncoding(m[i]));free(m);}
static void query(void){@autoreleasepool{@try{
 fprintf(stderr,"B31_QUERY_BEGIN pid=%d\n",getpid());
 id ax=obj(NSClassFromString(@"AXSpringBoardServer"),"server");
 for(const char **s=(const char *[]){"focusedApps","focusedAppProcess","focusedOccludedAppScenes",NULL};*s;s++){id v=obj(ax,*s);fprintf(stderr,"B31_AX %s value=%s\n",*s,[[v description] UTF8String]);methods(v);}
 SEL app=sel_registerName("applicationWithIdentifier:");if([ax respondsToSelector:app]){for(NSString *name in @[@"com.apple.Preferences",@"com.apple.mobilesafari"]){id v=((id(*)(id,SEL,id))objc_msgSend)(ax,app,name);fprintf(stderr,"B31_AX_APP %s value=%s\n",name.UTF8String,[[v description] UTF8String]);methods(v);}}
 id manager=obj(NSClassFromString(@"FBSceneManager"),"sharedInstance");fprintf(stderr,"B31_MANAGER %s\n",[[manager description] UTF8String]);
 SEL pass=sel_registerName("scenesPassingTest:");if([manager respondsToSelector:pass]){__block unsigned n=0;id v=((id(*)(id,SEL,id))objc_msgSend)(manager,pass,^BOOL(id scene){n++;fprintf(stderr,"B31_SCENE %s\n",[[scene description] UTF8String]);id settings=obj(scene,"clientSettings");fprintf(stderr,"B31_SCENE_SETTINGS %s\n",[[settings description] UTF8String]);return NO;});fprintf(stderr,"B31_SCENE_COUNT %u result=%s\n",n,[[v description] UTF8String]);}
 }@catch(NSException *e){fprintf(stderr,"B31_QUERY_EXCEPTION %s\n",e.description.UTF8String);}fprintf(stderr,"B31_QUERY_DONE pid=%d\n",getpid());fflush(stderr);}}
__attribute__((constructor)) static void start(void){if(!getenv("VPHONE_B31_SCENE_QUERY"))return;fprintf(stderr,"B31_QUERY_LOADED pid=%d\n",getpid());@autoreleasepool{for(NSString *n in @[@"AccessibilityUtilities",@"FrontBoardServices",@"SpringBoardServices"]){NSString *p=[NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@",n,n];dlopen(p.UTF8String,RTLD_NOW);}dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{query();});}}
