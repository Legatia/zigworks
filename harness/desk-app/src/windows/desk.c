// harness-desk's Windows layer: the window, its menu, and WebView2 with its
// handlers, through the C interfaces of Microsoft's WebView2.h. The loader
// (WebView2Loader.dll, beside the program) is loaded at run time. Every
// decision is made in Zig (main.zig): this file asks through the hdesk_on_*
// callbacks and does what it's told. See ../mac/desk.h for the interface;
// everything here runs on the main thread, except hdesk_post_main.
#define COBJMACROS
#define INITGUID
#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "WebView2.h"
#include "../mac/desk.h"

// The data folder, from Zig.
const char *hdesk_home(void);

// shobjidl.h's, for the taskbar's overlay (WebView2.h defines its own ids).
DEFINE_GUID(HD_CLSID_TaskbarList, 0x56fdf344, 0xfd6d, 0x11d0, 0x95, 0x8a, 0x00, 0x60, 0x97, 0xc9, 0xa0, 0x90);
DEFINE_GUID(HD_IID_ITaskbarList3, 0xea1afb91, 0x9e28, 0x4b86, 0x90, 0xe9, 0x9e, 0x9f, 0x8a, 0x5e, 0xef, 0xaf);

enum { WM_HD_CALL = WM_APP + 1, WM_HD_ALERT = WM_APP + 2 };
enum { ID_START = 1001, ID_STOP, ID_AUTOSTART, ID_RELOAD, ID_QUIT, ID_PROVIDER };
enum { MIN_W = 1024, MIN_H = 700, START_W = 1280, START_H = 820 };

static HWND hwnd;
// the key window, while it is open
static struct {
    HWND win, edit;
    HFONT font, bold;
} keybox;
static HMENU menu_bar;
static ICoreWebView2Environment *env;
static ICoreWebView2Controller *ctl;
static ICoreWebView2 *web;
static ITaskbarList3 *taskbar;
static HICON dot_icon;
static wchar_t user_agent[160];
static char badge[32];
static int exit_code;
// the next navigation is one of the app's own pages (hdesk_show_html)
static int html_pending;
static UINT64 html_nav;
static int have_html_nav;
// where the main frame's navigation is headed, for a failure's line
static char nav_url[2048];

struct every { void (*fn)(void *); void *arg; };
static struct every timers[8];
static UINT_PTR timer_count;

// ---- strings ----

static wchar_t *wide(const char *s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s ? s : "", -1, NULL, 0);
    wchar_t *w = (wchar_t *)malloc(sizeof(wchar_t) * (size_t)(n > 0 ? n : 1));
    if (!w) return NULL;
    if (n <= 0 || !MultiByteToWideChar(CP_UTF8, 0, s ? s : "", -1, w, n)) w[0] = 0;
    return w;
}

static char *utf8(const wchar_t *w) {
    int n = WideCharToMultiByte(CP_UTF8, 0, w ? w : L"", -1, NULL, 0, NULL, NULL);
    char *s = (char *)malloc((size_t)(n > 0 ? n : 1));
    if (!s) return NULL;
    if (n <= 0 || !WideCharToMultiByte(CP_UTF8, 0, w ? w : L"", -1, s, n, NULL, NULL)) s[0] = 0;
    return s;
}

// "http", "127.0.0.1" and the port of an address (0: the scheme's own); a
// page that is not on the web ("about:blank", "data:…") has only a scheme.
static void origin_of(const char *url, char *proto, size_t plen, char *host, size_t hlen, int *port) {
    proto[0] = host[0] = 0;
    *port = 0;
    const char *colon = strchr(url, ':');
    if (!colon) return;
    size_t n = (size_t)(colon - url);
    if (n >= plen) n = plen - 1;
    memcpy(proto, url, n);
    proto[n] = 0;
    if (strncmp(colon, "://", 3) != 0) return;
    const char *auth = colon + 3;
    size_t end = strcspn(auth, "/?#");
    // (an address with a user part is not harness's: its host is kept whole,
    // so it matches nothing)
    const char *pc = NULL;
    for (size_t i = 0; i < end; i++) if (auth[i] == ':') pc = auth + i;
    size_t hn = pc ? (size_t)(pc - auth) : end;
    if (memchr(auth, '@', end)) { hn = end; pc = NULL; }
    if (hn >= hlen) hn = hlen - 1;
    memcpy(host, auth, hn);
    host[hn] = 0;
    if (pc) *port = atoi(pc + 1);
}

// ---- the window's frame, kept between starts ----

static void frame_path(wchar_t *out, size_t len) {
    wchar_t *home = wide(hdesk_home());
    _snwprintf(out, len, L"%ls\\desk-webview\\window-frame", home ? home : L".");
    out[len - 1] = 0;
    free(home);
}

static void save_frame(void) {
    if (!hwnd || IsIconic(hwnd) || IsZoomed(hwnd)) return;
    RECT r;
    if (!GetWindowRect(hwnd, &r)) return;
    wchar_t path[MAX_PATH * 2];
    frame_path(path, sizeof path / sizeof path[0]);
    FILE *f = _wfopen(path, L"w");
    if (!f) return;
    fprintf(f, "%ld %ld %ld %ld\n", r.left, r.top, r.right - r.left, r.bottom - r.top);
    fclose(f);
}

static int load_frame(RECT *r) {
    wchar_t path[MAX_PATH * 2];
    frame_path(path, sizeof path / sizeof path[0]);
    FILE *f = _wfopen(path, L"r");
    if (!f) return 0;
    long x, y, w, h;
    int n = fscanf(f, "%ld %ld %ld %ld", &x, &y, &w, &h);
    fclose(f);
    if (n != 4 || w < 200 || h < 200) return 0;
    r->left = x;
    r->top = y;
    r->right = x + w;
    r->bottom = y + h;
    // only where a screen still is
    return MonitorFromRect(r, MONITOR_DEFAULTTONULL) != NULL;
}

static UINT dpi(void) {
    HMODULE u = GetModuleHandleW(L"user32.dll");
    UINT(WINAPI * for_window)(HWND) = (UINT(WINAPI *)(HWND))(void *)GetProcAddress(u, "GetDpiForWindow");
    if (for_window && hwnd) {
        UINT d = for_window(hwnd);
        if (d) return d;
    }
    HDC dc = GetDC(NULL);
    UINT d = (UINT)GetDeviceCaps(dc, LOGPIXELSX);
    ReleaseDC(NULL, dc);
    return d ? d : 96;
}

// The window's size for a client area of w by h at 96 dots an inch.
static SIZE outer(int w, int h) {
    UINT d = dpi();
    RECT r = { 0, 0, MulDiv(w, (int)d, 96), MulDiv(h, (int)d, 96) };
    AdjustWindowRectEx(&r, WS_OVERLAPPEDWINDOW, TRUE, 0);
    SIZE s = { r.right - r.left, r.bottom - r.top };
    return s;
}

// ---- the badge: the count in the title, a dot on the taskbar's icon ----

static HICON make_dot(void) {
    enum { N = 16 };
    BITMAPV5HEADER bi;
    memset(&bi, 0, sizeof bi);
    bi.bV5Size = sizeof bi;
    bi.bV5Width = N;
    bi.bV5Height = -N;
    bi.bV5Planes = 1;
    bi.bV5BitCount = 32;
    bi.bV5Compression = BI_BITFIELDS;
    bi.bV5RedMask = 0x00FF0000;
    bi.bV5GreenMask = 0x0000FF00;
    bi.bV5BlueMask = 0x000000FF;
    bi.bV5AlphaMask = 0xFF000000;
    DWORD *px = NULL;
    HDC dc = GetDC(NULL);
    HBITMAP color = CreateDIBSection(dc, (BITMAPINFO *)&bi, DIB_RGB_COLORS, (void **)&px, NULL, 0);
    ReleaseDC(NULL, dc);
    if (!color || !px) return NULL;
    for (int y = 0; y < N; y++) {
        for (int x = 0; x < N; x++) {
            double dx = x + 0.5 - N / 2.0, dy = y + 0.5 - N / 2.0;
            px[y * N + x] = dx * dx + dy * dy <= 6.5 * 6.5 ? 0xFFE5484D : 0;
        }
    }
    HBITMAP mask = CreateBitmap(N, N, 1, 1, NULL);
    ICONINFO ii;
    memset(&ii, 0, sizeof ii);
    ii.fIcon = TRUE;
    ii.hbmColor = color;
    ii.hbmMask = mask;
    HICON icon = CreateIconIndirect(&ii);
    DeleteObject(color);
    DeleteObject(mask);
    return icon;
}

void hdesk_badge(const char *label) {
    strncpy(badge, label ? label : "", sizeof badge - 1);
    badge[sizeof badge - 1] = 0;
    wchar_t title[64];
    if (badge[0]) _snwprintf(title, 64, L"harness (%hs)", badge); else wcscpy(title, L"harness");
    title[63] = 0;
    SetWindowTextW(hwnd, title);
    if (taskbar) {
        if (!dot_icon) dot_icon = make_dot();
        ITaskbarList3_SetOverlayIcon(taskbar, hwnd, badge[0] ? dot_icon : NULL, badge[0] ? L"Items need you" : NULL);
    }
}

void hdesk_badge_label(char *buf, int len) {
    if (len <= 0) return;
    // as the title has it: "harness (3)"
    wchar_t title[64];
    title[0] = 0;
    GetWindowTextW(hwnd, title, 64);
    const wchar_t *open = wcschr(title, L'(');
    int n = 0;
    if (open) for (open++; *open && *open != L')' && n < len - 1; open++) buf[n++] = (char)*open;
    buf[n] = 0;
}

void hdesk_attention(void) {
    FLASHWINFO f;
    memset(&f, 0, sizeof f);
    f.cbSize = sizeof f;
    f.hwnd = hwnd;
    f.dwFlags = FLASHW_TRAY;
    f.uCount = 3;
    FlashWindowEx(&f);
}

// ---- the menu ----

static void build_menu(void) {
    menu_bar = CreateMenu();
    HMENU app = CreatePopupMenu();
    AppendMenuW(app, MF_STRING | MF_GRAYED, ID_START, L"&Start harness");
    AppendMenuW(app, MF_STRING | MF_GRAYED, ID_STOP, L"S&top harness");
    AppendMenuW(app, MF_SEPARATOR, 0, NULL);
    AppendMenuW(app, MF_STRING | MF_GRAYED, ID_AUTOSTART, L"&Open at login");
    AppendMenuW(app, MF_STRING | MF_GRAYED, ID_PROVIDER, L"&Provider and key\x2026");
    AppendMenuW(app, MF_SEPARATOR, 0, NULL);
    AppendMenuW(app, MF_STRING, ID_QUIT, L"&Quit harness\tCtrl+Q");
    AppendMenuW(menu_bar, MF_POPUP, (UINT_PTR)app, L"&harness");
    HMENU view = CreatePopupMenu();
    AppendMenuW(view, MF_STRING, ID_RELOAD, L"&Reload\tCtrl+R");
    AppendMenuW(menu_bar, MF_POPUP, (UINT_PTR)view, L"&View");
}

void hdesk_menu_state(int start, int stop, int autostart_enabled, int autostart_on, int provider) {
    EnableMenuItem(menu_bar, ID_PROVIDER, MF_BYCOMMAND | (provider ? MF_ENABLED : MF_GRAYED));
    EnableMenuItem(menu_bar, ID_START, MF_BYCOMMAND | (start ? MF_ENABLED : MF_GRAYED));
    EnableMenuItem(menu_bar, ID_STOP, MF_BYCOMMAND | (stop ? MF_ENABLED : MF_GRAYED));
    EnableMenuItem(menu_bar, ID_AUTOSTART, MF_BYCOMMAND | (autostart_enabled ? MF_ENABLED : MF_GRAYED));
    CheckMenuItem(menu_bar, ID_AUTOSTART, MF_BYCOMMAND | (autostart_on == 1 ? MF_CHECKED : MF_UNCHECKED));
    DrawMenuBar(hwnd);
}

// ---- WebView2's handlers ----
//
// Each is one object for the program's life: a table of four functions and
// the id it answers to. They are never freed, so the counts are not kept.

typedef struct handler {
    void *vtbl;
    const IID *iid;
} handler;

static HRESULT STDMETHODCALLTYPE h_query(void *self, REFIID riid, void **out) {
    handler *h = (handler *)self;
    if (!out) return E_POINTER;
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, h->iid)) {
        *out = self;
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE h_addref(void *self) { (void)self; return 2; }
static ULONG STDMETHODCALLTYPE h_release(void *self) { (void)self; return 1; }

// A handler `name` whose Invoke is `fn`, answering to `IID_<iface>`.
#define HANDLER(name, iface, fn) \
    static void *name##_vtbl[4] = { (void *)h_query, (void *)h_addref, (void *)h_release, (void *)fn }; \
    static handler name = { name##_vtbl, &IID_##iface }

static void free_co(wchar_t *w) { if (w) CoTaskMemFree(w); }

static HRESULT STDMETHODCALLTYPE on_nav_starting(void *self, ICoreWebView2 *sender, ICoreWebView2NavigationStartingEventArgs *args) {
    (void)self;
    (void)sender;
    wchar_t *wuri = NULL;
    UINT64 id = 0;
    ICoreWebView2NavigationStartingEventArgs_get_Uri(args, &wuri);
    ICoreWebView2NavigationStartingEventArgs_get_NavigationId(args, &id);
    char *uri = utf8(wuri);
    free_co(wuri);
    if (!uri) return S_OK;
    // the app's own page: not a place a page could send the window to
    if (html_pending && (strncmp(uri, "about:blank", 11) == 0 || strncmp(uri, "data:text/html", 14) == 0)) {
        html_pending = 0;
        html_nav = id;
        have_html_nav = 1;
        free(uri);
        return S_OK;
    }
    // (a person's click on a link, as WebView2 tells it: a script's click(),
    // its location = and the app's own loads are not "user initiated")
    BOOL user = FALSE;
    ICoreWebView2NavigationStartingEventArgs_get_IsUserInitiated(args, &user);
    int d = hdesk_on_navigate_from(uri, HDESK_FRAME_MAIN, user ? 1 : 0);
    if (d != HDESK_ALLOW) ICoreWebView2NavigationStartingEventArgs_put_Cancel(args, TRUE);
    else {
        strncpy(nav_url, uri, sizeof nav_url - 1);
        nav_url[sizeof nav_url - 1] = 0;
    }
    free(uri);
    return S_OK;
}
HANDLER(nav_starting, ICoreWebView2NavigationStartingEventHandler, on_nav_starting);

static HRESULT STDMETHODCALLTYPE on_frame_nav_starting(void *self, ICoreWebView2 *sender, ICoreWebView2NavigationStartingEventArgs *args) {
    (void)self;
    (void)sender;
    wchar_t *wuri = NULL;
    ICoreWebView2NavigationStartingEventArgs_get_Uri(args, &wuri);
    char *uri = utf8(wuri);
    free_co(wuri);
    if (!uri) return S_OK;
    BOOL user = FALSE;
    ICoreWebView2NavigationStartingEventArgs_get_IsUserInitiated(args, &user);
    if (hdesk_on_navigate_from(uri, HDESK_FRAME_SUB, user ? 1 : 0) != HDESK_ALLOW) ICoreWebView2NavigationStartingEventArgs_put_Cancel(args, TRUE);
    free(uri);
    return S_OK;
}
HANDLER(frame_nav_starting, ICoreWebView2NavigationStartingEventHandler, on_frame_nav_starting);

// A new window is never made: the desk's own pages load in this one.
static HRESULT STDMETHODCALLTYPE on_new_window(void *self, ICoreWebView2 *sender, ICoreWebView2NewWindowRequestedEventArgs *args) {
    (void)self;
    wchar_t *wuri = NULL;
    ICoreWebView2NewWindowRequestedEventArgs_get_Uri(args, &wuri);
    ICoreWebView2NewWindowRequestedEventArgs_put_Handled(args, TRUE);
    BOOL user = FALSE;
    ICoreWebView2NewWindowRequestedEventArgs_get_IsUserInitiated(args, &user);
    char *uri = utf8(wuri);
    if (uri && hdesk_on_navigate_from(uri, HDESK_FRAME_NEW_WINDOW, user ? 1 : 0) == HDESK_ALLOW) ICoreWebView2_Navigate(sender, wuri);
    free(uri);
    free_co(wuri);
    return S_OK;
}
HANDLER(new_window, ICoreWebView2NewWindowRequestedEventHandler, on_new_window);

static HRESULT STDMETHODCALLTYPE on_nav_completed(void *self, ICoreWebView2 *sender, ICoreWebView2NavigationCompletedEventArgs *args) {
    (void)self;
    UINT64 id = 0;
    BOOL ok = FALSE;
    COREWEBVIEW2_WEB_ERROR_STATUS err = COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
    int status = 0;
    ICoreWebView2NavigationCompletedEventArgs_get_NavigationId(args, &id);
    ICoreWebView2NavigationCompletedEventArgs_get_IsSuccess(args, &ok);
    ICoreWebView2NavigationCompletedEventArgs_get_WebErrorStatus(args, &err);
    ICoreWebView2NavigationCompletedEventArgs2 *args2 = NULL;
    if (SUCCEEDED(ICoreWebView2NavigationCompletedEventArgs_QueryInterface(args, &IID_ICoreWebView2NavigationCompletedEventArgs2, (void **)&args2)) && args2) {
        ICoreWebView2NavigationCompletedEventArgs2_get_HttpStatusCode(args2, &status);
        ICoreWebView2NavigationCompletedEventArgs2_Release(args2);
    }
    if (have_html_nav && id == html_nav) {
        have_html_nav = 0;
        hdesk_on_finish("about:blank");
        return S_OK;
    }
    // stopped on purpose, by the policy or by the next navigation: not a failure
    if (!ok && status == 0 && err == COREWEBVIEW2_WEB_ERROR_STATUS_OPERATION_CANCELED) return S_OK;
    wchar_t *wsrc = NULL;
    ICoreWebView2_get_Source(sender, &wsrc);
    char *src = utf8(wsrc);
    free_co(wsrc);
    if (status > 0 || ok) {
        // (a page the server answered with 403 is a page too: the answer, then its end)
        if (status > 0) hdesk_on_response(src ? src : "", status, 1);
        hdesk_on_finish(src ? src : "");
    } else {
        hdesk_on_failed(nav_url, (int)err);
    }
    free(src);
    return S_OK;
}
HANDLER(nav_completed, ICoreWebView2NavigationCompletedEventHandler, on_nav_completed);

// A message's text: the JSON of what the page posted, or the text itself
// when it posted text. NULL when there is none.
static char *message_json(ICoreWebView2WebMessageReceivedEventArgs *args) {
    wchar_t *w = NULL;
    if (FAILED(ICoreWebView2WebMessageReceivedEventArgs_TryGetWebMessageAsString(args, &w)) || !w) {
        w = NULL;
        if (FAILED(ICoreWebView2WebMessageReceivedEventArgs_get_WebMessageAsJson(args, &w)) || !w) return NULL;
    }
    char *s = utf8(w);
    free_co(w);
    return s;
}

static void deliver_message(ICoreWebView2WebMessageReceivedEventArgs *args, int main_frame) {
    char *json = message_json(args);
    if (!json) return;
    wchar_t *wsrc = NULL;
    ICoreWebView2WebMessageReceivedEventArgs_get_Source(args, &wsrc);
    char *src = utf8(wsrc);
    // the main frame's own page: its address is the window's. A frame's
    // message that reaches the window's handler has the frame's address.
    if (main_frame && web) {
        wchar_t *wtop = NULL;
        ICoreWebView2_get_Source(web, &wtop);
        if (!wsrc || !wtop || wcscmp(wsrc, wtop) != 0) main_frame = 0;
        free_co(wtop);
    }
    free_co(wsrc);
    char proto[16], host[256];
    int port = 0;
    origin_of(src ? src : "", proto, sizeof proto, host, sizeof host, &port);
    hdesk_on_message(json, main_frame, proto, host, port);
    free(src);
    free(json);
}

static HRESULT STDMETHODCALLTYPE on_message(void *self, ICoreWebView2 *sender, ICoreWebView2WebMessageReceivedEventArgs *args) {
    (void)self;
    (void)sender;
    deliver_message(args, 1);
    return S_OK;
}
HANDLER(message, ICoreWebView2WebMessageReceivedEventHandler, on_message);

static HRESULT STDMETHODCALLTYPE on_frame_message(void *self, ICoreWebView2Frame *sender, ICoreWebView2WebMessageReceivedEventArgs *args) {
    (void)self;
    (void)sender;
    deliver_message(args, 0);
    return S_OK;
}
HANDLER(frame_message, ICoreWebView2FrameWebMessageReceivedEventHandler, on_frame_message);

// The microphone for the desk page itself; everything else a page may ask
// for is refused, and nothing is remembered in the profile.
static void decide_permission(ICoreWebView2PermissionRequestedEventArgs *args, int main_frame) {
    COREWEBVIEW2_PERMISSION_KIND kind = COREWEBVIEW2_PERMISSION_KIND_UNKNOWN_PERMISSION;
    wchar_t *wuri = NULL;
    ICoreWebView2PermissionRequestedEventArgs_get_PermissionKind(args, &kind);
    ICoreWebView2PermissionRequestedEventArgs_get_Uri(args, &wuri);
    char *uri = utf8(wuri);
    free_co(wuri);
    int ok = 0;
    if (kind == COREWEBVIEW2_PERMISSION_KIND_MICROPHONE || kind == COREWEBVIEW2_PERMISSION_KIND_CAMERA) {
        char proto[16], host[256];
        int port = 0;
        origin_of(uri ? uri : "", proto, sizeof proto, host, sizeof host, &port);
        ok = hdesk_on_media(proto, host, port, main_frame, kind == COREWEBVIEW2_PERMISSION_KIND_MICROPHONE ? HDESK_MEDIA_MIC : HDESK_MEDIA_CAMERA);
    }
    free(uri);
    ICoreWebView2PermissionRequestedEventArgs_put_State(args, ok ? COREWEBVIEW2_PERMISSION_STATE_ALLOW : COREWEBVIEW2_PERMISSION_STATE_DENY);
    ICoreWebView2PermissionRequestedEventArgs3 *args3 = NULL;
    if (SUCCEEDED(ICoreWebView2PermissionRequestedEventArgs_QueryInterface(args, &IID_ICoreWebView2PermissionRequestedEventArgs3, (void **)&args3)) && args3) {
        ICoreWebView2PermissionRequestedEventArgs3_put_SavesInProfile(args3, FALSE);
        ICoreWebView2PermissionRequestedEventArgs3_Release(args3);
    }
}

// Set when a frame was made whose own messages or requests this runtime
// can't hand to on_frame_message and on_frame_permission (no
// ICoreWebView2Frame2 or Frame3): they would arrive at the window's
// handlers looking like the desk page's. Nobody is given the microphone
// from then on, and the app says the runtime is too old and ends
// (frame_too_old).
static int frames_untold;
static void no_web_view(const wchar_t *why);
static const wchar_t too_old[] = L"is too old for harness here";
static void frame_too_old(void *unused) {
    (void)unused;
    no_web_view(too_old);
}

static HRESULT STDMETHODCALLTYPE on_permission(void *self, ICoreWebView2 *sender, ICoreWebView2PermissionRequestedEventArgs *args) {
    (void)self;
    (void)sender;
    decide_permission(args, frames_untold ? 0 : 1);
    return S_OK;
}
HANDLER(permission, ICoreWebView2PermissionRequestedEventHandler, on_permission);

// A frame's request is answered here, so it never reaches the window's
// handler as if the desk page had asked.
static HRESULT STDMETHODCALLTYPE on_frame_permission(void *self, ICoreWebView2Frame *sender, ICoreWebView2PermissionRequestedEventArgs2 *args) {
    (void)self;
    (void)sender;
    decide_permission((ICoreWebView2PermissionRequestedEventArgs *)args, 0);
    ICoreWebView2PermissionRequestedEventArgs2_put_Handled(args, TRUE);
    return S_OK;
}
HANDLER(frame_permission, ICoreWebView2FramePermissionRequestedEventHandler, on_frame_permission);

static HRESULT STDMETHODCALLTYPE on_frame_created(void *self, ICoreWebView2 *sender, ICoreWebView2FrameCreatedEventArgs *args) {
    (void)self;
    (void)sender;
    ICoreWebView2Frame *frame = NULL;
    if (FAILED(ICoreWebView2FrameCreatedEventArgs_get_Frame(args, &frame)) || !frame) return S_OK;
    EventRegistrationToken tok;
    int untold = 0;
    ICoreWebView2Frame2 *f2 = NULL;
    if (SUCCEEDED(ICoreWebView2Frame_QueryInterface(frame, &IID_ICoreWebView2Frame2, (void **)&f2)) && f2) {
        ICoreWebView2Frame2_add_WebMessageReceived(f2, (ICoreWebView2FrameWebMessageReceivedEventHandler *)&frame_message, &tok);
        ICoreWebView2Frame2_Release(f2);
    } else {
        untold = 1;
    }
    ICoreWebView2Frame3 *f3 = NULL;
    if (SUCCEEDED(ICoreWebView2Frame_QueryInterface(frame, &IID_ICoreWebView2Frame3, (void **)&f3)) && f3) {
        ICoreWebView2Frame3_add_PermissionRequested(f3, (ICoreWebView2FramePermissionRequestedEventHandler *)&frame_permission, &tok);
        ICoreWebView2Frame3_Release(f3);
    } else {
        untold = 1;
    }
    ICoreWebView2Frame_Release(frame);
    // (said from the message loop, once: the box runs a loop of its own)
    if (untold && !frames_untold) {
        frames_untold = 1;
        hdesk_post_main(frame_too_old, NULL);
    }
    return S_OK;
}
HANDLER(frame_created, ICoreWebView2FrameCreatedEventHandler, on_frame_created);

static HRESULT STDMETHODCALLTYPE on_process_failed(void *self, ICoreWebView2 *sender, ICoreWebView2ProcessFailedEventArgs *args) {
    (void)self;
    (void)sender;
    COREWEBVIEW2_PROCESS_FAILED_KIND kind = COREWEBVIEW2_PROCESS_FAILED_KIND_BROWSER_PROCESS_EXITED;
    ICoreWebView2ProcessFailedEventArgs_get_ProcessFailedKind(args, &kind);
    if (kind == COREWEBVIEW2_PROCESS_FAILED_KIND_RENDER_PROCESS_EXITED || kind == COREWEBVIEW2_PROCESS_FAILED_KIND_BROWSER_PROCESS_EXITED) hdesk_on_crashed();
    return S_OK;
}
HANDLER(process_failed, ICoreWebView2ProcessFailedEventHandler, on_process_failed);

// Nothing is downloaded.
static HRESULT STDMETHODCALLTYPE on_download(void *self, ICoreWebView2 *sender, ICoreWebView2DownloadStartingEventArgs *args) {
    (void)self;
    (void)sender;
    ICoreWebView2DownloadStartingEventArgs_put_Cancel(args, TRUE);
    ICoreWebView2DownloadStartingEventArgs_put_Handled(args, TRUE);
    return S_OK;
}
HANDLER(download, ICoreWebView2DownloadStartingEventHandler, on_download);

// The menu's keys, which the page has while it has the keyboard.
static HRESULT STDMETHODCALLTYPE on_key(void *self, ICoreWebView2Controller *sender, ICoreWebView2AcceleratorKeyPressedEventArgs *args) {
    (void)self;
    (void)sender;
    COREWEBVIEW2_KEY_EVENT_KIND kind = COREWEBVIEW2_KEY_EVENT_KIND_KEY_UP;
    UINT key = 0;
    ICoreWebView2AcceleratorKeyPressedEventArgs_get_KeyEventKind(args, &kind);
    ICoreWebView2AcceleratorKeyPressedEventArgs_get_VirtualKey(args, &key);
    if (kind != COREWEBVIEW2_KEY_EVENT_KIND_KEY_DOWN) return S_OK;
    int ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
    if (key == VK_F5 || (ctrl && key == 'R')) {
        ICoreWebView2AcceleratorKeyPressedEventArgs_put_Handled(args, TRUE);
        PostMessageW(hwnd, WM_COMMAND, ID_RELOAD, 0);
    } else if (ctrl && key == 'Q') {
        ICoreWebView2AcceleratorKeyPressedEventArgs_put_Handled(args, TRUE);
        PostMessageW(hwnd, WM_COMMAND, ID_QUIT, 0);
    }
    return S_OK;
}
HANDLER(key, ICoreWebView2AcceleratorKeyPressedEventHandler, on_key);

// ---- a script's alert, confirm and prompt ----
// The desk page's own alert and confirm are shown, in a box of Windows'
// own under a line that says whose words they are. A framed page's are
// dropped: alert returns, confirm answers no. prompt answers nothing for
// either (as on macOS). Leaving a page is never held up by its script.

typedef struct dialog_job {
    ICoreWebView2ScriptDialogOpeningEventArgs *args;
    ICoreWebView2Deferral *deferral;
    wchar_t *text;
    int confirm;
} dialog_job;

// From the message loop, not from inside the event: the box runs a loop of
// its own (hdesk_alert says the same).
static void show_dialog(void *arg) {
    dialog_job *j = (dialog_job *)arg;
    int yes = 1;
#ifndef HDESK_TEST_HOOKS
    yes = MessageBoxW(hwnd, j->text ? j->text : L"", j->confirm ? L"Question from the page" : L"Message from the page",
                      j->confirm ? MB_OKCANCEL | MB_ICONQUESTION : MB_OK | MB_ICONINFORMATION) == IDOK;
#endif
    // (a test build shows no box and answers yes: nobody is there to)
    if (yes) ICoreWebView2ScriptDialogOpeningEventArgs_Accept(j->args);
    ICoreWebView2Deferral_Complete(j->deferral);
    ICoreWebView2Deferral_Release(j->deferral);
    ICoreWebView2ScriptDialogOpeningEventArgs_Release(j->args);
    free_co(j->text);
    free(j);
}

static HRESULT STDMETHODCALLTYPE on_script_dialog(void *self, ICoreWebView2 *sender, ICoreWebView2ScriptDialogOpeningEventArgs *args) {
    (void)self;
    COREWEBVIEW2_SCRIPT_DIALOG_KIND kind = COREWEBVIEW2_SCRIPT_DIALOG_KIND_ALERT;
    ICoreWebView2ScriptDialogOpeningEventArgs_get_Kind(args, &kind);
    if (kind == COREWEBVIEW2_SCRIPT_DIALOG_KIND_BEFOREUNLOAD) {
        ICoreWebView2ScriptDialogOpeningEventArgs_Accept(args);
        return S_OK;
    }
    // the desk page's own: the page that asks is the one the window shows
    wchar_t *wuri = NULL, *wtop = NULL;
    ICoreWebView2ScriptDialogOpeningEventArgs_get_Uri(args, &wuri);
    ICoreWebView2_get_Source(sender, &wtop);
    int desk = wuri && wtop && wcscmp(wuri, wtop) == 0;
    free_co(wuri);
    free_co(wtop);
    char what[32];
    snprintf(what, sizeof what, "%s %s",
             kind == COREWEBVIEW2_SCRIPT_DIALOG_KIND_ALERT ? "alert" : kind == COREWEBVIEW2_SCRIPT_DIALOG_KIND_CONFIRM ? "confirm" : "prompt",
             desk ? "desk" : "frame");
    hdesk_on_native(what);
    if (!desk || kind == COREWEBVIEW2_SCRIPT_DIALOG_KIND_PROMPT) return S_OK;
    dialog_job *j = (dialog_job *)calloc(1, sizeof *j);
    if (!j) return S_OK;
    if (FAILED(ICoreWebView2ScriptDialogOpeningEventArgs_GetDeferral(args, &j->deferral)) || !j->deferral) {
        free(j);
        return S_OK;
    }
    ICoreWebView2ScriptDialogOpeningEventArgs_get_Message(args, &j->text);
    j->confirm = kind == COREWEBVIEW2_SCRIPT_DIALOG_KIND_CONFIRM;
    j->args = args;
    ICoreWebView2ScriptDialogOpeningEventArgs_AddRef(args);
    // (hdesk_post_main can't say that it failed; at exit only, and then the
    // page waiting on its answer goes with the process)
    hdesk_post_main(show_dialog, j);
    return S_OK;
}
HANDLER(script_dialog, ICoreWebView2ScriptDialogOpeningEventHandler, on_script_dialog);

static void fit(void) {
    if (!ctl || !hwnd) return;
    RECT r;
    GetClientRect(hwnd, &r);
    ICoreWebView2Controller_put_Bounds(ctl, r);
}

#ifdef HDESK_TEST_HOOKS
static int pretend_old(void) { return GetEnvironmentVariableW(L"HDESK_TEST_OLD_RUNTIME", NULL, 0) > 0; }
#endif

static void no_web_view(const wchar_t *why) {
    char *said = utf8(why);
    char note[160];
    snprintf(note, sizeof note, "no web view: it %s", said ? said : "");
    free(said);
    hdesk_on_native(note);
#ifdef HDESK_TEST_HOOKS
    // (no box for the test that pretends: nobody is there to answer it)
    if (pretend_old()) {
        exit_code = 1;
        PostQuitMessage(1);
        return;
    }
#endif
    wchar_t text[600];
    _snwprintf(text, 600, L"harness shows its window through Microsoft's WebView2 Runtime, and it %ls.\n\nOpen Microsoft's page to install it?", why);
    text[599] = 0;
    if (MessageBoxW(hwnd, text, L"harness", MB_YESNO | MB_ICONINFORMATION) == IDYES)
        ShellExecuteW(NULL, L"open", L"https://developer.microsoft.com/microsoft-edge/webview2/", NULL, NULL, SW_SHOWNORMAL);
    exit_code = 1;
    PostQuitMessage(1);
}

static HRESULT STDMETHODCALLTYPE on_controller(void *self, HRESULT result, ICoreWebView2Controller *controller) {
    (void)self;
    if (FAILED(result) || !controller) {
        no_web_view(L"couldn't start here");
        return S_OK;
    }
    ctl = controller;
    ICoreWebView2Controller_AddRef(ctl);
    if (FAILED(ICoreWebView2Controller_get_CoreWebView2(ctl, &web)) || !web) {
        no_web_view(L"couldn't start here");
        return S_OK;
    }
    // the desk's own black behind a page that hasn't drawn yet
    ICoreWebView2Controller2 *c2 = NULL;
    if (SUCCEEDED(ICoreWebView2Controller_QueryInterface(ctl, &IID_ICoreWebView2Controller2, (void **)&c2)) && c2) {
        COREWEBVIEW2_COLOR black = { 255, 7, 7, 13 };
        ICoreWebView2Controller2_put_DefaultBackgroundColor(c2, black);
        ICoreWebView2Controller2_Release(c2);
    }
    ICoreWebView2Settings *settings = NULL;
    if (SUCCEEDED(ICoreWebView2_get_Settings(web, &settings)) && settings) {
        ICoreWebView2Settings_put_IsWebMessageEnabled(settings, TRUE);
        ICoreWebView2Settings_put_IsStatusBarEnabled(settings, FALSE);
        ICoreWebView2Settings_put_AreDevToolsEnabled(settings, FALSE);
        ICoreWebView2Settings_put_IsZoomControlEnabled(settings, FALSE);
        ICoreWebView2Settings_put_AreHostObjectsAllowed(settings, FALSE);
        // the web view's own menu (Print, Save as, Open link in new window)
        // isn't the desk's
        ICoreWebView2Settings_put_AreDefaultContextMenusEnabled(settings, FALSE);
        // alert, confirm and prompt are answered in on_script_dialog, not
        // by the web view's own boxes
        ICoreWebView2Settings_put_AreDefaultScriptDialogsEnabled(settings, FALSE);
        ICoreWebView2Settings2 *s2 = NULL;
        if (SUCCEEDED(ICoreWebView2Settings_QueryInterface(settings, &IID_ICoreWebView2Settings2, (void **)&s2)) && s2) {
            wchar_t *ua = NULL;
            if (SUCCEEDED(ICoreWebView2Settings2_get_UserAgent(s2, &ua)) && ua) {
                size_t n = wcslen(ua) + wcslen(user_agent) + 2;
                wchar_t *both = (wchar_t *)malloc(n * sizeof(wchar_t));
                if (both) {
                    _snwprintf(both, n, L"%ls %ls", ua, user_agent);
                    both[n - 1] = 0;
                    ICoreWebView2Settings2_put_UserAgent(s2, both);
                    free(both);
                }
                CoTaskMemFree(ua);
            }
            ICoreWebView2Settings2_Release(s2);
        }
        // the browser's own keys (print, find, its reload) are not the desk's
        ICoreWebView2Settings3 *s3 = NULL;
        if (SUCCEEDED(ICoreWebView2Settings_QueryInterface(settings, &IID_ICoreWebView2Settings3, (void **)&s3)) && s3) {
            ICoreWebView2Settings3_put_AreBrowserAcceleratorKeysEnabled(s3, FALSE);
            ICoreWebView2Settings3_Release(s3);
        }
        ICoreWebView2Settings_Release(settings);
    }
    EventRegistrationToken tok;
    ICoreWebView2_add_NavigationStarting(web, (ICoreWebView2NavigationStartingEventHandler *)&nav_starting, &tok);
    ICoreWebView2_add_FrameNavigationStarting(web, (ICoreWebView2NavigationStartingEventHandler *)&frame_nav_starting, &tok);
    ICoreWebView2_add_NewWindowRequested(web, (ICoreWebView2NewWindowRequestedEventHandler *)&new_window, &tok);
    ICoreWebView2_add_NavigationCompleted(web, (ICoreWebView2NavigationCompletedEventHandler *)&nav_completed, &tok);
    ICoreWebView2_add_WebMessageReceived(web, (ICoreWebView2WebMessageReceivedEventHandler *)&message, &tok);
    ICoreWebView2_add_PermissionRequested(web, (ICoreWebView2PermissionRequestedEventHandler *)&permission, &tok);
    ICoreWebView2_add_ProcessFailed(web, (ICoreWebView2ProcessFailedEventHandler *)&process_failed, &tok);
    ICoreWebView2_add_ScriptDialogOpening(web, (ICoreWebView2ScriptDialogOpeningEventHandler *)&script_dialog, &tok);
    // Refusing downloads and telling a framed page from the desk's both
    // need ICoreWebView2_4. A runtime without it (an old fixed one: the
    // oldest the loader accepts, oldest_runtime, is older than this
    // interface) would let downloads through and hear a frame as the desk
    // page, so the app doesn't run on it.
    ICoreWebView2_4 *w4 = NULL;
    if (FAILED(ICoreWebView2_QueryInterface(web, &IID_ICoreWebView2_4, (void **)&w4))) w4 = NULL;
#ifdef HDESK_TEST_HOOKS
    // (test builds: with HDESK_TEST_OLD_RUNTIME set, a runtime without it)
    if (w4 && pretend_old()) {
        ICoreWebView2_4_Release(w4);
        w4 = NULL;
    }
#endif
    if (!w4) {
        no_web_view(too_old);
        return S_OK;
    }
    ICoreWebView2_4_add_FrameCreated(w4, (ICoreWebView2FrameCreatedEventHandler *)&frame_created, &tok);
    ICoreWebView2_4_add_DownloadStarting(w4, (ICoreWebView2DownloadStartingEventHandler *)&download, &tok);
    ICoreWebView2_4_Release(w4);
    ICoreWebView2Controller_add_AcceleratorKeyPressed(ctl, (ICoreWebView2AcceleratorKeyPressedEventHandler *)&key, &tok);
    fit();
    ICoreWebView2Controller_put_IsVisible(ctl, TRUE);
    hdesk_on_ready();
    return S_OK;
}
HANDLER(controller_done, ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, on_controller);

static HRESULT STDMETHODCALLTYPE on_environment(void *self, HRESULT result, ICoreWebView2Environment *e) {
    (void)self;
    if (FAILED(result) || !e) {
        no_web_view(result == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) ? L"isn't installed on this computer" : L"couldn't start here");
        return S_OK;
    }
    env = e;
    ICoreWebView2Environment_AddRef(env);
    // cookies and storage in memory only, where the runtime can (InPrivate)
    ICoreWebView2Environment10 *e10 = NULL;
    if (SUCCEEDED(ICoreWebView2Environment_QueryInterface(env, &IID_ICoreWebView2Environment10, (void **)&e10)) && e10) {
        ICoreWebView2ControllerOptions *opts = NULL;
        HRESULT hr = ICoreWebView2Environment10_CreateCoreWebView2ControllerOptions(e10, &opts);
        if (SUCCEEDED(hr) && opts) {
            ICoreWebView2ControllerOptions_put_IsInPrivateModeEnabled(opts, TRUE);
            hr = ICoreWebView2Environment10_CreateCoreWebView2ControllerWithOptions(e10, hwnd, opts, (ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *)&controller_done);
            ICoreWebView2ControllerOptions_Release(opts);
        }
        ICoreWebView2Environment10_Release(e10);
        if (SUCCEEDED(hr)) return S_OK;
    }
    if (FAILED(ICoreWebView2Environment_CreateCoreWebView2Controller(env, hwnd, (ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *)&controller_done)))
        no_web_view(L"couldn't start here");
    return S_OK;
}
HANDLER(environment_done, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, on_environment);

typedef HRESULT(STDAPICALLTYPE *create_env_fn)(PCWSTR browser, PCWSTR data, ICoreWebView2EnvironmentOptions *options, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *done);

// What the web view's browser is started with: media and speech without a
// click. Given as the options object WebView2 asks, which holds for every
// way the program is started (the WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS
// variable did here and not on GitHub's Windows runner). One object for
// the program's life; what it hands out is a copy for the caller to free.
static const wchar_t browser_args[] = L"--autoplay-policy=no-user-gesture-required";
// the oldest runtime the app runs on (what it uses beyond that, it asks for
// and does without where it is missing)
static const wchar_t oldest_runtime[] = L"86.0.616.0";

static HRESULT co_copy(const wchar_t *s, LPWSTR *out) {
    if (!out) return E_POINTER;
    *out = NULL;
    if (!s) return S_OK;
    size_t bytes = (wcslen(s) + 1) * sizeof(wchar_t);
    *out = (LPWSTR)CoTaskMemAlloc(bytes);
    if (!*out) return E_OUTOFMEMORY;
    memcpy(*out, s, bytes);
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE opt_get_args(void *self, LPWSTR *v) { (void)self; return co_copy(browser_args, v); }
static HRESULT STDMETHODCALLTYPE opt_get_language(void *self, LPWSTR *v) { (void)self; return co_copy(NULL, v); }
static HRESULT STDMETHODCALLTYPE opt_get_version(void *self, LPWSTR *v) { (void)self; return co_copy(oldest_runtime, v); }
static HRESULT STDMETHODCALLTYPE opt_put_text(void *self, LPCWSTR v) { (void)self; (void)v; return S_OK; }
static HRESULT STDMETHODCALLTYPE opt_get_sso(void *self, BOOL *v) { (void)self; if (!v) return E_POINTER; *v = FALSE; return S_OK; }
static HRESULT STDMETHODCALLTYPE opt_put_sso(void *self, BOOL v) { (void)self; (void)v; return S_OK; }
static void *options_vtbl[11] = {
    (void *)h_query, (void *)h_addref, (void *)h_release,
    (void *)opt_get_args, (void *)opt_put_text,
    (void *)opt_get_language, (void *)opt_put_text,
    (void *)opt_get_version, (void *)opt_put_text,
    (void *)opt_get_sso, (void *)opt_put_sso,
};
static handler options = { options_vtbl, &IID_ICoreWebView2EnvironmentOptions };

// The loader, from beside this program and nowhere else.
static create_env_fn loader(void) {
    wchar_t path[MAX_PATH * 2];
    DWORD n = GetModuleFileNameW(NULL, path, MAX_PATH * 2 - 32);
    if (n == 0) return NULL;
    wchar_t *slash = wcsrchr(path, L'\\');
    if (!slash) return NULL;
    wcscpy(slash + 1, L"WebView2Loader.dll");
    HMODULE m = LoadLibraryExW(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!m) return NULL;
    return (create_env_fn)(void *)GetProcAddress(m, "CreateCoreWebView2EnvironmentWithOptions");
}

static void start_web_view(void) {
    create_env_fn create = loader();
    if (!create) {
        MessageBoxW(hwnd, L"WebView2Loader.dll isn't beside harness-desk.exe. Both come in the same download: keep them together.", L"harness", MB_OK | MB_ICONERROR);
        exit_code = 1;
        PostQuitMessage(1);
        return;
    }
    // its own folder, in the data folder: never the folder the program is in
    wchar_t *home = wide(hdesk_home());
    wchar_t data[MAX_PATH * 2];
    _snwprintf(data, MAX_PATH * 2, L"%ls\\desk-webview", home ? home : L".");
    data[MAX_PATH * 2 - 1] = 0;
    free(home);
    HRESULT hr = create(NULL, data, (ICoreWebView2EnvironmentOptions *)&options, (ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *)&environment_done);
    if (FAILED(hr)) no_web_view(hr == HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND) ? L"isn't installed on this computer" : L"couldn't start here");
}

// ---- the window ----

static LRESULT CALLBACK wnd_proc(HWND w, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_HD_CALL:
        ((void (*)(void *))wp)((void *)lp);
        return 0;
    case WM_HD_ALERT: {
        wchar_t **pair = (wchar_t **)lp;
        MessageBoxW(w, pair[1], pair[0], MB_OK | MB_ICONINFORMATION);
        free(pair[0]);
        free(pair[1]);
        free(pair);
        return 0;
    }
    case WM_TIMER:
        if (wp >= 1 && wp <= timer_count) timers[wp - 1].fn(timers[wp - 1].arg);
        return 0;
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case ID_START: hdesk_on_menu(HDESK_MENU_START); return 0;
        case ID_STOP: hdesk_on_menu(HDESK_MENU_STOP); return 0;
        case ID_AUTOSTART: hdesk_on_menu(HDESK_MENU_AUTOSTART); return 0;
        case ID_RELOAD: hdesk_on_menu(HDESK_MENU_RELOAD); return 0;
        case ID_PROVIDER: hdesk_on_menu(HDESK_MENU_PROVIDER); return 0;
        case ID_QUIT: hdesk_quit(); return 0;
        }
        break;
    case WM_SIZE:
        fit();
        return 0;
    case WM_MOVE:
        if (ctl) ICoreWebView2Controller_NotifyParentWindowPositionChanged(ctl);
        return 0;
    case WM_EXITSIZEMOVE:
        save_frame();
        return 0;
    case WM_SETFOCUS:
        if (ctl) ICoreWebView2Controller_MoveFocus(ctl, COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
        return 0;
    case WM_GETMINMAXINFO: {
        SIZE s = outer(MIN_W, MIN_H);
        MINMAXINFO *m = (MINMAXINFO *)lp;
        m->ptMinTrackSize.x = s.cx;
        m->ptMinTrackSize.y = s.cy;
        return 0;
    }
    case WM_DPICHANGED: {
        RECT *r = (RECT *)lp;
        SetWindowPos(w, NULL, r->left, r->top, r->right - r->left, r->bottom - r->top, SWP_NOZORDER | SWP_NOACTIVATE);
        return 0;
    }
    // Closing the window leaves the app running, with its badge: it goes to
    // the taskbar, whose button brings it back. Quit is in the menu.
    case WM_CLOSE:
        save_frame();
        ShowWindow(w, SW_MINIMIZE);
        return 0;
    case WM_QUERYENDSESSION:
        save_frame();
        return TRUE;
    case WM_DESTROY:
        PostQuitMessage(exit_code);
        return 0;
    }
    return DefWindowProcW(w, msg, wp, lp);
}

// One window a data folder: a second start brings the first to the front.
static void class_name(wchar_t *out, size_t len) {
    unsigned long long h = 1469598103934665603ULL;
    for (const unsigned char *p = (const unsigned char *)hdesk_home(); *p; p++) {
        unsigned char c = *p;
        if (c >= 'A' && c <= 'Z') c = (unsigned char)(c + 32);
        if (c == '/') c = '\\';
        h = (h ^ c) * 1099511628211ULL;
    }
    _snwprintf(out, len, L"harness-desk-%016llx", h);
    out[len - 1] = 0;
}

int hdesk_run(const char *ua) {
    wchar_t *wua = wide(ua);
    wcsncpy(user_agent, wua ? wua : L"harness-desk", sizeof user_agent / sizeof user_agent[0] - 1);
    free(wua);

    wchar_t cls[64];
    class_name(cls, 64);
    HANDLE once = CreateMutexW(NULL, FALSE, cls);
    if (once && GetLastError() == ERROR_ALREADY_EXISTS) {
        HWND first = FindWindowW(cls, NULL);
        if (first) {
            if (IsIconic(first)) ShowWindow(first, SW_RESTORE);
            SetForegroundWindow(first);
        }
        return 0;
    }

    // sharp on every screen, where Windows can (10, 1703 and later)
    HMODULE u = GetModuleHandleW(L"user32.dll");
    BOOL(WINAPI * aware)(HANDLE) = (BOOL(WINAPI *)(HANDLE))(void *)GetProcAddress(u, "SetProcessDpiAwarenessContext");
    if (aware) aware((HANDLE)-4); // per monitor, version 2

    if (FAILED(CoInitializeEx(NULL, COINIT_APARTMENTTHREADED))) return 1;
    HINSTANCE inst = GetModuleHandleW(NULL);
    WNDCLASSEXW wc;
    memset(&wc, 0, sizeof wc);
    wc.cbSize = sizeof wc;
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.hIcon = LoadIconW(inst, MAKEINTRESOURCEW(1));
    if (!wc.hIcon) wc.hIcon = LoadIconW(NULL, IDI_APPLICATION);
    wc.hIconSm = wc.hIcon;
    wc.hbrBackground = CreateSolidBrush(RGB(7, 7, 13));
    wc.lpszClassName = cls;
    if (!RegisterClassExW(&wc)) return 1;
    build_menu();

    // the web view's own folder holds the window's frame too
    wchar_t *home = wide(hdesk_home());
    wchar_t dir[MAX_PATH * 2];
    _snwprintf(dir, MAX_PATH * 2, L"%ls\\desk-webview", home ? home : L".");
    dir[MAX_PATH * 2 - 1] = 0;
    free(home);
    // (with the folders above it: on a new computer the data folder isn't there yet)
    SHCreateDirectoryExW(NULL, dir, NULL);

    SIZE s = outer(START_W, START_H);
    hwnd = CreateWindowExW(0, cls, L"harness", WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, s.cx, s.cy, NULL, menu_bar, inst, NULL);
    if (!hwnd) return 1;
    RECT saved;
    if (load_frame(&saved)) SetWindowPos(hwnd, NULL, saved.left, saved.top, saved.right - saved.left, saved.bottom - saved.top, SWP_NOZORDER | SWP_NOACTIVATE);
    CoCreateInstance(&HD_CLSID_TaskbarList, NULL, CLSCTX_INPROC_SERVER, &HD_IID_ITaskbarList3, (void **)&taskbar);
    if (taskbar && FAILED(ITaskbarList3_HrInit(taskbar))) {
        ITaskbarList3_Release(taskbar);
        taskbar = NULL;
    }
    ShowWindow(hwnd, SW_SHOWNORMAL);
    UpdateWindow(hwnd);
    start_web_view();

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        // the key window's keys: Enter saves, Esc cancels, Tab moves on
        if (keybox.win && IsDialogMessageW(keybox.win, &msg)) continue;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    save_frame();
    if (ctl) ICoreWebView2Controller_Close(ctl);
    return exit_code;
}

void hdesk_quit(void) {
    save_frame();
    DestroyWindow(hwnd);
}

// ---- the web view ----

void hdesk_show_html(const char *html) {
    if (!web) return;
    wchar_t *w = wide(html);
    if (!w) return;
    html_pending = 1;
    ICoreWebView2_NavigateToString(web, w);
    free(w);
}

void hdesk_load(const char *url) {
    if (!web) return;
    wchar_t *w = wide(url);
    if (!w) return;
    ICoreWebView2_Navigate(web, w);
    free(w);
}

void hdesk_reload(void) {
    if (web) ICoreWebView2_Reload(web);
}

static HRESULT STDMETHODCALLTYPE on_cdp_done(void *self, HRESULT result, LPCWSTR json) {
    (void)self;
    (void)result;
    (void)json;
    return S_OK;
}
HANDLER(cdp_done, ICoreWebView2CallDevToolsProtocolMethodCompletedHandler, on_cdp_done);

// Run as a page's own script runs: through the DevTools protocol's
// Runtime.evaluate, which gives it no user gesture. (ExecuteScript's
// scripts count as the user's, and what they navigate to as clicked: a
// test's script would then open the system browser as a click does.)
// Only the test hooks call this.
void hdesk_eval_js(const char *js) {
    if (!web) return;
    wchar_t *w = wide(js);
    if (!w) return;
    size_t n = wcslen(w);
    wchar_t *params = (wchar_t *)malloc((n * 6 + 32) * sizeof(wchar_t));
    if (params) {
        wchar_t *o = params;
        o += swprintf(o, 32, L"{\"expression\":\"");
        for (size_t i = 0; i < n; i++) {
            wchar_t c = w[i];
            if (c == L'"' || c == L'\\') {
                *o++ = L'\\';
                *o++ = c;
            } else if (c < 0x20) {
                o += swprintf(o, 7, L"\\u%04x", (unsigned)c);
            } else {
                *o++ = c;
            }
        }
        *o++ = L'"';
        *o++ = L'}';
        *o = 0;
        ICoreWebView2_CallDevToolsProtocolMethod(web, L"Runtime.evaluate", params, (ICoreWebView2CallDevToolsProtocolMethodCompletedHandler *)&cdp_done);
        free(params);
    }
    free(w);
}

// Only http, https and mailto get here (policy.zig).
void hdesk_open_external(const char *url) {
    wchar_t *w = wide(url);
    if (!w) return;
    if (_wcsnicmp(w, L"http://", 7) == 0 || _wcsnicmp(w, L"https://", 8) == 0 || _wcsnicmp(w, L"mailto:", 7) == 0)
        ShellExecuteW(NULL, L"open", w, NULL, NULL, SW_SHOWNORMAL);
    free(w);
}

// Shown from the message loop, not from inside the turn that asked for it:
// a message box runs a loop of its own, and the next event would land in
// the middle of this one.
void hdesk_alert(const char *title, const char *text) {
    wchar_t **pair = (wchar_t **)malloc(2 * sizeof(wchar_t *));
    if (!pair) return;
    pair[0] = wide(title);
    pair[1] = wide(text);
    if (!PostMessageW(hwnd, WM_HD_ALERT, 0, (LPARAM)pair)) {
        free(pair[0]);
        free(pair[1]);
        free(pair);
    }
}

// (A post that fails has nowhere else to go: `fn` may only run on the main
// thread, and the only time the window can't take a message is after it
// was destroyed, when the loop that would run it has ended and the process
// is on its way out. What `arg` holds goes with the process.)
void hdesk_post_main(void (*fn)(void *), void *arg) {
    PostMessageW(hwnd, WM_HD_CALL, (WPARAM)fn, (LPARAM)arg);
}

// ---- the key: a small window of Windows' own controls over the app's ----
// `title` above a password edit control, `note` under it, Save and Cancel.
// The web view has no part in it. The app's window is disabled while it is
// open; its answer goes to Zig once (hdesk_on_key), as bytes in a buffer of
// our own that is zeroed right after, the control emptied first.

static void key_close(void) {
    HWND w = keybox.win;
    HFONT f = keybox.font, b = keybox.bold;
    memset(&keybox, 0, sizeof keybox);
    // the app's window first, or another program's would come forward
    EnableWindow(hwnd, TRUE);
    SetForegroundWindow(hwnd);
    if (w) DestroyWindow(w);
    if (f) DeleteObject(f);
    if (b) DeleteObject(b);
}

static void key_answer(int save) {
    if (!keybox.win) return;
    if (!save) {
        SetWindowTextW(keybox.edit, L"");
        key_close();
        hdesk_on_key(NULL, -1);
        return;
    }
    wchar_t typed[2048];
    int n = GetWindowTextW(keybox.edit, typed, (int)(sizeof typed / sizeof typed[0]));
    SetWindowTextW(keybox.edit, L"");
    // (UTF-8 takes at most three bytes for each of these)
    char bytes[sizeof typed / sizeof typed[0] * 3];
    int out = n > 0 ? WideCharToMultiByte(CP_UTF8, 0, typed, n, bytes, (int)sizeof bytes, NULL, NULL) : 0;
    SecureZeroMemory(typed, sizeof typed);
    // closed before the answer: what it starts may ask again
    key_close();
    hdesk_on_key(bytes, out);
    SecureZeroMemory(bytes, sizeof bytes);
}

static LRESULT CALLBACK key_proc(HWND w, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_COMMAND:
        if (LOWORD(wp) == IDOK) {
            key_answer(1);
            return 0;
        }
        if (LOWORD(wp) == IDCANCEL) {
            key_answer(0);
            return 0;
        }
        break;
    case WM_CLOSE:
        key_answer(0);
        return 0;
    }
    return DefWindowProcW(w, msg, wp, lp);
}

static void key_not_shown(void *unused) {
    (void)unused;
    hdesk_on_key(NULL, -1);
}

void hdesk_ask_key(const char *title, const char *note) {
    static int registered;
    if (keybox.win || !hwnd) return;
    HINSTANCE inst = GetModuleHandleW(NULL);
    if (!registered) {
        WNDCLASSEXW wc;
        memset(&wc, 0, sizeof wc);
        wc.cbSize = sizeof wc;
        wc.lpfnWndProc = key_proc;
        wc.hInstance = inst;
        wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
        wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
        wc.lpszClassName = L"harness-desk-key";
        registered = RegisterClassExW(&wc) != 0;
    }
    int d = (int)dpi();
    int cw = MulDiv(440, d, 96), ch = MulDiv(176, d, 96), pad = MulDiv(16, d, 96);
    int bw = MulDiv(88, d, 96), bh = MulDiv(28, d, 96), line = MulDiv(20, d, 96);
    DWORD style = WS_POPUP | WS_CAPTION | WS_SYSMENU;
    RECT r = { 0, 0, cw, ch };
    AdjustWindowRectEx(&r, style, FALSE, WS_EX_DLGMODALFRAME);
    RECT over;
    GetWindowRect(hwnd, &over);
    int ww = r.right - r.left, wh = r.bottom - r.top;
    HWND win = registered ? CreateWindowExW(WS_EX_DLGMODALFRAME, L"harness-desk-key", L"harness", style,
        over.left + ((over.right - over.left) - ww) / 2, over.top + ((over.bottom - over.top) - wh) / 2, ww, wh, hwnd, NULL, inst, NULL) : NULL;
    wchar_t *wtitle = wide(title), *wnote = wide(note);
    HWND head = NULL, edit = NULL, label = NULL, save = NULL, cancel = NULL;
    if (win) {
        head = CreateWindowExW(0, L"STATIC", wtitle ? wtitle : L"Key", WS_CHILD | WS_VISIBLE | SS_NOPREFIX,
            pad, pad, cw - 2 * pad, line, win, NULL, inst, NULL);
        edit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_PASSWORD | ES_AUTOHSCROLL,
            pad, pad + line + MulDiv(6, d, 96), cw - 2 * pad, MulDiv(26, d, 96), win, NULL, inst, NULL);
        label = CreateWindowExW(0, L"STATIC", wnote ? wnote : L"", WS_CHILD | WS_VISIBLE | SS_NOPREFIX,
            pad, pad + line + MulDiv(40, d, 96), cw - 2 * pad, 2 * line, win, NULL, inst, NULL);
        save = CreateWindowExW(0, L"BUTTON", L"Save", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
            cw - pad - 2 * bw - MulDiv(8, d, 96), ch - pad - bh, bw, bh, win, (HMENU)(INT_PTR)IDOK, inst, NULL);
        cancel = CreateWindowExW(0, L"BUTTON", L"Cancel", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
            cw - pad - bw, ch - pad - bh, bw, bh, win, (HMENU)(INT_PTR)IDCANCEL, inst, NULL);
    }
    free(wtitle);
    free(wnote);
    if (!win || !edit) {
        // no window to answer in: as a cancel, after this turn
        if (win) DestroyWindow(win);
        hdesk_post_main(key_not_shown, NULL);
        return;
    }
    HFONT font = NULL, bold = NULL;
    NONCLIENTMETRICSW ncm;
    memset(&ncm, 0, sizeof ncm);
    ncm.cbSize = sizeof ncm;
    if (SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof ncm, &ncm, 0)) {
        // (the system's size is for its own dots an inch; this window's may differ)
        HDC dc = GetDC(NULL);
        int system_dpi = GetDeviceCaps(dc, LOGPIXELSY);
        ReleaseDC(NULL, dc);
        if (system_dpi > 0) ncm.lfMessageFont.lfHeight = MulDiv(ncm.lfMessageFont.lfHeight, d, system_dpi);
        font = CreateFontIndirectW(&ncm.lfMessageFont);
        ncm.lfMessageFont.lfWeight = FW_SEMIBOLD;
        bold = CreateFontIndirectW(&ncm.lfMessageFont);
    }
    HWND kids[] = { edit, label, save, cancel };
    for (size_t i = 0; i < sizeof kids / sizeof kids[0]; i++)
        if (kids[i] && font) SendMessageW(kids[i], WM_SETFONT, (WPARAM)font, TRUE);
    if (head && bold) SendMessageW(head, WM_SETFONT, (WPARAM)bold, TRUE);
    SendMessageW(edit, EM_SETLIMITTEXT, 2000, 0);

    keybox.win = win;
    keybox.edit = edit;
    keybox.font = font;
    keybox.bold = bold;
    EnableWindow(hwnd, FALSE);
    ShowWindow(win, SW_SHOW);
    SetFocus(edit);
}

int hdesk_test_key(int action) {
#ifdef HDESK_TEST_HOOKS
    // a fake key, built into test builds only, set in the real control
    if (!keybox.win) return 0;
    int secure = (GetWindowLongW(keybox.edit, GWL_STYLE) & ES_PASSWORD) ? 1 : 0;
    if (action == 1) SetWindowTextW(keybox.edit, L"sk-test-not-a-key");
    key_answer(action == 1);
    return secure;
#else
    (void)action;
    return -1;
#endif
}

#ifdef HDESK_TEST_HOOKS
// The element's place came back ("[x,y]", or "null"): a press and a
// release there through the browser's own input (the DevTools protocol's
// Input.dispatchMouseEvent), which the page gets as a person's click.
static int click_other; // the mouse's other button: what opens a menu

// A menu of the web view's own is a window of its own, of Chromium's class:
// how many of those are on screen.
static BOOL CALLBACK count_menus(HWND w, LPARAM n) {
    wchar_t cls[64];
    DWORD pid = 0;
    GetWindowThreadProcessId(w, &pid);
    if (pid != GetCurrentProcessId() && IsWindowVisible(w) && GetClassNameW(w, cls, 64) > 0 && wcsncmp(cls, L"Chrome_WidgetWin_", 17) == 0 &&
        (GetWindowLongW(w, GWL_STYLE) & WS_POPUP))
        (*(int *)n)++;
    return TRUE;
}
static int menus_before;
static void CALLBACK menus_after(HWND w, UINT msg, UINT_PTR id, DWORD at) {
    (void)msg;
    (void)at;
    KillTimer(w, id);
    int n = 0;
    EnumWindows(count_menus, (LPARAM)&n);
    hdesk_on_native(n > menus_before ? "menu shown" : "menu kept shut");
}

static HRESULT STDMETHODCALLTYPE on_click_place(void *self, HRESULT result, LPCWSTR json) {
    (void)self;
    double x = 0, y = 0;
    if (FAILED(result) || !json || !web || swscanf(json, L"[%lf,%lf]", &x, &y) != 2) return S_OK;
    static const wchar_t *const kinds[2] = { L"mousePressed", L"mouseReleased" };
    if (click_other) {
        menus_before = 0;
        EnumWindows(count_menus, (LPARAM)&menus_before);
    }
    for (int i = 0; i < 2; i++) {
        wchar_t params[200];
        _snwprintf(params, 200, L"{\"type\":\"%ls\",\"x\":%.1f,\"y\":%.1f,\"button\":\"%ls\",\"buttons\":%d,\"clickCount\":1}", kinds[i], x, y,
                   click_other ? L"right" : L"left", i == 0 ? (click_other ? 2 : 1) : 0);
        params[199] = 0;
        ICoreWebView2_CallDevToolsProtocolMethod(web, L"Input.dispatchMouseEvent", params, (ICoreWebView2CallDevToolsProtocolMethodCompletedHandler *)&cdp_done);
    }
    // (a menu would be up well within this)
    if (click_other) SetTimer(hwnd, 9001, 1500, menus_after);
    return S_OK;
}
HANDLER(click_place, ICoreWebView2ExecuteScriptCompletedHandler, on_click_place);

static void click_at(const char *element, int other) {
    if (!web) return;
    // (an id of letters, digits, - and _ only: it goes into a script)
    for (const char *p = element; *p; p++)
        if (!isalnum((unsigned char)*p) && *p != '-' && *p != '_') return;
    click_other = other;
    char js[420];
    snprintf(js, sizeof js, "(function(){var e=document.getElementById('%.80s');if(!e)return null;"
                            "e.scrollIntoView({block:'center'});var r=e.getBoundingClientRect();"
                            "return [r.left+r.width/2,r.top+r.height/2];})()", element);
    wchar_t *w = wide(js);
    if (!w) return;
    ICoreWebView2_ExecuteScript(web, w, (ICoreWebView2ExecuteScriptCompletedHandler *)&click_place);
    free(w);
}
#endif

void hdesk_test_menu_click(const char *element) {
#ifdef HDESK_TEST_HOOKS
    click_at(element, 1);
#else
    (void)element;
#endif
}

void hdesk_test_click(const char *element) {
#ifdef HDESK_TEST_HOOKS
    click_at(element, 0);
#else
    (void)element;
#endif
}

void hdesk_every(double seconds, void (*fn)(void *), void *arg) {
    if (timer_count >= sizeof timers / sizeof timers[0]) return;
    timers[timer_count].fn = fn;
    timers[timer_count].arg = arg;
    timer_count++;
    SetTimer(hwnd, timer_count, (UINT)(seconds * 1000.0), NULL);
}

// ---- the frame: x and y from the screen's top left, in pixels ----

void hdesk_window_frame(double *x, double *y, double *w, double *h) {
    RECT r = { 0, 0, 0, 0 };
    GetWindowRect(hwnd, &r);
    *x = r.left;
    *y = r.top;
    *w = r.right - r.left;
    *h = r.bottom - r.top;
}

void hdesk_set_window_frame(double x, double y, double w, double h) {
    if (IsIconic(hwnd) || IsZoomed(hwnd)) ShowWindow(hwnd, SW_RESTORE);
    SetWindowPos(hwnd, NULL, (int)x, (int)y, (int)w, (int)h, SWP_NOZORDER | SWP_NOACTIVATE);
    save_frame();
}

void hdesk_screen_frame(double *x, double *y, double *w, double *h) {
    MONITORINFO mi;
    memset(&mi, 0, sizeof mi);
    mi.cbSize = sizeof mi;
    GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY), &mi);
    *x = mi.rcWork.left;
    *y = mi.rcWork.top;
    *w = mi.rcWork.right - mi.rcWork.left;
    *h = mi.rcWork.bottom - mi.rcWork.top;
}

void hdesk_min_frame(double *w, double *h) {
    SIZE s = outer(MIN_W, MIN_H);
    *w = s.cx;
    *h = s.cy;
}
