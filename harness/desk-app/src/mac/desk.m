// harness-desk's macOS layer. See desk.h.
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <dispatch/dispatch.h>
#include <string.h>
#include "desk.h"

static NSString *str(const char *s) { return [NSString stringWithUTF8String:s ? s : ""] ?: @""; }
static const char *cstr(NSString *s) { return s ? (s.UTF8String ?: "") : ""; }

@interface HDDesk : NSObject <NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation,
                              WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler>
@property(strong) NSWindow *window;
@property(strong) WKWebView *web;
@property(copy) NSString *userAgent;
@property int canStart, canStop, canAutostart, autostartOn, canProvider;
@property(strong) NSAlert *keyAlert;
@property(strong) NSSecureTextField *keyField;
@end

static HDDesk *desk;

static NSColor *deskBlack(void) { return [NSColor colorWithSRGBRed:7 / 255.0 green:7 / 255.0 blue:13 / 255.0 alpha:1]; }

@implementation HDDesk

// ---- the app ----

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    (void)n;
    [self buildWindow];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    hdesk_on_ready();
}

// Closing the window leaves the app running, with its badge; the Dock icon
// brings the window back.
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app {
    (void)app;
    return NO;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {
    (void)app;
    if (!visible) [self.window makeKeyAndOrderFront:nil];
    return YES;
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    (void)app;
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)n {
    (void)n;
    [self.window saveFrameUsingName:@"harness"];
}

// ---- the menu ----

static NSMenuItem *item(NSMenu *m, NSString *title, SEL action, NSString *key, id target, NSInteger tag) {
    NSMenuItem *i = [m addItemWithTitle:title action:action keyEquivalent:key];
    i.target = target;
    i.tag = tag;
    return i;
}

- (void)buildMenu {
    NSMenu *bar = [NSMenu new];

    NSMenu *app = [[NSMenu alloc] initWithTitle:@"harness"];
    item(app, @"Start harness", @selector(menuAction:), @"", self, HDESK_MENU_START);
    item(app, @"Stop harness", @selector(menuAction:), @"", self, HDESK_MENU_STOP);
    [app addItem:[NSMenuItem separatorItem]];
    item(app, @"Open at login", @selector(menuAction:), @"", self, HDESK_MENU_AUTOSTART);
    item(app, @"Provider and key…", @selector(menuAction:), @"", self, HDESK_MENU_PROVIDER);
    [app addItem:[NSMenuItem separatorItem]];
    item(app, @"Hide harness", @selector(hide:), @"h", nil, 0);
    NSMenuItem *others = item(app, @"Hide Others", @selector(hideOtherApplications:), @"h", nil, 0);
    others.keyEquivalentModifierMask = NSEventModifierFlagOption | NSEventModifierFlagCommand;
    item(app, @"Show All", @selector(unhideAllApplications:), @"", nil, 0);
    [app addItem:[NSMenuItem separatorItem]];
    item(app, @"Quit harness", @selector(terminate:), @"q", nil, 0);
    [bar addItemWithTitle:@"harness" action:nil keyEquivalent:@""].submenu = app;

    // without these, copy and paste don't reach the page's text fields
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    item(edit, @"Undo", @selector(undo:), @"z", nil, 0);
    item(edit, @"Redo", @selector(redo:), @"Z", nil, 0);
    [edit addItem:[NSMenuItem separatorItem]];
    item(edit, @"Cut", @selector(cut:), @"x", nil, 0);
    item(edit, @"Copy", @selector(copy:), @"c", nil, 0);
    item(edit, @"Paste", @selector(paste:), @"v", nil, 0);
    item(edit, @"Select All", @selector(selectAll:), @"a", nil, 0);
    [bar addItemWithTitle:@"Edit" action:nil keyEquivalent:@""].submenu = edit;

    NSMenu *view = [[NSMenu alloc] initWithTitle:@"View"];
    item(view, @"Reload", @selector(menuAction:), @"r", self, HDESK_MENU_RELOAD);
    [bar addItemWithTitle:@"View" action:nil keyEquivalent:@""].submenu = view;

    NSMenu *window = [[NSMenu alloc] initWithTitle:@"Window"];
    item(window, @"Minimize", @selector(performMiniaturize:), @"m", nil, 0);
    item(window, @"Zoom", @selector(performZoom:), @"", nil, 0);
    [window addItem:[NSMenuItem separatorItem]];
    item(window, @"Close", @selector(performClose:), @"w", nil, 0);
    [bar addItemWithTitle:@"Window" action:nil keyEquivalent:@""].submenu = window;
    NSApp.windowsMenu = window;

    NSApp.mainMenu = bar;
}

- (void)menuAction:(NSMenuItem *)sender {
    hdesk_on_menu((int)sender.tag);
}

- (BOOL)validateMenuItem:(NSMenuItem *)i {
    if (i.action != @selector(menuAction:)) return YES;
    switch (i.tag) {
    case HDESK_MENU_START: return self.canStart;
    case HDESK_MENU_STOP: return self.canStop;
    case HDESK_MENU_AUTOSTART:
        i.state = self.autostartOn == 1 ? NSControlStateValueOn : NSControlStateValueOff;
        return self.canAutostart;
    case HDESK_MENU_PROVIDER: return self.canProvider;
    default: return YES;
    }
}

// ---- the window and the web view ----

- (void)buildWindow {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 820)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.title = @"harness";
    w.releasedWhenClosed = NO;
    w.restorable = NO;
    w.tabbingMode = NSWindowTabbingModeDisallowed;
    w.contentMinSize = NSMakeSize(1024, 700);
    w.backgroundColor = deskBlack();
    w.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    w.delegate = self;
    [w center];
    // a frame saved earlier, when there is one
    [w setFrameAutosaveName:@"harness"];
    self.window = w;

    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    // nothing reusable reaches disk: cookies and storage live in memory
    cfg.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    // media and speech without a click
    cfg.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    cfg.applicationNameForUserAgent = self.userAgent;
    [cfg.userContentController addScriptMessageHandler:self name:@"harness"];

    WKWebView *web = [[WKWebView alloc] initWithFrame:w.contentView.bounds configuration:cfg];
    web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    web.navigationDelegate = self;
    web.UIDelegate = self;
    web.underPageBackgroundColor = deskBlack();
    web.allowsBackForwardNavigationGestures = NO;
    w.contentView = web;
    self.web = web;
}

// ---- navigation ----

static int frameOf(WKFrameInfo *f) {
    if (f == nil) return HDESK_FRAME_NEW_WINDOW;
    return f.isMainFrame ? HDESK_FRAME_MAIN : HDESK_FRAME_SUB;
}

// Whether the person clicked a link: a link activated with a mouse button.
// A script's own click() has no button, and a script setting location or
// calling window.open activates no link.
static int clicked(WKNavigationAction *a) {
    return a.navigationType == WKNavigationTypeLinkActivated && a.buttonNumber != 0;
}

- (void)webView:(WKWebView *)wv
    decidePolicyForNavigationAction:(WKNavigationAction *)a
                    decisionHandler:(void (^)(WKNavigationActionPolicy))h {
    int frame = frameOf(a.targetFrame);
    int d = hdesk_on_navigate_from(cstr(a.request.URL.absoluteString), frame, clicked(a));
    if (frame == HDESK_FRAME_NEW_WINDOW) {
        // never a second window: the desk's own pages load in this one
        if (d == HDESK_ALLOW) [wv loadRequest:a.request];
        h(WKNavigationActionPolicyCancel);
        return;
    }
    h(d == HDESK_ALLOW ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}

// window.open: the same decision, and no new web view
- (WKWebView *)webView:(WKWebView *)wv
    createWebViewWithConfiguration:(WKWebViewConfiguration *)cfg
               forNavigationAction:(WKNavigationAction *)a
                    windowFeatures:(WKWindowFeatures *)features {
    (void)cfg;
    (void)features;
    if (hdesk_on_navigate_from(cstr(a.request.URL.absoluteString), HDESK_FRAME_NEW_WINDOW, clicked(a)) == HDESK_ALLOW) [wv loadRequest:a.request];
    return nil;
}

- (void)webView:(WKWebView *)wv
    decidePolicyForNavigationResponse:(WKNavigationResponse *)r
                      decisionHandler:(void (^)(WKNavigationResponsePolicy))h {
    (void)wv;
    int status = 0;
    if ([r.response isKindOfClass:[NSHTTPURLResponse class]]) status = (int)((NSHTTPURLResponse *)r.response).statusCode;
    hdesk_on_response(cstr(r.response.URL.absoluteString), status, r.isForMainFrame);
    // nothing is downloaded
    h(r.canShowMIMEType ? WKNavigationResponsePolicyAllow : WKNavigationResponsePolicyCancel);
}

- (void)webView:(WKWebView *)wv didFinishNavigation:(WKNavigation *)n {
    (void)n;
    hdesk_on_finish(cstr(wv.URL.absoluteString));
}

static void failed(WKWebView *wv, NSError *e) {
    // a navigation stopped on purpose (by policy, or by the next one) isn't a failure
    if ([e.domain isEqualToString:NSURLErrorDomain] && e.code == NSURLErrorCancelled) return;
    if ([e.domain isEqualToString:@"WebKitErrorDomain"] && e.code == 102) return;
    NSString *url = e.userInfo[NSURLErrorFailingURLStringErrorKey] ?: wv.URL.absoluteString;
    hdesk_on_failed(cstr(url), (int)e.code);
}

- (void)webView:(WKWebView *)wv didFailProvisionalNavigation:(WKNavigation *)n withError:(NSError *)e {
    (void)n;
    failed(wv, e);
}

- (void)webView:(WKWebView *)wv didFailNavigation:(WKNavigation *)n withError:(NSError *)e {
    (void)n;
    failed(wv, e);
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)wv {
    (void)wv;
    hdesk_on_crashed();
}

// ---- the bridge ----

- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)m {
    (void)ucc;
    NSString *json = nil;
    if ([m.body isKindOfClass:[NSString class]]) {
        json = m.body;
    } else if ([NSJSONSerialization isValidJSONObject:m.body]) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:m.body options:0 error:nil];
        if (d) json = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    }
    if (!json) return;
    WKSecurityOrigin *o = m.frameInfo.securityOrigin;
    hdesk_on_message(cstr(json), m.frameInfo.isMainFrame, cstr(o.protocol), cstr(o.host), (int)o.port);
}

// ---- the microphone, files, alert and confirm ----

- (void)webView:(WKWebView *)wv
    requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)origin
                          initiatedByFrame:(WKFrameInfo *)frame
                                      type:(WKMediaCaptureType)type
                           decisionHandler:(void (^)(WKPermissionDecision))h {
    (void)wv;
    int kind = type == WKMediaCaptureTypeMicrophone ? HDESK_MEDIA_MIC
             : type == WKMediaCaptureTypeCamera     ? HDESK_MEDIA_CAMERA
                                                    : HDESK_MEDIA_BOTH;
    int ok = hdesk_on_media(cstr(origin.protocol), cstr(origin.host), (int)origin.port, frame.isMainFrame, kind);
    h(ok ? WKPermissionDecisionGrant : WKPermissionDecisionDeny);
}

- (void)webView:(WKWebView *)wv
    runOpenPanelWithParameters:(WKOpenPanelParameters *)p
              initiatedByFrame:(WKFrameInfo *)f
             completionHandler:(void (^)(NSArray<NSURL *> *))h {
    (void)wv;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    // an app framed in the desk, not the desk itself: said before a file is chosen
    if (!f.isMainFrame) panel.message = @"An app on the desk asks for a file. It can read the file you choose.";
    panel.allowsMultipleSelection = p.allowsMultipleSelection;
    panel.canChooseDirectories = p.allowsDirectories;
    panel.canChooseFiles = YES;
    [panel beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse r) {
                    h(r == NSModalResponseOK ? panel.URLs : nil);
                  }];
}

- (void)webView:(WKWebView *)wv
    runJavaScriptAlertPanelWithMessage:(NSString *)message
                      initiatedByFrame:(WKFrameInfo *)f
                     completionHandler:(void (^)(void))h {
    (void)wv;
    // the desk page's own only, and under a line that says whose words they are
    if (!f.isMainFrame) return h();
    NSAlert *a = [NSAlert new];
    a.messageText = @"Message from the page";
    a.informativeText = message ?: @"";
    [a addButtonWithTitle:@"OK"];
    [a beginSheetModalForWindow:self.window
              completionHandler:^(NSModalResponse r) {
                (void)r;
                h();
              }];
}

- (void)webView:(WKWebView *)wv
    runJavaScriptConfirmPanelWithMessage:(NSString *)message
                        initiatedByFrame:(WKFrameInfo *)f
                       completionHandler:(void (^)(BOOL))h {
    (void)wv;
    if (!f.isMainFrame) return h(NO);
    NSAlert *a = [NSAlert new];
    a.messageText = @"Question from the page";
    a.informativeText = message ?: @"";
    [a addButtonWithTitle:@"OK"];
    [a addButtonWithTitle:@"Cancel"];
    [a beginSheetModalForWindow:self.window
              completionHandler:^(NSModalResponse r) {
                h(r == NSAlertFirstButtonReturn);
              }];
}

@end

// ---- one window a data folder ----

// A port named after the data folder: the first start on a folder holds
// it; a later one asks through it for the window, and ends. (`harness
// open` starts the app anew each time, since a running app is handed no
// arguments: this is what keeps that to one window a folder.)
const char *hdesk_home(void);

static CFDataRef onAsked(CFMessagePortRef port, SInt32 msg, CFDataRef data, void *info) {
    (void)port, (void)msg, (void)data, (void)info;
    if (desk.window) {
        if (desk.window.miniaturized) [desk.window deminiaturize:nil];
        [desk.window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        hdesk_on_reopen();
    }
    pid_t pid = getpid();
    return CFDataCreate(NULL, (const UInt8 *)&pid, sizeof pid);
}

static int firstHere(void) {
    NSString *home = str(hdesk_home());
    if (!home.isAbsolutePath) home = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:home];
    home = home.stringByResolvingSymlinksInPath;
    unsigned long long h = 1469598103934665603ULL;
    for (const unsigned char *p = (const unsigned char *)home.UTF8String; p && *p; p++) h = (h ^ *p) * 1099511628211ULL;
    CFStringRef name = (__bridge CFStringRef)[NSString stringWithFormat:@"io.github.legatia.harness-desk.h%016llx", h];
    for (int i = 0; i < 2; i++) {
        CFMessagePortRef there = CFMessagePortCreateRemote(NULL, name);
        if (there) {
            CFDataRef reply = NULL;
            SInt32 r = CFMessagePortSendRequest(there, 1, NULL, 5, 5, kCFRunLoopDefaultMode, &reply);
            CFRelease(there);
            if (r == kCFMessagePortSuccess) {
                // (its own activation can be refused; this start, which
                // the system just brought forward, hands its turn over)
                if (reply && CFDataGetLength(reply) == sizeof(pid_t)) {
                    pid_t pid;
                    CFDataGetBytes(reply, CFRangeMake(0, sizeof pid), (UInt8 *)&pid);
                    [[NSRunningApplication runningApplicationWithProcessIdentifier:pid] activateWithOptions:0];
                }
                if (reply) CFRelease(reply);
                return 0;
            }
            if (reply) CFRelease(reply);
        }
        // nobody answers on it: this start is the folder's one
        CFMessagePortRef mine = CFMessagePortCreateLocal(NULL, name, onAsked, NULL, NULL);
        if (mine) {
            CFRunLoopSourceRef src = CFMessagePortCreateRunLoopSource(NULL, mine, 0);
            CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
            CFRelease(src);
            return 1;
        }
    }
    // the name is held by something that doesn't answer: a window of its
    // own beats none
    return 1;
}

// ---- the C interface ----

int hdesk_run(const char *user_agent) {
    @autoreleasepool {
        if (!firstHere()) return 0;
        NSApplication *app = [NSApplication sharedApplication];
        desk = [HDDesk new];
        desk.userAgent = str(user_agent);
        desk.autostartOn = -1;
        app.delegate = desk;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [desk buildMenu];
        [app run];
    }
    return 0;
}

void hdesk_quit(void) { [NSApp terminate:nil]; }

void hdesk_show_html(const char *html) { [desk.web loadHTMLString:str(html) baseURL:nil]; }

void hdesk_load(const char *url) {
    NSURL *u = [NSURL URLWithString:str(url)];
    if (u) [desk.web loadRequest:[NSURLRequest requestWithURL:u]];
}

void hdesk_reload(void) { [desk.web reload]; }

void hdesk_eval_js(const char *js) { [desk.web evaluateJavaScript:str(js) completionHandler:nil]; }

void hdesk_badge(const char *label) {
    NSString *s = str(label);
    NSApp.dockTile.badgeLabel = s.length ? s : nil;
}

void hdesk_badge_label(char *buf, int len) {
    if (len <= 0) return;
    strlcpy(buf, cstr(NSApp.dockTile.badgeLabel), (size_t)len);
}

void hdesk_attention(void) { [NSApp requestUserAttention:NSInformationalRequest]; }

void hdesk_open_external(const char *url) {
    NSURL *u = [NSURL URLWithString:str(url)];
    if (u) [[NSWorkspace sharedWorkspace] openURL:u];
}

void hdesk_menu_state(int start, int stop, int autostart_enabled, int autostart_on, int provider) {
    desk.canStart = start;
    desk.canStop = stop;
    desk.canAutostart = autostart_enabled;
    desk.autostartOn = autostart_on;
    desk.canProvider = provider;
}

// ---- the key ----

// The field's text goes to Zig as bytes in a buffer of our own, which is
// zeroed and freed right after; the field is emptied first. (The NSString
// AppKit made from the typing can't be zeroed: it is dropped at once.)
static void keyAnswered(NSModalResponse r) {
    NSSecureTextField *field = desk.keyField;
    desk.keyAlert = nil;
    desk.keyField = nil;
    if (r != NSAlertFirstButtonReturn) {
        field.stringValue = @"";
        hdesk_on_key(NULL, -1);
        return;
    }
    NSString *s = field.stringValue;
    field.stringValue = @"";
    NSUInteger cap = [s maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1;
    char *buf = calloc(cap, 1);
    if (!buf) {
        hdesk_on_key(NULL, -1);
        return;
    }
    NSUInteger used = 0;
    [s getBytes:buf maxLength:cap - 1 usedLength:&used encoding:NSUTF8StringEncoding options:0 range:NSMakeRange(0, s.length) remainingRange:NULL];
    s = nil;
    hdesk_on_key(buf, (int)used);
    memset_s(buf, cap, 0, cap);
    free(buf);
}

void hdesk_ask_key(const char *title, const char *note) {
    if (desk.keyAlert) return;
    NSAlert *a = [NSAlert new];
    a.messageText = str(title);
    [a addButtonWithTitle:@"Save"];
    [a addButtonWithTitle:@"Cancel"];
    // the field, and under it where the key goes
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 50)];
    NSSecureTextField *f = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 26, 300, 24)];
    f.usesSingleLineMode = YES;
    f.accessibilityLabel = str(title);
    NSTextField *n = [NSTextField labelWithString:str(note)];
    n.frame = NSMakeRect(0, 0, 300, 18);
    n.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    n.textColor = NSColor.secondaryLabelColor;
    [box addSubview:f];
    [box addSubview:n];
    a.accessoryView = box;
    desk.keyAlert = a;
    desk.keyField = f;
    [desk.window makeKeyAndOrderFront:nil];
    [a beginSheetModalForWindow:desk.window completionHandler:^(NSModalResponse r) { keyAnswered(r); }];
    [a.window makeFirstResponder:f];
}

int hdesk_test_key(int action) {
#ifdef HDESK_TEST_HOOKS
    // a fake key, built into test builds only, typed into the real field
    static NSString *const fake = @"sk-test-not-a-key";
    NSAlert *a = desk.keyAlert;
    if (!a) return 0;
    int secure = [desk.keyField isKindOfClass:[NSSecureTextField class]] ? 1 : 0;
    if (action == 1) desk.keyField.stringValue = fake;
    [desk.window endSheet:a.window returnCode:action == 1 ? NSAlertFirstButtonReturn : NSAlertSecondButtonReturn];
    return secure;
#else
    (void)action;
    return -1;
#endif
}

void hdesk_test_click(const char *element) {
#ifdef HDESK_TEST_HOOKS
    // where the element is, then a mouse press and release there: an event
    // from the system's side, as a person's click is
    NSString *js = [NSString stringWithFormat:@"(function(){var e=document.getElementById('%@');if(!e)return null;"
                                              @"e.scrollIntoView({block:'center'});var r=e.getBoundingClientRect();"
                                              @"return [r.left+r.width/2,r.top+r.height/2];})()", str(element)];
    [desk.web evaluateJavaScript:js
               completionHandler:^(id v, NSError *e) {
                 (void)e;
                 if (![v isKindOfClass:[NSArray class]] || [v count] != 2) return;
                 WKWebView *web = desk.web;
                 double x = [v[0] doubleValue], y = [v[1] doubleValue];
                 if (!web.isFlipped) y = web.bounds.size.height - y;
                 NSPoint at = [web convertPoint:NSMakePoint(x, y) toView:nil];
                 for (int up = 0; up < 2; up++) {
                     NSEvent *ev = [NSEvent mouseEventWithType:up ? NSEventTypeLeftMouseUp : NSEventTypeLeftMouseDown
                                                      location:at
                                                 modifierFlags:0
                                                     timestamp:NSProcessInfo.processInfo.systemUptime
                                                  windowNumber:desk.window.windowNumber
                                                       context:nil
                                                   eventNumber:0
                                                    clickCount:1
                                                      pressure:up ? 0 : 1];
                     if (up) [web mouseUp:ev]; else [web mouseDown:ev];
                 }
               }];
#else
    (void)element;
#endif
}

void hdesk_alert(const char *title, const char *text) {
    NSAlert *a = [NSAlert new];
    a.messageText = str(title);
    a.informativeText = str(text);
    [a addButtonWithTitle:@"OK"];
    [desk.window makeKeyAndOrderFront:nil];
    [a beginSheetModalForWindow:desk.window completionHandler:nil];
}

void hdesk_post_main(void (*fn)(void *), void *arg) { dispatch_async_f(dispatch_get_main_queue(), arg, fn); }

void hdesk_every(double seconds, void (*fn)(void *), void *arg) {
    NSTimer *t = [NSTimer timerWithTimeInterval:seconds
                                        repeats:YES
                                          block:^(NSTimer *timer) {
                                            (void)timer;
                                            fn(arg);
                                          }];
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
}

void hdesk_window_frame(double *x, double *y, double *w, double *h) {
    NSRect f = desk.window.frame;
    *x = f.origin.x;
    *y = f.origin.y;
    *w = f.size.width;
    *h = f.size.height;
}

void hdesk_set_window_frame(double x, double y, double w, double h) {
    [desk.window setFrame:NSMakeRect(x, y, w, h) display:YES];
    [desk.window saveFrameUsingName:@"harness"];
}

void hdesk_screen_frame(double *x, double *y, double *w, double *h) {
    NSScreen *screen = desk.window.screen ?: [NSScreen mainScreen];
    NSRect f = screen.visibleFrame;
    *x = f.origin.x;
    *y = f.origin.y;
    *w = f.size.width;
    *h = f.size.height;
}

void hdesk_min_frame(double *w, double *h) {
    NSRect content = NSMakeRect(0, 0, desk.window.contentMinSize.width, desk.window.contentMinSize.height);
    NSRect f = [desk.window frameRectForContentRect:content];
    *w = f.size.width;
    *h = f.size.height;
}
