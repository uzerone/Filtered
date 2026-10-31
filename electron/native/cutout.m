#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
int main(int argc, const char *argv[]) { @autoreleasepool {
  if (argc == 2 && strcmp(argv[1], "--fonts") == 0) {
    NSArray *fonts = [[NSFontManager.sharedFontManager availableFontFamilies] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSData *json = [NSJSONSerialization dataWithJSONObject:fonts options:0 error:nil];
    fwrite(json.bytes, 1, json.length, stdout);
    return 0;
  }
  if (argc != 3) return 1;
  if (@available(macOS 14.0, *)) {
    NSURL *input = [NSURL fileURLWithPath:@(argv[1])];
    CIImage *image = [CIImage imageWithContentsOfURL:input];
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCIImage:image options:@{}];
    VNGenerateForegroundInstanceMaskRequest *request = [VNGenerateForegroundInstanceMaskRequest new];
    NSError *error = nil;
    if (![handler performRequests:@[request] error:&error]) { fprintf(stderr,"%s",error.localizedDescription.UTF8String);return 2; }
    VNInstanceMaskObservation *result = request.results.firstObject;
    if (!result || result.allInstances.count == 0) { fprintf(stderr,"No subject found."); return 3; }
    CVPixelBufferRef buffer = [result generateMaskedImageOfInstances:result.allInstances fromRequestHandler:handler croppedToInstancesExtent:NO error:&error];
    if (!buffer) { fprintf(stderr,"%s",error.localizedDescription.UTF8String);return 4; }
    CIImage *masked = [CIImage imageWithCVPixelBuffer:buffer];
    CIContext *context = [CIContext context]; CGColorSpaceRef colors = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    BOOL ok = [context writePNGRepresentationOfImage:masked toURL:[NSURL fileURLWithPath:@(argv[2])] format:kCIFormatRGBA8 colorSpace:colors options:@{} error:&error];
    CGColorSpaceRelease(colors); CVPixelBufferRelease(buffer);
    if (!ok) { fprintf(stderr,"%s",error.localizedDescription.UTF8String);return 5; } return 0;
  } else { fprintf(stderr,"Subject cutout requires macOS 14 or newer."); return 6; }
} }
