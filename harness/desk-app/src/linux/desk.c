// harness-desk's Linux layer: a GTK 3 window, its menu, and a WebKitGTK 4.1
// web view. Every decision is made in Zig (main.zig): this file asks through
// the hdesk_on_* callbacks and does what it's told. See ../mac/desk.h for
// the interface; everything here runs on the main thread, except
// hdesk_post_main.
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include "../mac/desk.h"

// The data folder and the window's icon (a PNG), from Zig.
const char *hdesk_home(void);
const unsigned char *hdesk_icon(size_t *len);

enum { MIN_W = 1024, MIN_H = 700, START_W = 1280, START_H = 820 };

static GApplication *gapp;
static GtkWidget *win;
static GtkWidget *menu_bar;
static GtkWidget *item_start, *item_stop, *item_autostart, *item_provider;
// the key dialog and its entry, while it is open
static GtkWidget *key_dialog, *key_entry;
static WebKitWebView *web;
static char badge[32];
static char *agent_name, *agent_version;
// Open at login's mark is being set by the app, not chosen by the owner
static int setting_mark;
// the last frame asked for, kept as asked: a window manager may move it
static int have_frame;
static int frame_x, frame_y, frame_w, frame_h;

// ---- the window's frame, kept between starts ----

static char *own_dir(void) { return g_build_filename(hdesk_home(), "desk-webview", NULL); }

static void save_frame(void) {
    if (!win) return;
    int x = 0, y = 0, w = 0, h = 0;
    gtk_window_get_position(GTK_WINDOW(win), &x, &y);
    gtk_window_get_size(GTK_WINDOW(win), &w, &h);
    if (w < 200 || h < 200) return;
    char *dir = own_dir();
    g_mkdir_with_parents(dir, 0700);
    char *path = g_build_filename(dir, "window-frame", NULL);
    char text[96];
    snprintf(text, sizeof text, "%d %d %d %d\n", x, y, w, h);
    g_file_set_contents(path, text, -1, NULL);
    g_free(path);
    g_free(dir);
}

static int load_frame(int *x, int *y, int *w, int *h) {
    char *dir = own_dir();
    char *path = g_build_filename(dir, "window-frame", NULL);
    char *text = NULL;
    int ok = g_file_get_contents(path, &text, NULL, NULL) && text && sscanf(text, "%d %d %d %d", x, y, w, h) == 4 && *w >= 200 && *h >= 200;
    g_free(text);
    g_free(path);
    g_free(dir);
    return ok;
}

// ---- the badge: the count in the title; attention: the urgency hint ----

void hdesk_badge(const char *label) {
    g_strlcpy(badge, label ? label : "", sizeof badge);
    char title[64];
    if (badge[0]) snprintf(title, sizeof title, "harness (%s)", badge); else g_strlcpy(title, "harness", sizeof title);
    gtk_window_set_title(GTK_WINDOW(win), title);
}

void hdesk_badge_label(char *buf, int len) {
    if (len <= 0) return;
    // as the title has it: "harness (3)"
    const char *title = gtk_window_get_title(GTK_WINDOW(win));
    const char *open = title ? strchr(title, '(') : NULL;
    int n = 0;
    if (open) for (open++; *open && *open != ')' && n < len - 1; open++) buf[n++] = *open;
    buf[n] = 0;
}

void hdesk_attention(void) { gtk_window_set_urgency_hint(GTK_WINDOW(win), TRUE); }

static gboolean on_focus_in(GtkWidget *w, GdkEvent *e, gpointer d) {
    (void)e;
    (void)d;
    gtk_window_set_urgency_hint(GTK_WINDOW(w), FALSE);
    return FALSE;
}

// ---- the menu ----

static void on_menu(GtkMenuItem *item, gpointer which) {
    (void)item;
    int id = GPOINTER_TO_INT(which);
    if (id == HDESK_MENU_AUTOSTART && setting_mark) return;
    if (id < 0) hdesk_quit(); else hdesk_on_menu(id);
}

static GtkWidget *add_item(GtkWidget *menu, GtkWidget *item, int id, GtkAccelGroup *keys, guint key) {
    g_signal_connect(item, "activate", G_CALLBACK(on_menu), GINT_TO_POINTER(id));
    if (key) gtk_widget_add_accelerator(item, "activate", keys, key, GDK_CONTROL_MASK, GTK_ACCEL_VISIBLE);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
    return item;
}

static void build_menu(GtkAccelGroup *keys) {
    menu_bar = gtk_menu_bar_new();
    GtkWidget *app = gtk_menu_new();
    item_start = add_item(app, gtk_menu_item_new_with_mnemonic("_Start harness"), HDESK_MENU_START, keys, 0);
    item_stop = add_item(app, gtk_menu_item_new_with_mnemonic("S_top harness"), HDESK_MENU_STOP, keys, 0);
    gtk_menu_shell_append(GTK_MENU_SHELL(app), gtk_separator_menu_item_new());
    item_autostart = add_item(app, gtk_check_menu_item_new_with_mnemonic("_Open at login"), HDESK_MENU_AUTOSTART, keys, 0);
    item_provider = add_item(app, gtk_menu_item_new_with_mnemonic("_Provider and key\xe2\x80\xa6"), HDESK_MENU_PROVIDER, keys, 0);
    gtk_menu_shell_append(GTK_MENU_SHELL(app), gtk_separator_menu_item_new());
    add_item(app, gtk_menu_item_new_with_mnemonic("_Quit harness"), -1, keys, GDK_KEY_q);
    GtkWidget *top = gtk_menu_item_new_with_mnemonic("_harness");
    gtk_menu_item_set_submenu(GTK_MENU_ITEM(top), app);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu_bar), top);
    GtkWidget *view = gtk_menu_new();
    add_item(view, gtk_menu_item_new_with_mnemonic("_Reload"), HDESK_MENU_RELOAD, keys, GDK_KEY_r);
    GtkWidget *vtop = gtk_menu_item_new_with_mnemonic("_View");
    gtk_menu_item_set_submenu(GTK_MENU_ITEM(vtop), view);
    gtk_menu_shell_append(GTK_MENU_SHELL(menu_bar), vtop);
    gtk_widget_set_sensitive(item_start, FALSE);
    gtk_widget_set_sensitive(item_stop, FALSE);
    gtk_widget_set_sensitive(item_autostart, FALSE);
    gtk_widget_set_sensitive(item_provider, FALSE);
}

// ---- the key: a dialog of GTK's own over the window ----
// `title` above an entry that doesn't show what is typed, `note` under it,
// Save and Cancel. The web view has no part in it. Its answer goes to Zig
// once (hdesk_on_key), as bytes in a buffer of our own that is zeroed right
// after, the entry emptied first.

static void wipe(char *p, size_t n) {
    volatile char *v = p;
    while (n--) *v++ = 0;
}

static void on_key_response(GtkDialog *d, gint response, gpointer unused) {
    (void)d;
    (void)unused;
    GtkWidget *dlg = key_dialog, *entry = key_entry;
    if (!dlg) return;
    key_dialog = NULL;
    key_entry = NULL;
    if (response != GTK_RESPONSE_OK) {
        gtk_entry_set_text(GTK_ENTRY(entry), "");
        gtk_widget_destroy(dlg);
        hdesk_on_key(NULL, -1);
        return;
    }
    const char *typed = gtk_entry_get_text(GTK_ENTRY(entry));
    size_t n = typed ? strlen(typed) : 0;
    char *bytes = g_malloc(n + 1);
    if (n) memcpy(bytes, typed, n);
    bytes[n] = 0;
    gtk_entry_set_text(GTK_ENTRY(entry), "");
    // closed before the answer: what it starts may ask again
    gtk_widget_destroy(dlg);
    hdesk_on_key(bytes, (int)n);
    wipe(bytes, n + 1);
    g_free(bytes);
}

void hdesk_ask_key(const char *title, const char *note) {
    if (key_dialog || !win) return;
    GtkWidget *dlg = gtk_dialog_new_with_buttons("harness", GTK_WINDOW(win),
        GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT, "_Cancel", GTK_RESPONSE_CANCEL, "_Save", GTK_RESPONSE_OK, NULL);
    gtk_dialog_set_default_response(GTK_DIALOG(dlg), GTK_RESPONSE_OK);
    gtk_window_set_resizable(GTK_WINDOW(dlg), FALSE);
    GtkWidget *box = gtk_dialog_get_content_area(GTK_DIALOG(dlg));
    gtk_container_set_border_width(GTK_CONTAINER(box), 16);
    gtk_box_set_spacing(GTK_BOX(box), 8);
    GtkWidget *head = gtk_label_new(NULL);
    char *bold = g_markup_printf_escaped("<b>%s</b>", title ? title : "Key");
    gtk_label_set_markup(GTK_LABEL(head), bold);
    g_free(bold);
    gtk_label_set_xalign(GTK_LABEL(head), 0);
    gtk_box_pack_start(GTK_BOX(box), head, FALSE, FALSE, 0);
    GtkWidget *entry = gtk_entry_new();
    gtk_entry_set_visibility(GTK_ENTRY(entry), FALSE);
    gtk_entry_set_input_purpose(GTK_ENTRY(entry), GTK_INPUT_PURPOSE_PASSWORD);
    gtk_entry_set_activates_default(GTK_ENTRY(entry), TRUE);
    gtk_entry_set_max_length(GTK_ENTRY(entry), 2000);
    gtk_entry_set_width_chars(GTK_ENTRY(entry), 44);
    gtk_box_pack_start(GTK_BOX(box), entry, FALSE, FALSE, 0);
    GtkWidget *label = gtk_label_new(note ? note : "");
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_label_set_line_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(label), 48);
    gtk_box_pack_start(GTK_BOX(box), label, FALSE, FALSE, 0);
    key_dialog = dlg;
    key_entry = entry;
    g_signal_connect(dlg, "response", G_CALLBACK(on_key_response), NULL);
    gtk_window_present(GTK_WINDOW(win));
    gtk_widget_show_all(dlg);
    gtk_widget_grab_focus(entry);
}

int hdesk_test_key(int action) {
#ifdef HDESK_TEST_HOOKS
    // a fake key, built into test builds only, set in the real entry
    if (!key_dialog) return 0;
    int secure = gtk_entry_get_visibility(GTK_ENTRY(key_entry)) ? 0 : 1;
    if (action == 1) gtk_entry_set_text(GTK_ENTRY(key_entry), "sk-test-not-a-key");
    gtk_dialog_response(GTK_DIALOG(key_dialog), action == 1 ? GTK_RESPONSE_OK : GTK_RESPONSE_CANCEL);
    return secure;
#else
    (void)action;
    return -1;
#endif
}

#ifdef HDESK_TEST_HOOKS
// Where the element is, then a mouse press and release there, put to GTK
// as the window system's own events are: WebKit takes them as a person's.
static void click_there(GObject *src, GAsyncResult *res, gpointer d) {
    (void)d;
    JSCValue *v = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(src), res, NULL);
    if (!v) return;
    char *s = jsc_value_is_string(v) ? jsc_value_to_string(v) : NULL;
    double x = 0, y = 0;
    GdkWindow *gw = gtk_widget_get_window(GTK_WIDGET(web));
    if (s && gw && sscanf(s, "%lf %lf", &x, &y) == 2) {
        int rx = 0, ry = 0;
        gdk_window_get_root_coords(gw, (int)x, (int)y, &rx, &ry);
        GdkDevice *pointer = gdk_seat_get_pointer(gdk_display_get_default_seat(gdk_window_get_display(gw)));
        for (int up = 0; up < 2; up++) {
            GdkEvent *ev = gdk_event_new(up ? GDK_BUTTON_RELEASE : GDK_BUTTON_PRESS);
            ev->button.window = g_object_ref(gw);
            ev->button.send_event = FALSE;
            ev->button.time = GDK_CURRENT_TIME;
            ev->button.x = x;
            ev->button.y = y;
            ev->button.x_root = rx;
            ev->button.y_root = ry;
            ev->button.button = 1;
            ev->button.state = up ? GDK_BUTTON1_MASK : 0;
            gdk_event_set_device(ev, pointer);
            gtk_main_do_event(ev);
            gdk_event_free(ev);
        }
    }
    g_free(s);
    g_object_unref(v);
}
#endif

void hdesk_test_click(const char *element) {
#ifdef HDESK_TEST_HOOKS
    // (an id of letters, digits, - and _ only: it goes into a script)
    for (const char *p = element; *p; p++)
        if (!g_ascii_isalnum(*p) && *p != '-' && *p != '_') return;
    char *js = g_strdup_printf("(function(){var e=document.getElementById('%s');if(!e)return '';"
                               "e.scrollIntoView({block:'center'});var r=e.getBoundingClientRect();"
                               "return (r.left+r.width/2)+' '+(r.top+r.height/2);})()", element);
    webkit_web_view_evaluate_javascript(web, js, -1, NULL, NULL, NULL, click_there, NULL);
    g_free(js);
#else
    (void)element;
#endif
}

void hdesk_menu_state(int start, int stop, int autostart_enabled, int autostart_on, int provider) {
    gtk_widget_set_sensitive(item_provider, provider != 0);
    gtk_widget_set_sensitive(item_start, start != 0);
    gtk_widget_set_sensitive(item_stop, stop != 0);
    gtk_widget_set_sensitive(item_autostart, autostart_enabled != 0);
    setting_mark = 1;
    gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(item_autostart), autostart_on == 1);
    setting_mark = 0;
}

// ---- strings ----

// "http", "127.0.0.1" and the port of an address (0: the scheme's own); a
// page that is not on the web ("about:blank") has only a scheme.
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
    const char *pc = NULL;
    for (size_t i = 0; i < end; i++) if (auth[i] == ':') pc = auth + i;
    size_t hn = pc ? (size_t)(pc - auth) : end;
    // (an address with a user part is not harness's: its host is kept whole,
    // so it matches nothing)
    if (memchr(auth, '@', end)) { hn = end; pc = NULL; }
    if (hn >= hlen) hn = hlen - 1;
    memcpy(host, auth, hn);
    host[hn] = 0;
    if (pc) *port = atoi(pc + 1);
}

// ---- navigation ----

// A person's click on a link: a link activated with a mouse button, as on
// macOS. A script's click(), its location = and window.open carry no
// button (WebKit takes one only from an event of the system's), and
// "user gesture" alone won't do: a script the app itself evaluates counts
// as one.
static int person_clicked(WebKitNavigationAction *a) {
    return webkit_navigation_action_get_navigation_type(a) == WEBKIT_NAVIGATION_TYPE_LINK_CLICKED && webkit_navigation_action_get_mouse_button(a) != 0;
}

static gboolean on_decide(WebKitWebView *view, WebKitPolicyDecision *decision, WebKitPolicyDecisionType type, gpointer d) {
    (void)d;
    switch (type) {
    case WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION: {
        WebKitNavigationAction *a = webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(decision));
        const char *uri = webkit_uri_request_get_uri(webkit_navigation_action_get_request(a));
        // WebKitGTK doesn't say which frame is navigating. What the owner
        // did (a click, the app's own load) is taken as the window's: an
        // address that isn't the desk's then goes to the system browser. What
        // a script did by itself is taken as a frame's: it goes nowhere. The
        // desk's own address is allowed in both.
        int clicked = person_clicked(a);
        int frame = clicked || webkit_navigation_action_is_user_gesture(a) ? HDESK_FRAME_MAIN : HDESK_FRAME_SUB;
        if (hdesk_on_navigate_from(uri ? uri : "", frame, clicked) == HDESK_ALLOW) webkit_policy_decision_use(decision); else webkit_policy_decision_ignore(decision);
        return TRUE;
    }
    // never a second window: the desk's own pages load in this one
    case WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION: {
        WebKitNavigationAction *a = webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(decision));
        const char *uri = webkit_uri_request_get_uri(webkit_navigation_action_get_request(a));
        if (hdesk_on_navigate_from(uri ? uri : "", HDESK_FRAME_NEW_WINDOW, person_clicked(a)) == HDESK_ALLOW && uri) webkit_web_view_load_uri(view, uri);
        webkit_policy_decision_ignore(decision);
        return TRUE;
    }
    case WEBKIT_POLICY_DECISION_TYPE_RESPONSE: {
        WebKitResponsePolicyDecision *r = WEBKIT_RESPONSE_POLICY_DECISION(decision);
        WebKitURIResponse *resp = webkit_response_policy_decision_get_response(r);
        int main_frame = webkit_response_policy_decision_is_main_frame_main_resource(r);
        hdesk_on_response(webkit_uri_response_get_uri(resp) ? webkit_uri_response_get_uri(resp) : "", (int)webkit_uri_response_get_status_code(resp), main_frame);
        // nothing is downloaded
        if (webkit_response_policy_decision_is_mime_type_supported(r)) webkit_policy_decision_use(decision); else webkit_policy_decision_ignore(decision);
        return TRUE;
    }
    default:
        return FALSE;
    }
}

// window.open: no new web view (the decision above loads the desk's own
// address in this one)
static GtkWidget *on_create(WebKitWebView *view, WebKitNavigationAction *a, gpointer d) {
    (void)d;
    // (a script's window.open comes here without a decision asked first:
    // it is put to the policy as a new window's navigation, so the desk's
    // own address loads in this view and anything else is dropped and
    // logged as dropped)
    const char *uri = webkit_uri_request_get_uri(webkit_navigation_action_get_request(a));
    if (hdesk_on_navigate_from(uri ? uri : "", HDESK_FRAME_NEW_WINDOW, person_clicked(a)) == HDESK_ALLOW && uri) webkit_web_view_load_uri(view, uri);
    return NULL;
}

static void on_load_changed(WebKitWebView *view, WebKitLoadEvent event, gpointer d) {
    (void)d;
    if (event != WEBKIT_LOAD_FINISHED) return;
    const char *uri = webkit_web_view_get_uri(view);
    hdesk_on_finish(uri ? uri : "about:blank");
}

static gboolean on_load_failed(WebKitWebView *view, WebKitLoadEvent event, const char *uri, GError *error, gpointer d) {
    (void)view;
    (void)event;
    (void)d;
    // a navigation stopped on purpose (by policy, or by the next one) isn't a failure
    if (g_error_matches(error, WEBKIT_NETWORK_ERROR, WEBKIT_NETWORK_ERROR_CANCELLED)) return TRUE;
    if (g_error_matches(error, WEBKIT_POLICY_ERROR, WEBKIT_POLICY_ERROR_FRAME_LOAD_INTERRUPTED_BY_POLICY_CHANGE)) return TRUE;
    hdesk_on_failed(uri ? uri : "", error ? error->code : 0);
    // (no error page of WebKit's: the app shows its own)
    return TRUE;
}

static void on_terminated(WebKitWebView *view, WebKitWebProcessTerminationReason reason, gpointer d) {
    (void)view;
    (void)reason;
    (void)d;
    hdesk_on_crashed();
}

static void on_download(WebKitWebContext *ctx, WebKitDownload *download, gpointer d) {
    (void)ctx;
    (void)d;
    webkit_download_cancel(download);
}

// ---- the bridge ----
//
// The handler is in a world of the app's own, and only the window's own
// page gets the two scripts that reach it, so a frame in the page has no
// `window.webkit.messageHandlers.harness` at all (WebKitGTK doesn't say
// which frame a message came from). The page's world and the app's share
// the document, not objects: the message crosses as an attribute's text.

#define HD_WORLD "harness-desk"

static const char page_script[] =
    "(function () {\n"
    "  var h = { postMessage: function (m) {\n"
    "    var text = typeof m === 'string' ? m : JSON.stringify(m);\n"
    "    var root = document.documentElement;\n"
    "    if (!root || text === undefined) return;\n"
    "    root.setAttribute('data-harness-desk-message', text);\n"
    "    root.dispatchEvent(new Event('harness-desk-message'));\n"
    "  } };\n"
    "  try {\n"
    "    if (!window.webkit) window.webkit = {};\n"
    "    if (!window.webkit.messageHandlers) window.webkit.messageHandlers = {};\n"
    "    window.webkit.messageHandlers.harness = h;\n"
    "  } catch (e) {}\n"
    "})();\n";

static const char world_script[] =
    "document.addEventListener('harness-desk-message', function () {\n"
    "  var root = document.documentElement;\n"
    "  var text = root && root.getAttribute('data-harness-desk-message');\n"
    "  if (root) root.removeAttribute('data-harness-desk-message');\n"
    "  if (typeof text === 'string') window.webkit.messageHandlers.harness.postMessage(text);\n"
    "}, true);\n";

static void on_message(WebKitUserContentManager *ucm, WebKitJavascriptResult *result, gpointer d) {
    (void)ucm;
    (void)d;
    JSCValue *v = webkit_javascript_result_get_js_value(result);
    if (!v || !jsc_value_is_string(v)) return;
    char *json = jsc_value_to_string(v);
    if (!json) return;
    const char *uri = webkit_web_view_get_uri(web);
    char proto[16], host[256];
    int port = 0;
    origin_of(uri ? uri : "about:blank", proto, sizeof proto, host, sizeof host, &port);
    // The main frame's, always: the handler lives in a world of its own
    // (HD_WORLD) that only the top document has a script in, and that
    // script passes on what is set on the top document's root element. A
    // framed app (another origin, or sandboxed) can't reach that element.
    hdesk_on_message(json, 1, proto, host, port);
    g_free(json);
}

// ---- the microphone ----
//
// For the desk page, by the window's own address. WebKitGTK's 4.1 API
// doesn't say which frame asks, so a request is judged as the window's;
// what keeps a framed app from asking is the page, which gives none of its
// frames the microphone (no `allow` on them, and WebKit refuses a frame of
// another origin without one before it gets here). Only a request for a
// microphone or a camera is put to the policy: the screen, and a request
// that names neither, are refused here. Anything else a page may ask for
// is refused too.
static gboolean on_permission(WebKitWebView *view, WebKitPermissionRequest *request, gpointer d) {
    (void)d;
    int ok = 0;
    if (WEBKIT_IS_USER_MEDIA_PERMISSION_REQUEST(request)) {
        WebKitUserMediaPermissionRequest *m = WEBKIT_USER_MEDIA_PERMISSION_REQUEST(request);
        int audio = webkit_user_media_permission_is_for_audio_device(m);
        int video = webkit_user_media_permission_is_for_video_device(m);
        int screen = webkit_user_media_permission_is_for_display_device(m);
        if (!screen && (audio || video)) {
            const char *uri = webkit_web_view_get_uri(view);
            char proto[16], host[256];
            int port = 0;
            origin_of(uri ? uri : "", proto, sizeof proto, host, sizeof host, &port);
            ok = hdesk_on_media(proto, host, port, 1, audio && video ? HDESK_MEDIA_BOTH : video ? HDESK_MEDIA_CAMERA : HDESK_MEDIA_MIC);
        }
    }
    if (ok) webkit_permission_request_allow(request); else webkit_permission_request_deny(request);
    return TRUE;
}

// The web view's own menu (Print, Save as, Open link in new window,
// Download linked file) isn't the desk's: none is shown.
static gboolean on_context_menu(WebKitWebView *view, WebKitContextMenu *menu, GdkEvent *event, WebKitHitTestResult *hit, gpointer d) {
    (void)view;
    (void)menu;
    (void)event;
    (void)hit;
    (void)d;
    return TRUE;
}

// ---- the web process's sandbox ----

// Whether bubblewrap can make the namespaces WebKit's sandbox is built
// from. It can't where unprivileged user namespaces are restricted (stock
// Ubuntu 24.04, until its AppArmor setting or a profile allows it): there
// the web process would never start and the window would stay empty.
static int sandbox_works(void) {
    char *argv[] = { "bwrap", "--unshare-user", "--unshare-pid", "--ro-bind", "/", "/", "true", NULL };
    int status = 1;
    if (!g_spawn_sync(NULL, argv, NULL, G_SPAWN_SEARCH_PATH | G_SPAWN_STDOUT_TO_DEV_NULL | G_SPAWN_STDERR_TO_DEV_NULL, NULL, NULL, NULL, NULL, &status, NULL)) return 0;
    return g_spawn_check_wait_status(status, NULL) ? 1 : 0;
}

// ---- the window ----

// Closing the window leaves the app running, with its badge: it goes to
// the taskbar, whose entry brings it back. Quit is in the menu.
static gboolean on_delete(GtkWidget *w, GdkEvent *e, gpointer d) {
    (void)e;
    (void)d;
    save_frame();
    gtk_window_iconify(GTK_WINDOW(w));
    return TRUE;
}

static void on_activate(GApplication *a, gpointer d) {
    (void)a;
    (void)d;
    if (win) gtk_window_present(GTK_WINDOW(win));
}

static void build_window(void) {
    win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_title(GTK_WINDOW(win), "harness");
    gtk_window_set_default_size(GTK_WINDOW(win), START_W, START_H);
    size_t icon_len = 0;
    const unsigned char *icon = hdesk_icon(&icon_len);
    GdkPixbufLoader *loader = gdk_pixbuf_loader_new();
    if (icon_len > 0 && gdk_pixbuf_loader_write(loader, icon, icon_len, NULL) && gdk_pixbuf_loader_close(loader, NULL)) {
        GdkPixbuf *pix = gdk_pixbuf_loader_get_pixbuf(loader);
        if (pix) gtk_window_set_icon(GTK_WINDOW(win), pix);
    }
    g_object_unref(loader);
    g_object_set(gtk_settings_get_default(), "gtk-application-prefer-dark-theme", TRUE, NULL);
    GtkAccelGroup *keys = gtk_accel_group_new();
    gtk_window_add_accel_group(GTK_WINDOW(win), keys);
    build_menu(keys);

    WebKitWebContext *ctx = webkit_web_context_new_ephemeral();
    // The pages run in WebKit's sandbox (bubblewrap) wherever it can be
    // made; it has to be asked for before the first web process starts.
    // Where it can't, the app runs as it did before, and says so.
    int sandbox = sandbox_works();
    if (sandbox) webkit_web_context_set_sandbox_enabled(ctx, TRUE);
    hdesk_on_sandbox(sandbox);
    g_signal_connect(ctx, "download-started", G_CALLBACK(on_download), NULL);
    WebKitUserContentManager *ucm = webkit_user_content_manager_new();
    webkit_user_content_manager_register_script_message_handler_in_world(ucm, "harness", HD_WORLD);
    g_signal_connect(ucm, "script-message-received::harness", G_CALLBACK(on_message), NULL);
    WebKitUserScript *in_page = webkit_user_script_new(page_script, WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, NULL, NULL);
    WebKitUserScript *in_world = webkit_user_script_new_for_world(world_script, WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, HD_WORLD, NULL, NULL);
    webkit_user_content_manager_add_script(ucm, in_page);
    webkit_user_content_manager_add_script(ucm, in_world);
    webkit_user_script_unref(in_page);
    webkit_user_script_unref(in_world);

    WebKitSettings *settings = webkit_settings_new();
    webkit_settings_set_user_agent_with_application_details(settings, agent_name, agent_version);
    // the avatar draws with WebGL 2
    webkit_settings_set_enable_webgl(settings, TRUE);
    webkit_settings_set_hardware_acceleration_policy(settings, WEBKIT_HARDWARE_ACCELERATION_POLICY_ALWAYS);
    // media without a click; the microphone, asked for (on_permission)
    webkit_settings_set_media_playback_requires_user_gesture(settings, FALSE);
    webkit_settings_set_enable_media_stream(settings, TRUE);
    webkit_settings_set_enable_developer_extras(settings, FALSE);
    webkit_settings_set_enable_back_forward_navigation_gestures(settings, FALSE);

    // (the setting above is the old switch; this policy is the one WebKit
    // goes by for a page's own play())
    WebKitWebsitePolicies *policies = webkit_website_policies_new_with_policies("autoplay", WEBKIT_AUTOPLAY_ALLOW, NULL);
    web = WEBKIT_WEB_VIEW(g_object_new(WEBKIT_TYPE_WEB_VIEW, "web-context", ctx, "user-content-manager", ucm, "settings", settings, "website-policies", policies, NULL));
    g_object_unref(policies);
    GdkRGBA black = { 7 / 255.0, 7 / 255.0, 13 / 255.0, 1 };
    webkit_web_view_set_background_color(web, &black);
    g_signal_connect(web, "decide-policy", G_CALLBACK(on_decide), NULL);
    g_signal_connect(web, "create", G_CALLBACK(on_create), NULL);
    g_signal_connect(web, "load-changed", G_CALLBACK(on_load_changed), NULL);
    g_signal_connect(web, "load-failed", G_CALLBACK(on_load_failed), NULL);
    g_signal_connect(web, "web-process-terminated", G_CALLBACK(on_terminated), NULL);
    g_signal_connect(web, "permission-request", G_CALLBACK(on_permission), NULL);
    g_signal_connect(web, "context-menu", G_CALLBACK(on_context_menu), NULL);
    gtk_widget_set_size_request(GTK_WIDGET(web), MIN_W, MIN_H);

    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_box_pack_start(GTK_BOX(box), menu_bar, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), GTK_WIDGET(web), TRUE, TRUE, 0);
    gtk_container_add(GTK_CONTAINER(win), box);
    g_signal_connect(win, "delete-event", G_CALLBACK(on_delete), NULL);
    g_signal_connect(win, "focus-in-event", G_CALLBACK(on_focus_in), NULL);

    int x, y, w, h;
    if (load_frame(&x, &y, &w, &h)) {
        gtk_window_resize(GTK_WINDOW(win), w, h);
        gtk_window_move(GTK_WINDOW(win), x, y);
        have_frame = 1;
        frame_x = x;
        frame_y = y;
        frame_w = w;
        frame_h = h;
    }
    gtk_widget_show_all(win);
    gtk_widget_grab_focus(GTK_WIDGET(web));
}

static gboolean ready_once(gpointer d) {
    (void)d;
    hdesk_on_ready();
    return G_SOURCE_REMOVE;
}

// One window a data folder: a second start brings the first to the front
// (through the session bus, where there is one) and ends.
static int first_here(void) {
    unsigned long long h = 1469598103934665603ULL;
    for (const unsigned char *p = (const unsigned char *)hdesk_home(); *p; p++) h = (h ^ *p) * 1099511628211ULL;
    char id[96];
    snprintf(id, sizeof id, "io.github.legatia.harness_desk.h%016llx", h);
    gapp = g_application_new(id, 0);
    g_signal_connect(gapp, "activate", G_CALLBACK(on_activate), NULL);
    GError *err = NULL;
    if (g_application_register(gapp, NULL, &err)) {
        if (g_application_get_is_remote(gapp)) {
            g_application_activate(gapp);
            return 0;
        }
    } else {
        g_clear_error(&err);
    }
    // (and without a bus: a lock in the app's own folder)
    char *dir = own_dir();
    g_mkdir_with_parents(dir, 0700);
    char *path = g_build_filename(dir, "lock", NULL);
    int fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    g_free(path);
    g_free(dir);
    if (fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) != 0 && errno == EWOULDBLOCK) return 0;
    return 1;
}

int hdesk_run(const char *user_agent) {
    // "harness-desk/0.3.0": the name and the version
    const char *slash = user_agent ? strchr(user_agent, '/') : NULL;
    agent_name = slash ? g_strndup(user_agent, (gsize)(slash - user_agent)) : g_strdup("harness-desk");
    agent_version = g_strdup(slash ? slash + 1 : "");
    if (!gtk_init_check(NULL, NULL)) {
        fprintf(stderr, "harness-desk: no display to open a window on\n");
        return 1;
    }
    if (!first_here()) return 0;
    build_window();
    g_idle_add(ready_once, NULL);
    gtk_main();
    return 0;
}

void hdesk_quit(void) {
    save_frame();
    gtk_main_quit();
}

// ---- the web view ----

void hdesk_show_html(const char *html) { webkit_web_view_load_html(web, html ? html : "", NULL); }

void hdesk_load(const char *url) { webkit_web_view_load_uri(web, url); }

void hdesk_reload(void) { webkit_web_view_reload(web); }

void hdesk_eval_js(const char *js) { webkit_web_view_evaluate_javascript(web, js, -1, NULL, NULL, NULL, NULL, NULL); }

// Only http, https and mailto get here (policy.zig).
void hdesk_open_external(const char *url) {
    if (g_ascii_strncasecmp(url, "http://", 7) != 0 && g_ascii_strncasecmp(url, "https://", 8) != 0 && g_ascii_strncasecmp(url, "mailto:", 7) != 0) return;
    gtk_show_uri_on_window(GTK_WINDOW(win), url, GDK_CURRENT_TIME, NULL);
}

// Shown without a loop of its own, so the next event doesn't land in the
// middle of the turn that asked for it.
void hdesk_alert(const char *title, const char *text) {
    GtkWidget *dlg = gtk_message_dialog_new(GTK_WINDOW(win), GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT, GTK_MESSAGE_INFO, GTK_BUTTONS_OK, "%s", title ? title : "");
    gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(dlg), "%s", text ? text : "");
    g_signal_connect(dlg, "response", G_CALLBACK(gtk_widget_destroy), NULL);
    gtk_window_present(GTK_WINDOW(win));
    gtk_widget_show(dlg);
}

struct call { void (*fn)(void *); void *arg; };

static gboolean call_once(gpointer p) {
    struct call *c = (struct call *)p;
    c->fn(c->arg);
    g_free(c);
    return G_SOURCE_REMOVE;
}

static gboolean call_again(gpointer p) {
    struct call *c = (struct call *)p;
    c->fn(c->arg);
    return G_SOURCE_CONTINUE;
}

void hdesk_post_main(void (*fn)(void *), void *arg) {
    struct call *c = g_new(struct call, 1);
    c->fn = fn;
    c->arg = arg;
    g_idle_add_full(G_PRIORITY_DEFAULT, call_once, c, NULL);
}

void hdesk_every(double seconds, void (*fn)(void *), void *arg) {
    struct call *c = g_new(struct call, 1);
    c->fn = fn;
    c->arg = arg;
    g_timeout_add((guint)(seconds * 1000.0), call_again, c);
}

// ---- the frame: x and y from the screen's top left; the size is the
// window's own, without what a window manager draws around it ----

void hdesk_window_frame(double *x, double *y, double *w, double *h) {
    int ix = 0, iy = 0, iw = 0, ih = 0;
    gtk_window_get_position(GTK_WINDOW(win), &ix, &iy);
    gtk_window_get_size(GTK_WINDOW(win), &iw, &ih);
    // (a frame asked for and not yet through the window system is the
    // window's all the same)
    if (have_frame) {
        ix = frame_x;
        iy = frame_y;
        iw = frame_w;
        ih = frame_h;
    }
    *x = ix;
    *y = iy;
    *w = iw;
    *h = ih;
}

void hdesk_set_window_frame(double x, double y, double w, double h) {
    gtk_window_unmaximize(GTK_WINDOW(win));
    gtk_window_move(GTK_WINDOW(win), (int)x, (int)y);
    gtk_window_resize(GTK_WINDOW(win), (int)w, (int)h);
    have_frame = 1;
    frame_x = (int)x;
    frame_y = (int)y;
    frame_w = (int)w;
    frame_h = (int)h;
    char *dir = own_dir();
    g_mkdir_with_parents(dir, 0700);
    char *path = g_build_filename(dir, "window-frame", NULL);
    char text[96];
    snprintf(text, sizeof text, "%d %d %d %d\n", frame_x, frame_y, frame_w, frame_h);
    g_file_set_contents(path, text, -1, NULL);
    g_free(path);
    g_free(dir);
}

void hdesk_screen_frame(double *x, double *y, double *w, double *h) {
    GdkRectangle r = { 0, 0, 1280, 800 };
    GdkDisplay *display = gdk_display_get_default();
    GdkWindow *gw = win ? gtk_widget_get_window(win) : NULL;
    GdkMonitor *m = display ? (gw ? gdk_display_get_monitor_at_window(display, gw) : gdk_display_get_primary_monitor(display)) : NULL;
    if (m) gdk_monitor_get_workarea(m, &r);
    *x = r.x;
    *y = r.y;
    *w = r.width;
    *h = r.height;
}

void hdesk_min_frame(double *w, double *h) {
    int menu_h = 0;
    if (menu_bar) gtk_widget_get_preferred_height(menu_bar, NULL, &menu_h);
    *w = MIN_W;
    *h = MIN_H + menu_h;
}
