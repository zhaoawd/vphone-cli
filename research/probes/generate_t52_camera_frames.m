// Generate deterministic host-side QR/neutral inputs for camera acceptance.
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

static BOOL writeFrame(NSString *path, NSString *payload) {
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(NULL, 640, 640, 8, 640 * 4, color,
        (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(color);
    if (!bitmap) return NO;
    CGFloat gray = payload ? 1.0 : .5;
    CGContextSetRGBFillColor(bitmap, gray, gray, gray, 1);
    CGContextFillRect(bitmap, CGRectMake(0, 0, 640, 640));
    if (payload) {
        CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
        [filter setValue:[payload dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
        [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
        CIImage *output = filter.outputImage;
        CIContext *context = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}];
        CGImageRef image = [context createCGImage:output fromRect:output.extent];
        if (!image) { CGContextRelease(bitmap); return NO; }
        CGFloat size = floor(540 / output.extent.size.width) * output.extent.size.width;
        CGContextSetInterpolationQuality(bitmap, kCGInterpolationNone);
        CGContextDrawImage(bitmap, CGRectMake((640 - size) / 2, (640 - size) / 2, size, size), image);
        CGImageRelease(image);
    }
    CGImageRef image = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    if (!destination) { CGImageRelease(image); return NO; }
    CGImageDestinationAddImage(destination, image, NULL);
    BOOL success = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    return success;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 4) return 64;
        NSString *directory = @(argv[1]);
        if ([[NSFileManager defaultManager] fileExistsAtPath:directory]) return 65;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:nil]) return 66;
        BOOL written = writeFrame([directory stringByAppendingPathComponent:@"a.png"], @(argv[2])) &&
               writeFrame([directory stringByAppendingPathComponent:@"neutral.png"], nil) &&
               writeFrame([directory stringByAppendingPathComponent:@"b.png"], @(argv[3]));
        if (!written) { NSLog(@"Could not render all acceptance frames"); return 1; }
        CIDetector *detector = [CIDetector detectorOfType:CIDetectorTypeQRCode context:nil
            options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
        NSArray *names = @[@"a.png", @"neutral.png", @"b.png"];
        NSArray *expected = @[@(argv[2]), @"", @(argv[3])];
        for (NSUInteger i = 0; i < names.count; i++) {
            CIImage *image = [CIImage imageWithContentsOfURL:[NSURL fileURLWithPath:
                [directory stringByAppendingPathComponent:names[i]]]];
            NSArray *features = [detector featuresInImage:image];
            if (i == 1 ? features.count != 0 :
                (features.count != 1 || ![[features.firstObject messageString] isEqual:expected[i]])) {
                NSLog(@"QR input verification failed for %@", names[i]); return 2;
            }
        }
        return 0;
    }
}
