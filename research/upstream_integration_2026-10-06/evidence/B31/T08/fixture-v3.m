#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <unistd.h>
static NSUInteger mask=UIInterfaceOrientationMaskAll;static unsigned samples=0;static NSString *lastRequest=@"";static NSDictionary *geometryResult;
static NSString *doc(void){return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;}
@interface ProbeVC:UIViewController
@property(nonatomic,strong) UILabel *label;
@end
@implementation ProbeVC
-(UIInterfaceOrientationMask)supportedInterfaceOrientations{return mask;}
-(BOOL)shouldAutorotate{return YES;}
-(void)viewDidLoad{[super viewDidLoad];UIApplication.sharedApplication.idleTimerDisabled=YES;self.view.backgroundColor=UIColor.blackColor;self.label=[UILabel new];self.label.textColor=UIColor.greenColor;self.label.font=[UIFont monospacedSystemFontOfSize:20 weight:UIFontWeightRegular];self.label.numberOfLines=0;self.label.textAlignment=NSTextAlignmentCenter;self.label.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;self.label.frame=self.view.bounds;[self.view addSubview:self.label];[NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t){
 if(samples++>=4800){[t invalidate];return;}NSDictionary *p=[NSDictionary dictionaryWithContentsOfFile:[doc() stringByAppendingPathComponent:@"policy.plist"]];NSUInteger next=p[@"mask"]?[p[@"mask"] unsignedIntegerValue]:UIInterfaceOrientationMaskAll;if(next!=mask&&(next==2||next==26||next==30)){mask=next;[self setNeedsUpdateOfSupportedInterfaceOrientations];}
 UIWindowScene *s=self.view.window.windowScene;
 if(samples==1){NSMutableArray *methods=[NSMutableArray array];for(id target in @[s,self,UIDevice.currentDevice,UIApplication.sharedApplication]){Class c=object_getClass(target);while(c&&c!=NSObject.class){unsigned count=0;Method *list=class_copyMethodList(c,&count);for(unsigned k=0;k<count;k++){NSString *name=NSStringFromSelector(method_getName(list[k]));if([name.lowercaseString containsString:@"orientation"]||[name.lowercaseString containsString:@"scene"]){[methods addObject:@{@"object":NSStringFromClass([target class]),@"declaring_class":NSStringFromClass(c),@"selector":name,@"encoding":@(method_getTypeEncoding(list[k]))}];}}free(list);c=class_getSuperclass(c);}}NSData *m=[NSJSONSerialization dataWithJSONObject:methods options:NSJSONWritingPrettyPrinted error:nil];[m writeToFile:[doc() stringByAppendingPathComponent:@"methods.json"] atomically:YES];}

 NSString *request=p[@"request_id"];if(request&&![request isEqual:lastRequest]){lastRequest=[request copy];NSUInteger requested=[p[@"geometry_mask"] unsignedIntegerValue];geometryResult=@{@"request_id":request,@"requested_mask":@(requested),@"call_time":@([NSDate date].timeIntervalSince1970),@"error":[NSNull null]};[s requestGeometryUpdateWithPreferences:[[UIWindowSceneGeometryPreferencesIOS alloc]initWithInterfaceOrientations:requested] errorHandler:^(NSError *e){geometryResult=@{@"request_id":request,@"requested_mask":@(requested),@"error":@{@"domain":e.domain,@"code":@(e.code),@"description":e.localizedDescription,@"user_info":e.userInfo.description}};}];}
 id client=nil;SEL sceneSel=NSSelectorFromString(@"_scene");if([s respondsToSelector:sceneSel]){id fbs=((id(*)(id,SEL))objc_msgSend)(s,sceneSel);SEL clientSel=NSSelectorFromString(@"clientSettings");if([fbs respondsToSelector:clientSel])client=((id(*)(id,SEL))objc_msgSend)(fbs,clientSel);}
 NSNumber *clientMask=nil;SEL support=NSSelectorFromString(@"supportedInterfaceOrientations");if([client respondsToSelector:support])clientMask=@(((NSUInteger(*)(id,SEL))objc_msgSend)(client,support));
 NSDictionary *row=@{@"time":@([NSDate date].timeIntervalSince1970),@"pid":@(getpid()),@"uid":@(getuid()),@"mask_returned_by_controller":@(self.supportedInterfaceOrientations),@"scene_client_mask":clientMask?:[NSNull null],@"application_mask":@([UIApplication.sharedApplication supportedInterfaceOrientationsForWindow:self.view.window]),@"geometry_request":geometryResult?:[NSNull null],@"scene_orientation":@(s.effectiveGeometry.interfaceOrientation),@"scene_locked":@(s.effectiveGeometry.interfaceOrientationLocked),@"width":@(self.view.bounds.size.width),@"height":@(self.view.bounds.size.height),@"activation_state":@(s.activationState)};
 NSData *data=[NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:nil];NSString *path=[doc() stringByAppendingPathComponent:@"rotation.jsonl"];if(![[NSFileManager defaultManager] fileExistsAtPath:path])[[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];NSFileHandle *h=[NSFileHandle fileHandleForWritingAtPath:path];[h seekToEndOfFile];[h writeData:data];[h writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];[h closeFile];self.label.text=[NSString stringWithFormat:@"↑ TOP\nVPhone B31\nmask=%lu client=%@\norientation=%ld\n%.0f × %.0f\n↓ BOTTOM",(unsigned long)mask,clientMask,(long)s.effectiveGeometry.interfaceOrientation,self.view.bounds.size.width,self.view.bounds.size.height];
 }];}
@end
@interface ProbeScene:NSObject<UIWindowSceneDelegate>
@property(nonatomic,strong)UIWindow *window;
@end
@implementation ProbeScene
-(void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options{self.window=[[UIWindow alloc]initWithWindowScene:(UIWindowScene *)scene];self.window.rootViewController=[ProbeVC new];[self.window makeKeyAndVisible];}
@end
@interface ProbeApp:NSObject<UIApplicationDelegate>
@end
@implementation ProbeApp
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass([ProbeApp class]));}}
