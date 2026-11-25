// harness-desk's macOS layer: the Cocoa app, its window and menu, and the
// WKWebView with its delegates. Every decision is made in Zig (main.zig):
// this file asks through the hdesk_on_* callbacks and does what it's told.
// Everything here runs on the main thread, except hdesk_post_main.
#pragma once

enum { HDESK_ALLOW = 0, HDESK_EXTERNAL = 1, HDESK_CANCEL = 2 };
enum { HDESK_FRAME_MAIN = 0, HDESK_FRAME_SUB = 1, HDESK_FRAME_NEW_WINDOW = 2 };
enum { HDESK_MEDIA_MIC = 0, HDESK_MEDIA_CAMERA = 1, HDESK_MEDIA_BOTH = 2 };
enum { HDESK_MENU_START = 0, HDESK_MENU_STOP = 1, HDESK_MENU_AUTOSTART = 2, HDESK_MENU_RELOAD = 3 };

// Runs the app; returns only if it couldn't start. `user_agent` is added to
// the web view's user agent ("harness-desk/0.3.0").
int hdesk_run(const char *user_agent);
void hdesk_quit(void);

// The web view.
void hdesk_show_html(const char *html);
void hdesk_load(const char *url);
void hdesk_reload(void);
void hdesk_eval_js(const char *js);

// The Dock: the badge ("" clears it) and one bounce.
void hdesk_badge(const char *label);
// The badge as the Dock tile has it, into buf ("" when none).
void hdesk_badge_label(char *buf, int len);
void hdesk_attention(void);

// The system browser (or mail app) for a link that isn't the desk's.
void hdesk_open_external(const char *url);

// The menu: which items work, and Open at login's check mark
// (autostart_on: 1 on, 0 off, -1 not known).
void hdesk_menu_state(int start, int stop, int autostart_enabled, int autostart_on);

// A sheet on the window with one OK button.
void hdesk_alert(const char *title, const char *text);

// Calls fn(arg) on the main thread, soon; safe from any thread.
void hdesk_post_main(void (*fn)(void *), void *arg);
// Calls fn(arg) on the main thread every `seconds`, also while a menu is open.
void hdesk_every(double seconds, void (*fn)(void *), void *arg);

// The window's frame on screen (x, y from the bottom left), and setting it.
void hdesk_window_frame(double *x, double *y, double *w, double *h);
void hdesk_set_window_frame(double x, double y, double w, double h);
// The visible part of the window's screen (without the menu bar and the
// Dock), and the smallest frame the window takes.
void hdesk_screen_frame(double *x, double *y, double *w, double *h);
void hdesk_min_frame(double *w, double *h);

// Exported by Zig.
void hdesk_on_ready(void);
void hdesk_on_message(const char *json, int main_frame, const char *proto, const char *host, int port);
int hdesk_on_navigate(const char *url, int frame);
void hdesk_on_response(const char *url, int status, int main_frame);
void hdesk_on_finish(const char *url);
void hdesk_on_failed(const char *url, int code);
int hdesk_on_media(const char *proto, const char *host, int port, int main_frame, int kind);
void hdesk_on_menu(int item);
void hdesk_on_crashed(void);
