// headsight's Apple layer. See capture.h.
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <Vision/Vision.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "capture.h"

// ---- host app ----

static NSString *host_bundle_path(void) {
    pid_t pid = getppid();
    for (int i = 0; i < 64 && pid > 1; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pid, path, sizeof path) > 0) {
            char *p = strstr(path, ".app/"); // outermost bundle: helpers live inside their app
            if (p) return [[NSString alloc] initWithBytes:path length:(NSUInteger)(p - path + 4) encoding:NSUTF8StringEncoding];
        }
        // sysctl, like ps: proc_pidinfo is refused for processes of other
        // users, such as the root-owned `login` between Terminal and the shell.
        struct kinfo_proc kp;
        size_t len = sizeof kp;
        int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
        if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0 || len == 0) break;
        pid = kp.kp_eproc.e_ppid;
    }
    return nil;
}

int hs_host_app(char *buf, int len) {
    @autoreleasepool {
        NSString *path = host_bundle_path();
        if (!path || len <= 0) return 0;
        NSBundle *b = [NSBundle bundleWithPath:path];
        NSString *name = b.infoDictionary[@"CFBundleDisplayName"] ?: b.infoDictionary[@"CFBundleName"]
                         ?: path.lastPathComponent.stringByDeletingPathExtension;
        strlcpy(buf, name.UTF8String, (size_t)len);
        return 1;
    }
}

// ---- permissions ----

int hs_screen_access(int request) {
    if (CGPreflightScreenCaptureAccess()) return 1;
    if (request) CGRequestScreenCaptureAccess();
    return 0;
}

int hs_screen_locked(void) {
    CFDictionaryRef d = CGSessionCopyCurrentDictionary();
    if (!d) return 0;
    CFBooleanRef v = CFDictionaryGetValue(d, CFSTR("CGSSessionScreenIsLocked"));
    int locked = v && CFGetTypeID(v) == CFBooleanGetTypeID() && CFBooleanGetValue(v);
    CFRelease(d);
    return locked;
}

int hs_camera_access(void) {
    @autoreleasepool {
        // No check of the host's NSCameraUsageDescription: Terminal has none,
        // and the camera still works for tools started from it.
        if (!host_bundle_path()) return HS_NO_HOST;
        AVAuthorizationStatus st = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        if (st == AVAuthorizationStatusAuthorized) return HS_OK;
        if (st != AVAuthorizationStatusNotDetermined) return HS_PERMISSION;
        __block BOOL ok = NO;
        dispatch_semaphore_t s = dispatch_semaphore_create(0);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL g) { ok = g; dispatch_semaphore_signal(s); }];
        if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC)) != 0) return HS_PERMISSION;
        return ok ? HS_OK : HS_PERMISSION;
    }
}

// ---- shareable content ----

static SCShareableContent *shareable(int *err) {
    __block SCShareableContent *content = nil;
    __block NSError *e = nil;
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES
                                                 completionHandler:^(SCShareableContent *c, NSError *er) {
        content = c; e = er; dispatch_semaphore_signal(s);
    }];
    dispatch_semaphore_wait(s, DISPATCH_TIME_FOREVER);
    if (!content) {
        if (err) *err = (e && e.code == SCStreamErrorUserDeclined) ? HS_PERMISSION : HS_FAIL;
        if (e) fprintf(stderr, "headsight: %s\n", e.localizedDescription.UTF8String);
        return nil;
    }
    return content;
}

static SCContentFilter *filter_for(const hs_source *src, int *err) {
    SCShareableContent *content = shareable(err);
    if (!content) return nil;
    if (src->kind == 1) {
        for (SCWindow *w in content.windows)
            if (w.windowID == src->window_id) return [[SCContentFilter alloc] initWithDesktopIndependentWindow:w];
        if (err) *err = HS_NOT_FOUND;
        return nil;
    }
    CGDirectDisplayID main_id = CGMainDisplayID();
    SCDisplay *display = content.displays.firstObject;
    for (SCDisplay *d in content.displays) if (d.displayID == main_id) display = d;
    if (!display) { if (err) *err = HS_FAIL; return nil; }
    return [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
}

static SCStreamConfiguration *config_for(SCContentFilter *f) {
    SCStreamConfiguration *cfg = [SCStreamConfiguration new];
    CGFloat scale = f.pointPixelScale;
    cfg.width = (size_t)llround(f.contentRect.size.width * scale);
    cfg.height = (size_t)llround(f.contentRect.size.height * scale);
    cfg.pixelFormat = kCVPixelFormatType_32BGRA;
    cfg.showsCursor = NO;
    cfg.ignoreShadowsSingleWindow = YES;
    return cfg;
}

int hs_windows(hs_window_cb cb, void *ctx) {
    @autoreleasepool {
        int err = HS_OK;
        SCShareableContent *content = shareable(&err);
        if (!content) return err;
        NSMutableDictionary<NSNumber *, SCWindow *> *byId = [NSMutableDictionary dictionary];
        for (SCWindow *w in content.windows) byId[@(w.windowID)] = w;
        CGFloat scale = 1;
        for (SCDisplay *d in content.displays)
            if (d.displayID == CGMainDisplayID()) {
                SCContentFilter *f = [[SCContentFilter alloc] initWithDisplay:d excludingWindows:@[]];
                scale = f.pointPixelScale;
            }
        // CoreGraphics lists windows front to back; ScreenCaptureKit has the details.
        CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
        NSArray *infos = CFBridgingRelease(list);
        for (NSDictionary *info in infos) {
            // normal, floating and panel windows; not the Dock, menu bar or status items
            int layer = [info[(id)kCGWindowLayer] intValue];
            if (layer < 0 || layer >= kCGDockWindowLevel) continue;
            SCWindow *w = byId[info[(id)kCGWindowNumber]];
            if (!w || w.frame.size.width < 2 || w.frame.size.height < 2) continue;
            NSString *app = w.owningApplication.applicationName ?: @"";
            NSString *title = w.title ?: @"";
            cb(ctx, w.windowID, app.UTF8String, title.UTF8String, (int)llround(w.frame.origin.x * scale), (int)llround(w.frame.origin.y * scale),
               (int)llround(w.frame.size.width * scale), (int)llround(w.frame.size.height * scale));
        }
        return HS_OK;
    }
}

// ---- one frame ----

static uint8_t *bgra_from_image(CGImageRef img, int *w, int *h, int *stride) {
    size_t W = CGImageGetWidth(img), H = CGImageGetHeight(img), S = W * 4;
    uint8_t *buf = malloc(S * H);
    if (!buf) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, S, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextDrawImage(ctx, CGRectMake(0, 0, W, H), img);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    *w = (int)W; *h = (int)H; *stride = (int)S;
    return buf;
}

int hs_shot(const hs_source *src, uint8_t **px, int *w, int *h, int *stride, double *pixel_scale) {
    @autoreleasepool {
        if (src->kind == 2) return HS_FAIL; // the camera is read through hs_stream
        int err = HS_OK;
        SCContentFilter *f = filter_for(src, &err);
        if (!f) return err;
        SCStreamConfiguration *cfg = config_for(f);
        __block CGImageRef img = NULL;
        __block NSError *e = nil;
        dispatch_semaphore_t s = dispatch_semaphore_create(0);
        [SCScreenshotManager captureImageWithFilter:f configuration:cfg completionHandler:^(CGImageRef i, NSError *er) {
            if (i) img = CGImageRetain(i);
            e = er;
            dispatch_semaphore_signal(s);
        }];
        dispatch_semaphore_wait(s, DISPATCH_TIME_FOREVER);
        if (!img) {
            if (e) fprintf(stderr, "headsight: %s\n", e.localizedDescription.UTF8String);
            return (e && e.code == SCStreamErrorUserDeclined) ? HS_PERMISSION : HS_FAIL;
        }
        *px = bgra_from_image(img, w, h, stride);
        CGImageRelease(img);
        *pixel_scale = f.pointPixelScale;
        return *px ? HS_OK : HS_FAIL;
    }
}

// ---- streams ----

@interface HSSink : NSObject <SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic) hs_frame_cb cb;
@property (nonatomic) void *ctx;
@property (nonatomic, strong) dispatch_semaphore_t done;
@property (nonatomic) float scale;
@property (nonatomic) uint32_t window_id; // 0 unless a window is watched
@end

@implementation HSSink {
    atomic_int _state; // 0 running, 1 stopped by cb, 2 gone
    int _ticks, _offscreen;
}
- (int)state { return atomic_load(&_state); }
- (void)finish:(int)how {
    int expected = 0;
    if (atomic_compare_exchange_strong(&_state, &expected, how)) dispatch_semaphore_signal(self.done);
}
- (void)deliver:(const hs_frame *)f {
    if (atomic_load(&_state) != 0) return;
    if (self.cb(self.ctx, f)) [self finish:1];
}
- (void)deliverPixels:(CVPixelBufferRef)pb {
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    hs_frame f = { CVPixelBufferGetBaseAddress(pb), (int)CVPixelBufferGetWidth(pb), (int)CVPixelBufferGetHeight(pb), (int)CVPixelBufferGetBytesPerRow(pb), self.scale };
    [self deliver:&f];
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
}
// ScreenCaptureKit
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen) return;
    @autoreleasepool {
        CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, false);
        if (!atts || CFArrayGetCount(atts) == 0) return;
        NSDictionary *a = (__bridge NSDictionary *)CFArrayGetValueAtIndex(atts, 0);
        NSNumber *st = a[SCStreamFrameInfoStatus];
        CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
        if (st && st.integerValue == SCFrameStatusComplete && pb) [self deliverPixels:pb];
        else if (st && st.integerValue == SCFrameStatusStopped) [self finish:2]; // e.g. the window was minimised
        else [self deliver:NULL];
    }
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error { [self finish:2]; }
// ScreenCaptureKit sends nothing when a watched window is minimised or its app
// hidden, so every 500 ms the window is looked up. Off screen in two checks in
// a row counts as gone. macOS gives no way to tell a minimised window from one
// on another desktop without Accessibility access; both end the wait.
- (void)tick {
    [self deliver:NULL];
    if (self.window_id == 0 || ++_ticks % 5 != 0) return;
    const void *ids[1] = { (const void *)(uintptr_t)self.window_id };
    CFArrayRef want = CFArrayCreate(NULL, ids, 1, NULL);
    NSArray *infos = CFBridgingRelease(CGWindowListCreateDescriptionFromArray(want));
    CFRelease(want);
    NSDictionary *info = infos.firstObject;
    BOOL on = info && [info[(id)kCGWindowIsOnscreen] boolValue];
    _offscreen = on ? 0 : _offscreen + 1;
    if (_offscreen >= 2) [self finish:2];
}
// AVFoundation
- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)sb fromConnection:(AVCaptureConnection *)c {
    @autoreleasepool {
        CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
        if (pb) [self deliverPixels:pb];
    }
}
- (void)sessionError:(NSNotification *)n { [self finish:2]; }
@end

static NSArray<AVCaptureDevice *> *cameras(AVCaptureDeviceType type) {
    return [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[ type ] mediaType:AVMediaTypeVideo
                                                                    position:AVCaptureDevicePositionUnspecified].devices;
}

static AVCaptureDevice *camera_lookup(const char *name);

static AVCaptureDevice *camera_named(const char *name) {
    // With an iPhone nearby, AVFoundation logs a Continuity Camera deprecation
    // warning on any lookup. It means nothing to the agent reading our
    // output, so stderr is muted for the lookup only.
    fflush(stderr);
    int saved = dup(STDERR_FILENO);
    int devnull = open("/dev/null", O_WRONLY);
    if (saved >= 0 && devnull >= 0) dup2(devnull, STDERR_FILENO);
    AVCaptureDevice *d = camera_lookup(name);
    if (saved >= 0) { dup2(saved, STDERR_FILENO); close(saved); }
    if (devnull >= 0) close(devnull);
    return d;
}

static AVCaptureDevice *camera_lookup(const char *name) {
    // Built-in cameras first, then external ones.
    NSArray<AVCaptureDevice *> *builtin = cameras(AVCaptureDeviceTypeBuiltInWideAngleCamera);
    if (!(name && *name)) return builtin.firstObject ?: cameras(AVCaptureDeviceTypeExternal).firstObject;
    NSString *want = [NSString stringWithUTF8String:name];
    for (NSArray<AVCaptureDevice *> *devs in @[ builtin, cameras(AVCaptureDeviceTypeExternal) ])
        for (AVCaptureDevice *d in devs)
            if ([d.localizedName rangeOfString:want options:NSCaseInsensitiveSearch].location != NSNotFound) return d;
    return nil;
}

// Idle ticks every 100 ms, so "still" and timeouts work even when no frames
// arrive. Created only once capture runs: libdispatch traps when a timer that
// was never resumed is released, as it would be on an early error return.
static dispatch_source_t start_ticks(HSSink *sink, dispatch_queue_t q) {
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), 100 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{ [sink tick]; });
    dispatch_resume(t);
    return t;
}

static int wait_done(HSSink *sink, int timeout_ms) {
    long r = dispatch_semaphore_wait(sink.done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout_ms * NSEC_PER_MSEC));
    if (r != 0) return HS_TIMEOUT;
    return sink.state == 2 ? HS_GONE : HS_OK;
}

int hs_stream(const hs_source *src, int timeout_ms, hs_frame_cb cb, void *ctx) {
    @autoreleasepool {
        HSSink *sink = [HSSink new];
        sink.cb = cb; sink.ctx = ctx; sink.done = dispatch_semaphore_create(0); sink.scale = 1;
        dispatch_queue_t q = dispatch_queue_create("headsight.frames", DISPATCH_QUEUE_SERIAL);
        dispatch_source_t tick;
        int rc;

        if (src->kind == 2) {
            AVCaptureDevice *dev = camera_named(src->camera_name);
            if (!dev) return HS_NOT_FOUND;
            NSError *e = nil;
            AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&e];
            if (!in) { fprintf(stderr, "headsight: %s\n", e.localizedDescription.UTF8String); return HS_FAIL; }
            AVCaptureSession *ses = [AVCaptureSession new];
            [ses beginConfiguration];
            if (![ses canAddInput:in]) return HS_FAIL;
            [ses addInput:in];
            if ([ses canSetSessionPreset:AVCaptureSessionPreset1280x720]) ses.sessionPreset = AVCaptureSessionPreset1280x720;
            AVCaptureVideoDataOutput *out = [AVCaptureVideoDataOutput new];
            // 1280x720 is plenty to see a change; the output scales whatever the camera gives.
            out.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                                  (id)kCVPixelBufferWidthKey: @1280, (id)kCVPixelBufferHeightKey: @720};
            out.alwaysDiscardsLateVideoFrames = YES;
            [out setSampleBufferDelegate:sink queue:q];
            if (![ses canAddOutput:out]) return HS_FAIL;
            [ses addOutput:out];
            [ses commitConfiguration];
            [[NSNotificationCenter defaultCenter] addObserver:sink selector:@selector(sessionError:) name:AVCaptureSessionRuntimeErrorNotification object:ses];
            [ses startRunning];
            tick = start_ticks(sink, q);
            rc = wait_done(sink, timeout_ms);
            [sink finish:1];
            dispatch_source_cancel(tick);
            [ses stopRunning];
            [[NSNotificationCenter defaultCenter] removeObserver:sink];
            dispatch_sync(q, ^{});
            return rc;
        }

        int err = HS_OK;
        SCContentFilter *f = filter_for(src, &err);
        if (!f) return err;
        SCStreamConfiguration *cfg = config_for(f);
        sink.scale = (float)f.pointPixelScale;
        if (src->kind == 1) sink.window_id = src->window_id;
        cfg.minimumFrameInterval = CMTimeMake(1, src->fps > 0 ? src->fps : 30);
        cfg.queueDepth = 5;
        SCStream *st = [[SCStream alloc] initWithFilter:f configuration:cfg delegate:sink];
        NSError *e = nil;
        if (![st addStreamOutput:sink type:SCStreamOutputTypeScreen sampleHandlerQueue:q error:&e]) {
            fprintf(stderr, "headsight: %s\n", e.localizedDescription.UTF8String);
            return HS_FAIL;
        }
        __block NSError *se = nil;
        dispatch_semaphore_t started = dispatch_semaphore_create(0);
        [st startCaptureWithCompletionHandler:^(NSError *er) { se = er; dispatch_semaphore_signal(started); }];
        dispatch_semaphore_wait(started, DISPATCH_TIME_FOREVER);
        if (se) {
            fprintf(stderr, "headsight: %s\n", se.localizedDescription.UTF8String);
            return se.code == SCStreamErrorUserDeclined ? HS_PERMISSION : HS_FAIL;
        }
        tick = start_ticks(sink, q);
        rc = wait_done(sink, timeout_ms);
        [sink finish:1];
        dispatch_source_cancel(tick);
        if (rc != HS_GONE) {
            dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
            [st stopCaptureWithCompletionHandler:^(NSError *er) { dispatch_semaphore_signal(stopped); }];
            dispatch_semaphore_wait(stopped, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        }
        dispatch_sync(q, ^{});
        return rc;
    }
}

// ---- images ----

static CGImageRef image_of(const hs_frame *f, int x, int y, int w, int h) {
    if (x < 0 || y < 0 || w <= 0 || h <= 0 || x + w > f->w || y + h > f->h) return NULL;
    const uint8_t *start = f->px + (size_t)y * (size_t)f->stride + (size_t)x * 4;
    size_t len = (size_t)(h - 1) * (size_t)f->stride + (size_t)w * 4;
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, start, len, NULL);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef img = CGImageCreate((size_t)w, (size_t)h, 8, 32, (size_t)f->stride, cs,
                                   kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little, dp, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(dp);
    return img;
}

int hs_ocr(const hs_frame *f, int x, int y, int w, int h, int accurate, hs_text_cb cb, void *ctx) {
    @autoreleasepool {
        CGImageRef img = image_of(f, x, y, w, h);
        if (!img) return HS_FAIL;
        VNRecognizeTextRequest *req = [VNRecognizeTextRequest new];
        req.recognitionLevel = accurate ? VNRequestTextRecognitionLevelAccurate : VNRequestTextRecognitionLevelFast;
        req.usesLanguageCorrection = accurate ? YES : NO;
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:img options:@{}];
        NSError *e = nil;
        BOOL ok = [handler performRequests:@[ req ] error:&e];
        CGImageRelease(img);
        if (!ok) { fprintf(stderr, "headsight: %s\n", e.localizedDescription.UTF8String); return HS_FAIL; }
        for (VNRecognizedTextObservation *o in req.results) {
            VNRecognizedText *t = [o topCandidates:1].firstObject;
            if (!t) continue;
            CGRect bb = o.boundingBox; // normalised, origin bottom left
            int bx = x + (int)lround(bb.origin.x * w);
            int by = y + (int)lround((1.0 - bb.origin.y - bb.size.height) * h);
            cb(ctx, t.string.UTF8String, t.confidence, bx, by, (int)lround(bb.size.width * w), (int)lround(bb.size.height * h));
        }
        return HS_OK;
    }
}

int hs_write_png(const char *path, const hs_frame *f, int x, int y, int w, int h, int max_side, double *scale_out) {
    @autoreleasepool {
        CGImageRef img = image_of(f, x, y, w, h);
        if (!img) return HS_FAIL;
        double scale = 1.0;
        int longest = w > h ? w : h;
        if (max_side > 0 && longest > max_side) scale = (double)max_side / (double)longest;
        CGImageRef out = img;
        if (scale < 1.0) {
            size_t tw = (size_t)llround(w * scale), th = (size_t)llround(h * scale);
            if (tw < 1) tw = 1;
            if (th < 1) th = 1;
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGContextRef c = CGBitmapContextCreate(NULL, tw, th, 8, 0, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
            CGColorSpaceRelease(cs);
            CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
            CGContextDrawImage(c, CGRectMake(0, 0, tw, th), img);
            out = CGBitmapContextCreateImage(c);
            CGContextRelease(c);
        }
        CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
        CGImageDestinationRef d = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
        CFRelease(url);
        int rc = HS_FAIL;
        if (d) {
            CGImageDestinationAddImage(d, out, NULL);
            if (CGImageDestinationFinalize(d)) rc = HS_OK;
            CFRelease(d);
        }
        if (out != img) CGImageRelease(out);
        CGImageRelease(img);
        if (scale_out) *scale_out = scale;
        return rc;
    }
}

void hs_free(void *p) { free(p); }

uint8_t *hs_test_render_text(int w, int h, const char *text) {
    @autoreleasepool {
        uint8_t *buf = calloc((size_t)w * (size_t)h, 4);
        if (!buf) return NULL;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef c = CGBitmapContextCreate(buf, (size_t)w, (size_t)h, 8, (size_t)w * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGColorSpaceRelease(cs);
        CGContextSetRGBFillColor(c, 1, 1, 1, 1);
        CGContextFillRect(c, CGRectMake(0, 0, w, h));
        CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica"), h / 4.0, NULL);
        NSDictionary *attrs = @{(id)kCTFontAttributeName: (__bridge id)font, (id)kCTForegroundColorFromContextAttributeName: @YES};
        CGContextSetRGBFillColor(c, 0, 0, 0, 1);
        NSAttributedString *as = [[NSAttributedString alloc] initWithString:[NSString stringWithUTF8String:text] attributes:attrs];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
        CGContextSetTextPosition(c, w / 4.0, h / 2.0); // bottom-left origin: text in the right part, middle height
        CTLineDraw(line, c);
        CFRelease(line);
        CFRelease(font);
        CGContextRelease(c);
        return buf;
    }
}
