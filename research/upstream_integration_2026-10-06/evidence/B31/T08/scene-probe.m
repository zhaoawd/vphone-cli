#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static void dump(Class cls,BOOL meta){unsigned count=0;Method *methods=class_copyMethodList(meta?object_getClass(cls):cls,&count);for(unsigned i=0;i<count;i++){const char *name=sel_getName(method_getName(methods[i]));fprintf(stderr,"B31_METHOD %s %c %s %s\n",class_getName(cls),meta?'+':'-',name,method_getTypeEncoding(methods[i]));}free(methods);}
__attribute__((constructor)) static void probe(void){if(!getenv("VPHONE_B31_SCENE_PROBE"))return;@autoreleasepool{
 for(NSString *name in @[@"AccessibilityUtilities",@"FrontBoardServices",@"SpringBoardServices"]){NSString *path=[NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@",name,name];void *h=dlopen(path.UTF8String,RTLD_NOW);fprintf(stderr,"B31_FRAMEWORK %s loaded=%d\n",name.UTF8String,h!=NULL);}
 for(NSString *name in @[@"AXSpringBoardServer",@"FBSSystemService",@"FBSScene",@"FBSSceneClientSettings",@"FBSSceneSettings",@"FBSSceneManager",@"FBSceneManager",@"SBSApplicationClient",@"SBSApplicationSceneSpecification",@"SBSApplicationSceneEntity",@"UIApplicationSceneClientSettings"]){Class cls=NSClassFromString(name);fprintf(stderr,"B31_CLASS %s exists=%d\n",name.UTF8String,cls!=Nil);if(cls){dump(cls,NO);dump(cls,YES);}}
 fprintf(stderr,"B31_SCENE_PROBE_DONE pid=%d\n",getpid());fflush(stderr);
}}
