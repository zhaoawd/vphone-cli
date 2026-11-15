#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

@interface ProbeController : UIViewController <WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate, AVCaptureVideoDataOutputSampleBufferDelegate>
@property NSMutableDictionary *report;
@property NSMutableSet *nativeHashes;
@property AVCaptureSession *session;
@property WKWebView *web;
@property UILabel *status;
@property dispatch_queue_t captureQueue;
@property int listener;
@property unsigned short port;
@property UIBackgroundTaskIdentifier backgroundTask;
@end
@implementation ProbeController
- (void)persist {
    NSString *path=[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"report.json"];
    NSData *data=[NSJSONSerialization dataWithJSONObject:self.report options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:path atomically:YES];self.status.text=[NSString stringWithFormat:@"Native: %@ / WK: %@ / Safari: %@",self.report[@"native"][@"frames"]?:@0,self.report[@"wk"][@"phase"]?:@"ready",self.report[@"safari"][@"phase"]?:@"ready"];
}
- (void)record:(NSDictionary *)value {
    if(![value isKindOfClass:NSDictionary.class])return;
    NSString *client=value[@"client"];if(![@[@"wk",@"safari"] containsObject:client])return;
    self.report[client]=value;[self persist];
}
- (void)startServer {
    self.listener=socket(AF_INET,SOCK_STREAM,0);int yes=1;setsockopt(self.listener,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));
    struct sockaddr_in address={.sin_len=sizeof(address),.sin_family=AF_INET,.sin_port=0,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    if(bind(self.listener,(void *)&address,sizeof(address))||listen(self.listener,4)){self.report[@"server_error"]=@"bind/listen failed";return;}
    socklen_t length=sizeof(address);getsockname(self.listener,(void *)&address,&length);self.port=ntohs(address.sin_port);
    NSString *html=[NSString stringWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"index" ofType:@"html"] encoding:NSUTF8StringEncoding error:nil];
    int listener=self.listener;__weak ProbeController *weak=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{while(1){int fd=accept(listener,NULL,NULL);if(fd<0)break;@autoreleasepool{
        struct timeval timeout={.tv_sec=5};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
        NSMutableData *request=[NSMutableData data];unsigned char buffer[4096];NSRange header={NSNotFound,0};NSUInteger bodyLength=0;
        while(request.length<65536){ssize_t n=read(fd,buffer,sizeof(buffer));if(n<=0)break;[request appendBytes:buffer length:n];header=[request rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0,request.length)];if(header.location!=NSNotFound){NSString *text=[[NSString alloc]initWithData:[request subdataWithRange:NSMakeRange(0,header.location)] encoding:NSUTF8StringEncoding];for(NSString *line in [text componentsSeparatedByString:@"\r\n"]){if([line.lowercaseString hasPrefix:@"content-length:"])bodyLength=[[line substringFromIndex:15] integerValue];}if(request.length>=header.location+4+bodyLength)break;}}
        BOOL post=request.length>=5&&!memcmp(request.bytes,"POST ",5);NSData *body;
        if(post&&header.location!=NSNotFound&&request.length>=header.location+4+bodyLength){NSDictionary *value=[NSJSONSerialization JSONObjectWithData:[request subdataWithRange:NSMakeRange(header.location+4,bodyLength)] options:0 error:nil];dispatch_async(dispatch_get_main_queue(),^{[weak record:value];});body=[@"ok" dataUsingEncoding:NSUTF8StringEncoding];}else body=[html dataUsingEncoding:NSUTF8StringEncoding];
        NSString *headers=[NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",post?@"text/plain":@"text/html",(unsigned long)body.length];NSMutableData *response=[[headers dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];[response appendData:body];size_t sent=0;while(sent<response.length){ssize_t n=write(fd,(const char *)response.bytes+sent,response.length-sent);if(n<=0)break;sent+=n;}close(fd);
    }}});
}
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=UIColor.systemBackgroundColor;self.report=[NSMutableDictionary dictionary];self.nativeHashes=[NSMutableSet set];self.captureQueue=dispatch_queue_create("com.vphone.tests.camera",DISPATCH_QUEUE_SERIAL);self.backgroundTask=UIBackgroundTaskInvalid;
    UIStackView *buttons=[[UIStackView alloc]init];buttons.axis=UILayoutConstraintAxisVertical;buttons.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:buttons];
    NSArray *labels=@[@"Start Native Camera",@"Stop Native Camera",@"Open Web Page",@"Open Safari Page"];
    NSArray *ids=@[@"probe.native.start",@"probe.native.stop",@"probe.web.open",@"probe.safari.open"];
    SEL selectors[]={@selector(startNative),@selector(stopNative),@selector(openWeb),@selector(openSafari)};
    for(NSUInteger i=0;i<labels.count;i++){UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem];[b setTitle:labels[i] forState:UIControlStateNormal];b.accessibilityIdentifier=ids[i];[b addTarget:self action:selectors[i] forControlEvents:UIControlEventTouchUpInside];[buttons addArrangedSubview:b];}
    self.status=[UILabel new];self.status.numberOfLines=0;[buttons addArrangedSubview:self.status];
    WKWebViewConfiguration *configuration=[WKWebViewConfiguration new];configuration.allowsInlineMediaPlayback=YES;configuration.mediaTypesRequiringUserActionForPlayback=WKAudiovisualMediaTypeNone;[configuration.userContentController addScriptMessageHandler:self name:@"report"];
    self.web=[[WKWebView alloc]initWithFrame:CGRectZero configuration:configuration];self.web.UIDelegate=self;self.web.navigationDelegate=self;self.web.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.web];
    [NSLayoutConstraint activateConstraints:@[[buttons.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:48],[buttons.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],[buttons.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],[self.web.topAnchor constraintEqualToAnchor:buttons.bottomAnchor constant:8],[self.web.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.web.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.web.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]]];
    [self startServer];self.report[@"port"]=@(self.port);[self persist];
}
- (void)startNative {
    self.report[@"native"]=@{@"phase":@"requested"};[self persist];
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted){dispatch_async(self.captureQueue,^{@try{
        if(!granted){dispatch_async(dispatch_get_main_queue(),^{self.report[@"native"]=@{@"error":@"camera permission denied"};[self persist];});return;}
        AVCaptureDevice *device=[AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];NSError *error=nil;AVCaptureDeviceInput *input=[AVCaptureDeviceInput deviceInputWithDevice:device error:&error];AVCaptureSession *session=[AVCaptureSession new];AVCaptureVideoDataOutput *output=[AVCaptureVideoDataOutput new];output.videoSettings=@{(NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)};[output setSampleBufferDelegate:self queue:self.captureQueue];
        if(!input||![session canAddInput:input]||![session canAddOutput:output])@throw [NSException exceptionWithName:@"capture" reason:error.description?:@"capture graph admission failed" userInfo:nil];
        [session addInput:input];[session addOutput:output];self.session=session;[session startRunning];
    }@catch(NSException *e){dispatch_async(dispatch_get_main_queue(),^{self.report[@"native"]=@{@"error":e.reason?:e.name};[self persist];});}});}];
}
- (void)stopNative { dispatch_async(self.captureQueue,^{[self.session stopRunning];self.session=nil;}); }
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    CVPixelBufferRef pixel=CMSampleBufferGetImageBuffer(sample);if(!pixel)return;CVPixelBufferLockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);const unsigned char *bytes=CVPixelBufferGetBaseAddress(pixel);size_t size=CVPixelBufferGetDataSize(pixel);uint32_t hash=2166136261;for(size_t i=0;bytes&&i<size;i+=MAX((size_t)1,size/4096))hash=(hash^bytes[i])*16777619;NSUInteger width=CVPixelBufferGetWidth(pixel),height=CVPixelBufferGetHeight(pixel);CVPixelBufferUnlockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);
    dispatch_async(dispatch_get_main_queue(),^{[self.nativeHashes addObject:@(hash)];NSUInteger count=[self.report[@"native"][@"frames"] unsignedIntegerValue]+1;self.report[@"native"]=@{@"frames":@(count),@"unique":@(self.nativeHashes.count),@"width":@(width),@"height":@(height),@"hashes":self.nativeHashes.allObjects};[self persist];});
}
- (void)openWeb { [self stopNative];[self.web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%hu/?client=wk",self.port]]]]; }
- (void)openSafari {
    [self stopNative];[self.web evaluateJavaScript:@"window.stopCapture?.()" completionHandler:nil];
    if(self.backgroundTask==UIBackgroundTaskInvalid)self.backgroundTask=[UIApplication.sharedApplication beginBackgroundTaskWithName:@"camera-regression" expirationHandler:^{[UIApplication.sharedApplication endBackgroundTask:self.backgroundTask];self.backgroundTask=UIBackgroundTaskInvalid;}];
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%hu/?client=safari",self.port]] options:@{} completionHandler:nil];
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message { [self record:message.body]; }
- (void)webView:(WKWebView *)web requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)origin initiatedByFrame:(WKFrameInfo *)frame type:(WKMediaCaptureType)type decisionHandler:(void (^)(WKPermissionDecision))decisionHandler { decisionHandler([origin.host isEqualToString:@"127.0.0.1"]&&type==WKMediaCaptureTypeCamera?WKPermissionDecisionGrant:WKPermissionDecisionDeny); }
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)web { self.report[@"wk"]=@{@"phase":@"terminated"};[self persist]; }
@end
@interface ProbeScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation ProbeScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window=[[UIWindow alloc]initWithWindowScene:(UIWindowScene *)scene];self.window.rootViewController=[ProbeController new];[self.window makeKeyAndVisible];
}
- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
    NSString *command=contexts.anyObject.URL.host;ProbeController *probe=(ProbeController *)self.window.rootViewController;
    if([command isEqualToString:@"native"])[probe startNative];
    else if([command isEqualToString:@"stop"])[probe stopNative];
    else if([command isEqualToString:@"wk"])[probe openWeb];
    else if([command isEqualToString:@"safari"])[probe openSafari];
}
@end
@interface ProbeApp : UIResponder <UIApplicationDelegate>
@end
@implementation ProbeApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options { return YES; }
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(ProbeApp.class));}}
