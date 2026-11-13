// headsight's Apple layer: screen and window capture (ScreenCaptureKit),
// camera (AVFoundation), text recognition (Vision), PNG files (ImageIO) and
// permission checks. Plain C interface, used from Zig.
#pragma once
#include <stdint.h>

enum { HS_OK = 0, HS_TIMEOUT = 1, HS_PERMISSION = 3, HS_FAIL = 4, HS_GONE = 5, HS_NO_HOST = 6, HS_NOT_FOUND = 8 };

typedef struct { const uint8_t *px; int w, h, stride; float scale; } hs_frame; // BGRA; scale: pixels per point
typedef struct { int kind; uint32_t window_id; const char *camera_name; int fps; } hs_source; // kind: 0 display, 1 window, 2 camera

int hs_host_app(char *buf, int len);   // 1: name of the app that started us; 0: none (ssh, launchd)
int hs_screen_access(int request);     // 1 granted; request=1 asks macOS to list the host app
int hs_screen_locked(void);            // 1 while the login screen is up: windows are not redrawn
int hs_camera_access(void);            // HS_OK, HS_PERMISSION, HS_NO_HOST

typedef void (*hs_window_cb)(void *ctx, uint32_t id, const char *app, const char *title, int x, int y, int w, int h);
int hs_windows(hs_window_cb cb, void *ctx);   // on-screen app windows, front to back, pixel sizes

int hs_shot(const hs_source *src, uint8_t **px, int *w, int *h, int *stride, double *pixel_scale); // display or window; free px with hs_free

typedef int (*hs_frame_cb)(void *ctx, const hs_frame *f);   // f NULL: idle tick; return 1 to stop
int hs_stream(const hs_source *src, int timeout_ms, hs_frame_cb cb, void *ctx); // HS_OK (cb stopped), HS_TIMEOUT, HS_GONE, errors

typedef void (*hs_text_cb)(void *ctx, const char *text, float conf, int x, int y, int w, int h);
int hs_ocr(const hs_frame *f, int x, int y, int w, int h, int accurate, hs_text_cb cb, void *ctx);

int hs_write_png(const char *path, const hs_frame *f, int x, int y, int w, int h, int max_side, double *scale_out);
void hs_free(void *p);

uint8_t *hs_test_render_text(int w, int h, const char *text); // tests only: black text on white, BGRA, free with hs_free
