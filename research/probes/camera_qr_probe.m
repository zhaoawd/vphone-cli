// Manual rig2 acceptance probe. Does not launch apps or open decoded URLs.
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>

@interface VPhoneQRProbe : NSObject <AVCaptureMetadataOutputObjectsDelegate>
@property(nonatomic, copy) NSString *expected;
@property(nonatomic) NSUInteger callbacks;
@property(nonatomic) BOOL matched;
@end

@implementation VPhoneQRProbe
- (void)captureOutput:(AVCaptureOutput *)output
    didOutputMetadataObjects:(NSArray *)objects
              fromConnection:(AVCaptureConnection *)connection {
    (void)output;
    (void)connection;
    self.callbacks++;
    for (AVMetadataObject *object in objects) {
        if (![object isKindOfClass:AVMetadataMachineReadableCodeObject.class]) continue;
        NSString *value = ((AVMetadataMachineReadableCodeObject *)object).stringValue;
        printf("DECODED=%s\n", value.UTF8String ?: "");
        self.matched |= [value isEqualToString:self.expected];
    }
    fflush(stdout);
}
@end

static int decodeFile(NSString *path, NSString *expected) {
    CGImageSourceRef source = CGImageSourceCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!source) return 2;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) return 2;
    // Check the graphics prerequisite separately from QR recognition.
    CVPixelBufferRef buffer = NULL;
    NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    CVReturn status = CVPixelBufferCreate(NULL, 64, 64, kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attrs, &buffer);
    printf("IOSURFACE_STATUS=%d\n", status);
    if (buffer) CVPixelBufferRelease(buffer);
    CIDetector *detector = [CIDetector detectorOfType:CIDetectorTypeQRCode
        context:nil options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
    BOOL matched = NO;
    for (CIQRCodeFeature *feature in [detector featuresInImage:[CIImage imageWithCGImage:image]]) {
        printf("DECODED=%s\n", feature.messageString.UTF8String ?: "");
        matched |= [feature.messageString isEqualToString:expected];
    }
    CGImageRelease(image);
    return matched && status == kCVReturnSuccess ? 0 : 1;
}

static int decodeMetadata(NSString *expected) {
    void *shim = dlopen("/var/jb/Library/MobileSubstrate/DynamicLibraries/libcamfix.dylib", RTLD_NOW);
    if (!shim) { fprintf(stderr, "DLOPEN=%s\n", dlerror()); return 2; }
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    printf("DEVICE=%s\n", device.uniqueID.UTF8String ?: "none");
    if (![device.uniqueID isEqualToString:@"vphone:vcam:0"]) return 2;
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input) { fprintf(stderr, "INPUT=%s\n", error.description.UTF8String); return 2; }
    AVCaptureSession *session = [AVCaptureSession new];
    AVCaptureMetadataOutput *output = [AVCaptureMetadataOutput new];
    VPhoneQRProbe *probe = [VPhoneQRProbe new];
    probe.expected = expected;
    [session beginConfiguration];
    if (![session canAddInput:input]) return 2;
    [session addInput:input];
    if (![session canAddOutput:output]) return 2;
    [session addOutput:output];
    [output setMetadataObjectsDelegate:probe queue:dispatch_get_main_queue()];
    output.metadataObjectTypes = @[AVMetadataObjectTypeQRCode];
    [session commitConfiguration];
    [session startRunning];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:12];
    while (!probe.callbacks && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    // The shim promises at most one callback per metadata configuration.
    if (probe.callbacks)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];
    [output setMetadataObjectsDelegate:nil queue:NULL];
    [session stopRunning];
    printf("CALLBACKS=%lu\n", (unsigned long)probe.callbacks);
    return probe.matched && probe.callbacks == 1 ? 0 : 1;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        @try {
            int status;
            if (argc == 4 && strcmp(argv[1], "file") == 0)
                status = decodeFile(@(argv[2]), @(argv[3]));
            else if (argc == 3 && strcmp(argv[1], "metadata") == 0)
                status = decodeMetadata(@(argv[2]));
            else {
                fprintf(stderr, "usage: camera-qr-probe file IMAGE EXPECTED | metadata EXPECTED\n");
                return 64;
            }
            printf("RESULT=%s\n", status == 0 ? "PASS" : "FAIL");
            return status;
        } @catch (NSException *exception) {
            fprintf(stderr, "EXCEPTION=%s\n", exception.description.UTF8String);
            return 3;
        }
    }
}
