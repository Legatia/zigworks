// headsound's Apple layer. See audio.h.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <SoundAnalysis/SoundAnalysis.h>
#import <Speech/Speech.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <stdatomic.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "audio.h"

void hsnd_free(void *p) { free(p); }

// ---- decoding ----

static void fourcc(UInt32 id, char *codec, int len) {
    const char *name = NULL;
    switch (id) {
    case kAudioFormatLinearPCM: name = "pcm"; break;
    case kAudioFormatMPEG4AAC: case kAudioFormatMPEG4AAC_HE: case kAudioFormatMPEG4AAC_HE_V2: name = "aac"; break;
    case kAudioFormatAppleLossless: name = "alac"; break;
    case kAudioFormatMPEGLayer3: name = "mp3"; break;
    case kAudioFormatFLAC: name = "flac"; break;
    case kAudioFormatOpus: name = "opus"; break;
    default: break;
    }
    if (name) { strlcpy(codec, name, (size_t)len); return; }
    char s[5] = { (char)(id >> 24), (char)(id >> 16), (char)(id >> 8), (char)id, 0 };
    for (int i = 0; i < 4; i++) if (s[i] < 32 || s[i] > 126) s[i] = '?';
    strlcpy(codec, s, (size_t)len);
}

int hsnd_decode(const char *path, float **out, long long *frames, int *rate, int *channels, char *codec, int codec_len) {
    *out = NULL;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    if (!url) return HSND_FAIL;
    ExtAudioFileRef f = NULL;
    OSStatus st = ExtAudioFileOpenURL(url, &f);
    CFRelease(url);
    if (st != noErr || !f) return HSND_UNSUPPORTED;

    AudioStreamBasicDescription in = {0};
    UInt32 sz = sizeof in;
    SInt64 est = 0;
    UInt32 esz = sizeof est;
    if (ExtAudioFileGetProperty(f, kExtAudioFileProperty_FileDataFormat, &sz, &in) != noErr || in.mChannelsPerFrame == 0 || in.mSampleRate <= 0) {
        ExtAudioFileDispose(f);
        return HSND_UNSUPPORTED;
    }
    ExtAudioFileGetProperty(f, kExtAudioFileProperty_FileLengthFrames, &esz, &est);
    fourcc(in.mFormatID, codec, codec_len);
    const UInt32 ch = in.mChannelsPerFrame;
    AudioStreamBasicDescription client = {
        .mSampleRate = in.mSampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 4 * ch,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = 4 * ch,
        .mChannelsPerFrame = ch,
        .mBitsPerChannel = 32,
    };
    if (ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, sizeof client, &client) != noErr) {
        ExtAudioFileDispose(f);
        return HSND_UNSUPPORTED;
    }
    // The length is an estimate for some codecs: grow as needed.
    size_t cap = (size_t)(est > 0 ? est : in.mSampleRate * 60) + 8192;
    float *buf = malloc(cap * ch * sizeof(float));
    if (!buf) { ExtAudioFileDispose(f); return HSND_FAIL; }
    size_t have = 0;
    for (;;) {
        if (cap - have < 8192) {
            cap *= 2;
            float *nb = realloc(buf, cap * ch * sizeof(float));
            if (!nb) { free(buf); ExtAudioFileDispose(f); return HSND_FAIL; }
            buf = nb;
        }
        UInt32 n = 8192;
        AudioBufferList bl = { .mNumberBuffers = 1 };
        bl.mBuffers[0].mNumberChannels = ch;
        bl.mBuffers[0].mDataByteSize = n * 4 * ch;
        bl.mBuffers[0].mData = buf + have * ch;
        if (ExtAudioFileRead(f, &n, &bl) != noErr) { free(buf); ExtAudioFileDispose(f); return HSND_FAIL; }
        if (n == 0) break;
        have += n;
    }
    ExtAudioFileDispose(f);
    *out = buf;
    *frames = (long long)have;
    *rate = (int)(in.mSampleRate + 0.5);
    *channels = (int)ch;
    return HSND_OK;
}

// ---- host app and permission ----

static NSString *host_bundle_path(void) {
    pid_t pid = getppid();
    for (int i = 0; i < 64 && pid > 1; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pid, path, sizeof path) > 0) {
            char *p = strstr(path, ".app/"); // outermost bundle: helpers live inside their app
            if (p) return [[NSString alloc] initWithBytes:path length:(NSUInteger)(p - path + 4) encoding:NSUTF8StringEncoding];
        }
        // sysctl, like ps: proc_pidinfo is refused for other users' processes
        // (the root-owned `login` between Terminal and the shell).
        struct kinfo_proc kp;
        size_t len = sizeof kp;
        int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
        if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0 || len == 0) break;
        pid = kp.kp_eproc.e_ppid;
    }
    return nil;
}

int hsnd_host_app(char *buf, int len) {
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

int hsnd_mic_access(void) {
    @autoreleasepool {
        if (!host_bundle_path()) return HSND_NO_HOST;
        AVAuthorizationStatus st = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        if (st == AVAuthorizationStatusAuthorized) return HSND_OK;
        if (st != AVAuthorizationStatusNotDetermined) return HSND_PERMISSION;
        __block BOOL ok = NO;
        dispatch_semaphore_t s = dispatch_semaphore_create(0);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL g) { ok = g; dispatch_semaphore_signal(s); }];
        if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC)) != 0) return HSND_UNANSWERED;
        return ok ? HSND_OK : HSND_PERMISSION;
    }
}

// ---- microphone ----

typedef struct {
    hsnd_sink sink;
    void *ctx;
    atomic_int stop;
} Listener;

static void on_input(void *ud, AudioQueueRef q, AudioQueueBufferRef b, const AudioTimeStamp *t, UInt32 n,
                     const AudioStreamPacketDescription *d) {
    (void)t; (void)n; (void)d;
    Listener *l = ud;
    if (atomic_load(&l->stop)) return;
    if (b->mAudioDataByteSize > 0 && l->sink(l->ctx, b->mAudioData, (int)(b->mAudioDataByteSize / 4)))
        atomic_store(&l->stop, 1);
    if (!atomic_load(&l->stop)) AudioQueueEnqueueBuffer(q, b, 0, NULL);
}

int hsnd_listen(double rate, hsnd_sink sink, void *ctx, int max_ms) {
    AudioStreamBasicDescription fmt = {
        .mSampleRate = rate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 4,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = 4,
        .mChannelsPerFrame = 1,
        .mBitsPerChannel = 32,
    };
    Listener l = { .sink = sink, .ctx = ctx };
    atomic_init(&l.stop, 0);
    AudioQueueRef q = NULL;
    // NULL run loop: callbacks come on the queue's own thread.
    if (AudioQueueNewInput(&fmt, on_input, &l, NULL, NULL, 0, &q) != noErr || !q) return HSND_NO_INPUT;
    const UInt32 bytes = (UInt32)(rate / 10) * 4;
    for (int i = 0; i < 4; i++) {
        AudioQueueBufferRef b = NULL;
        if (AudioQueueAllocateBuffer(q, bytes, &b) != noErr || AudioQueueEnqueueBuffer(q, b, 0, NULL) != noErr) {
            AudioQueueDispose(q, true);
            return HSND_FAIL;
        }
    }
    if (AudioQueueStart(q, NULL) != noErr) {
        AudioQueueDispose(q, true);
        return HSND_NO_INPUT;
    }
    for (int waited = 0; !atomic_load(&l.stop) && waited < max_ms; waited += 10) usleep(10000);
    atomic_store(&l.stop, 1);
    AudioQueueStop(q, true);
    AudioQueueDispose(q, true);
    return HSND_OK;
}

// ---- sound classification ----

@interface HSObserver : NSObject <SNResultsObserving>
@property hsnd_class_sink sink;
@property void *ctx;
@property double floor;
@property dispatch_semaphore_t done;
@property BOOL failed;
@end

@implementation HSObserver
- (void)request:(id<SNRequest>)request didProduceResult:(id<SNResult>)result {
    (void)request;
    if (![result isKindOfClass:[SNClassificationResult class]]) return;
    SNClassificationResult *r = (SNClassificationResult *)result;
    double start = CMTimeGetSeconds(r.timeRange.start);
    double dur = CMTimeGetSeconds(r.timeRange.duration);
    for (SNClassification *c in r.classifications) {
        if (c.confidence < self.floor) continue;
        self.sink(self.ctx, start, dur, c.identifier.UTF8String, c.confidence);
    }
}
- (void)request:(id<SNRequest>)request didFailWithError:(NSError *)error {
    (void)request; (void)error;
    self.failed = YES;
    dispatch_semaphore_signal(self.done);
}
- (void)requestDidComplete:(id<SNRequest>)request {
    (void)request;
    dispatch_semaphore_signal(self.done);
}
@end

static SNClassifySoundRequest *new_request(void) {
    NSError *err = nil;
    SNClassifySoundRequest *req = [[SNClassifySoundRequest alloc] initWithClassifierIdentifier:SNClassifierIdentifierVersion1 error:&err];
    return err ? nil : req;
}

int hsnd_classify(const float *samples, long long frames, double rate, double window_s, double floor, hsnd_class_sink sink, void *ctx) {
    @autoreleasepool {
        SNClassifySoundRequest *req = new_request();
        if (!req) return HSND_FAIL;
        // the window length nearest to the one asked for that the classifier takes
        SNTimeDurationConstraint *dc = req.windowDurationConstraint;
        CMTime want = CMTimeMakeWithSeconds(window_s, 1000);
        if (dc.type == SNTimeDurationConstraintTypeRange) {
            CMTimeRange r = dc.durationRange;
            if (CMTimeCompare(want, r.start) < 0) want = r.start;
            if (CMTimeCompare(want, CMTimeRangeGetEnd(r)) > 0) want = CMTimeRangeGetEnd(r);
        } else {
            double best = INFINITY;
            CMTime pick = req.windowDuration;
            for (NSValue *v in dc.enumeratedDurations) {
                double d = fabs(CMTimeGetSeconds(v.CMTimeValue) - window_s);
                if (d < best) { best = d; pick = v.CMTimeValue; }
            }
            want = pick;
        }
        req.windowDuration = want;
        req.overlapFactor = 0.5;
        AVAudioFormat *fmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:rate channels:1 interleaved:NO];
        SNAudioStreamAnalyzer *an = [[SNAudioStreamAnalyzer alloc] initWithFormat:fmt];
        HSObserver *obs = [HSObserver new];
        obs.sink = sink;
        obs.ctx = ctx;
        obs.floor = floor;
        obs.done = dispatch_semaphore_create(0);
        NSError *err = nil;
        if (![an addRequest:req withObserver:obs error:&err]) return HSND_FAIL;
        const AVAudioFrameCount chunk = 8192;
        AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:chunk];
        for (long long pos = 0; pos < frames; pos += chunk) {
            AVAudioFrameCount n = (AVAudioFrameCount)((frames - pos) < chunk ? (frames - pos) : chunk);
            memcpy(buf.floatChannelData[0], samples + pos, n * sizeof(float));
            buf.frameLength = n;
            [an analyzeAudioBuffer:buf atAudioFramePosition:pos];
        }
        [an completeAnalysis];
        // No timeout: the observer calls back into the caller's frame, so
        // returning before the analyzer is done would leave it dangling.
        dispatch_semaphore_wait(obs.done, DISPATCH_TIME_FOREVER);
        return obs.failed ? HSND_FAIL : HSND_OK;
    }
}

int hsnd_class_names(void (*sink)(void *ctx, const char *label), void *ctx) {
    @autoreleasepool {
        SNClassifySoundRequest *req = new_request();
        if (!req) return HSND_FAIL;
        for (NSString *s in req.knownClassifications) sink(ctx, s.UTF8String);
        return HSND_OK;
    }
}

// ---- speech to text ----

// A command-line tool has no app bundle; Speech looks for the reason it
// shows in the permission prompt in the executable's embedded Info.plist.
__attribute__((used, section("__TEXT,__info_plist"))) static const char info_plist[] =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
    "<plist version=\"1.0\"><dict>\n"
    "<key>CFBundleName</key><string>headsound</string>\n"
    "<key>NSMicrophoneUsageDescription</key><string>headsound records what you say when you run headsound listen.</string>\n"
    "<key>NSSpeechRecognitionUsageDescription</key><string>headsound turns recordings into text on this Mac when you run headsound transcribe.</string>\n"
    "</dict></plist>\n";

int hsnd_speech_access(void) {
    @autoreleasepool {
        if (!host_bundle_path()) return HSND_NO_HOST;
        SFSpeechRecognizerAuthorizationStatus st = [SFSpeechRecognizer authorizationStatus];
        if (st == SFSpeechRecognizerAuthorizationStatusAuthorized) return HSND_OK;
        if (st != SFSpeechRecognizerAuthorizationStatusNotDetermined) return HSND_PERMISSION;
        __block SFSpeechRecognizerAuthorizationStatus got = st;
        dispatch_semaphore_t s = dispatch_semaphore_create(0);
        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus g) { got = g; dispatch_semaphore_signal(s); }];
        if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC)) != 0) return HSND_UNANSWERED;
        return got == SFSpeechRecognizerAuthorizationStatusAuthorized ? HSND_OK : HSND_PERMISSION;
    }
}

int hsnd_transcribe(const float *samples, long long frames, double rate, const char *locale, char *used, int used_len,
                    hsnd_word_sink sink, void *ctx) {
    @autoreleasepool {
        SFSpeechRecognizer *r = (locale && *locale)
            ? [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@(locale)]]
            : [[SFSpeechRecognizer alloc] init];
        if (used_len > 0) strlcpy(used, r ? r.locale.localeIdentifier.UTF8String : (locale ? locale : ""), (size_t)used_len);
        if (!r || !r.supportsOnDeviceRecognition) return HSND_UNSUPPORTED;
        // results arrive on this queue, not the main one this thread blocks
        r.queue = [[NSOperationQueue alloc] init];
        SFSpeechAudioBufferRecognitionRequest *req = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
        req.requiresOnDeviceRecognition = YES;
        req.shouldReportPartialResults = NO;
        req.addsPunctuation = YES;
        req.taskHint = SFSpeechRecognitionTaskHintDictation;
        AVAudioFormat *fmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:rate channels:1 interleaved:NO];
        const AVAudioFrameCount chunk = 16384;
        for (long long pos = 0; pos < frames; pos += chunk) {
            AVAudioFrameCount n = (AVAudioFrameCount)((frames - pos) < chunk ? (frames - pos) : chunk);
            AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:n];
            memcpy(buf.floatChannelData[0], samples + pos, n * sizeof(float));
            buf.frameLength = n;
            [req appendAudioPCMBuffer:buf];
        }
        [req endAudio];
        // Only objects the block keeps alive are written after a timeout.
        __block SFSpeechRecognitionResult *final = nil;
        __block NSError *error = nil;
        __block atomic_int finished = 0;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        SFSpeechRecognitionTask *task = [r recognitionTaskWithRequest:req resultHandler:^(SFSpeechRecognitionResult *res, NSError *e) {
            if (atomic_load(&finished)) return;
            if (res.isFinal) final = res;
            else if (e) error = e;
            else return;
            atomic_store(&finished, 1);
            dispatch_semaphore_signal(done);
        }];
        double limit = 60 + 4 * (double)frames / rate;
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(limit * NSEC_PER_SEC))) != 0) {
            atomic_store(&finished, 1);
            [task cancel];
            return HSND_FAIL;
        }
        if (!final) {
            BOOL assistant = [error.domain isEqualToString:@"kAFAssistantErrorDomain"];
            // "No speech detected" is an answer, not a failure
            if (assistant && error.code == 1110) return HSND_OK;
            // Siri and Dictation turned off, or recognition not allowed
            if (assistant && error.code == 1700) return HSND_PERMISSION;
            return HSND_FAIL;
        }
        SFTranscription *tr = final.bestTranscription;
        NSUInteger prev = 0;
        for (SFTranscriptionSegment *seg in tr.segments) {
            NSRange r = seg.substringRange;
            int space = 0;
            if (r.location > prev && r.location <= tr.formattedString.length) {
                NSString *gap = [tr.formattedString substringWithRange:NSMakeRange(prev, r.location - prev)];
                space = [gap rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound;
            }
            prev = r.location + r.length;
            sink(ctx, seg.substring.UTF8String, seg.timestamp, seg.duration, seg.confidence, space);
        }
        return HSND_OK;
    }
}
