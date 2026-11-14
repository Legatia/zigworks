// headsight's Linux layer: the camera through V4L2 (YUYV frames, memory-mapped
// buffers). The screen, windows and text recognition are macOS only for now;
// those entry points report HS_FAIL and main.zig explains before calling them.
// Same plain C interface as src/mac/capture.h.
#include "../mac/capture.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

// From src/yuv.zig.
void hs_yuyv_to_bgra(const uint8_t *src, int w, int h, int src_stride, uint8_t *dst);

static char last_device[64];

// Path of the device the last camera call opened or failed on ("" if none).
const char *hs_linux_last_device(void) { return last_device; }

int hs_host_app(char *buf, int len) { (void)buf; (void)len; return 0; }
int hs_screen_access(int request) { (void)request; return 0; }
int hs_screen_locked(void) { return 0; }
int hs_camera_access(void) { return HS_OK; } // checked when the device is opened
int hs_windows(hs_window_cb cb, void *ctx) { (void)cb; (void)ctx; return HS_FAIL; }
int hs_shot(const hs_source *src, uint8_t **px, int *w, int *h, int *stride, double *pixel_scale) {
    (void)src; (void)px; (void)w; (void)h; (void)stride; (void)pixel_scale;
    return HS_FAIL;
}
int hs_ocr(const hs_frame *f, int x, int y, int w, int h, int accurate, hs_text_cb cb, void *ctx) {
    (void)f; (void)x; (void)y; (void)w; (void)h; (void)accurate; (void)cb; (void)ctx;
    return HS_FAIL;
}
void hs_free(void *p) { free(p); }

static int xioctl(int fd, unsigned long req, void *arg) {
    int r;
    do r = ioctl(fd, req, arg);
    while (r == -1 && errno == EINTR);
    return r;
}

static long long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static int has_yuyv(int fd) {
    struct v4l2_fmtdesc d;
    memset(&d, 0, sizeof d);
    d.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    for (d.index = 0; xioctl(fd, VIDIOC_ENUM_FMT, &d) == 0; d.index++)
        if (d.pixelformat == V4L2_PIX_FMT_YUYV) return 1;
    return 0;
}

// Fastest frame rate the camera offers for YUYV at w x h (0 if unknown).
static double max_fps(int fd, unsigned w, unsigned h) {
    struct v4l2_frmivalenum iv;
    memset(&iv, 0, sizeof iv);
    iv.pixel_format = V4L2_PIX_FMT_YUYV;
    iv.width = w;
    iv.height = h;
    double best = 0;
    for (iv.index = 0; xioctl(fd, VIDIOC_ENUM_FRAMEINTERVALS, &iv) == 0; iv.index++) {
        const struct v4l2_fract *f = iv.type == V4L2_FRMIVAL_TYPE_DISCRETE ? &iv.discrete : &iv.stepwise.min;
        if (f->numerator) {
            double fps = (double)f->denominator / f->numerator;
            if (fps > best) best = fps;
        }
        if (iv.type != V4L2_FRMIVAL_TYPE_DISCRETE) break;
    }
    return best;
}

// The largest YUYV size up to 1280x720 that runs at 15 fps or more, so warm-up
// (counted in frames) stays short. USB2 webcams often give 1280x720 only at
// 5-10 fps but 640x480 at 30. Falls back to asking for 1280x720.
static void pick_size(int fd, unsigned *w, unsigned *h) {
    *w = 1280;
    *h = 720;
    struct v4l2_frmsizeenum s;
    memset(&s, 0, sizeof s);
    s.pixel_format = V4L2_PIX_FMT_YUYV;
    unsigned bw = 0, bh = 0;
    for (s.index = 0; xioctl(fd, VIDIOC_ENUM_FRAMESIZES, &s) == 0; s.index++) {
        if (s.type != V4L2_FRMSIZE_TYPE_DISCRETE) return; // stepwise: the driver adjusts 1280x720
        unsigned cw = s.discrete.width, ch = s.discrete.height;
        if (cw > 1280 || ch > 720 || (unsigned long)cw * ch <= (unsigned long)bw * bh) continue;
        double fps = max_fps(fd, cw, ch);
        if (fps == 0 || fps >= 15) { bw = cw; bh = ch; }
    }
    if (bw) { *w = bw; *h = bh; }
}

// Opens a video capture device. name: NULL for the first camera, a /dev path,
// or text matched (case-insensitive) against the device's card name.
// Returns the fd, or -HS_NOT_FOUND / -HS_PERMISSION.
static int open_camera(const char *name) {
    int denied = 0;
    last_device[0] = 0;
    if (name && strncmp(name, "/dev/", 5) == 0) {
        snprintf(last_device, sizeof last_device, "%s", name);
        int fd = open(name, O_RDWR | O_NONBLOCK);
        if (fd < 0) return errno == EACCES ? -HS_PERMISSION : -HS_NOT_FOUND;
        return fd;
    }
    for (int i = 0; i < 64; i++) {
        char path[32];
        snprintf(path, sizeof path, "/dev/video%d", i);
        int fd = open(path, O_RDWR | O_NONBLOCK);
        if (fd < 0) {
            if (errno == EACCES && !denied) {
                denied = 1;
                snprintf(last_device, sizeof last_device, "%s", path);
            }
            continue;
        }
        struct v4l2_capability cap;
        memset(&cap, 0, sizeof cap);
        unsigned caps = 0;
        if (xioctl(fd, VIDIOC_QUERYCAP, &cap) == 0)
            caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS) ? cap.device_caps : cap.capabilities;
        int ok = (caps & V4L2_CAP_VIDEO_CAPTURE) && (caps & V4L2_CAP_STREAMING);
        // the first camera means the first one headsight can read (skips IR and raw sensor nodes)
        if (ok && !(name && *name)) ok = has_yuyv(fd);
        if (ok && name && *name) {
            // strcasestr is a GNU extension; compare by hand.
            const char *card = (const char *)cap.card;
            size_t n = strlen(name);
            ok = 0;
            for (const char *p = card; *p && !ok; p++) ok = strncasecmp(p, name, n) == 0;
        }
        if (ok) {
            snprintf(last_device, sizeof last_device, "%s", path);
            return fd;
        }
        close(fd);
    }
    return denied ? -HS_PERMISSION : -HS_NOT_FOUND;
}

struct mapped { void *start; size_t len; };

int hs_stream(const hs_source *src, int timeout_ms, hs_frame_cb cb, void *ctx) {
    if (src->kind != 2) return HS_FAIL;
    int fd = open_camera(src->camera_name);
    if (fd < 0) return -fd;

    int rc = HS_FAIL;
    struct mapped bufs[4];
    unsigned nbufs = 0;
    uint8_t *bgra = NULL;
    int streaming = 0;
    int w = 0, h = 0, stride = 0;
    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;

    struct v4l2_format fmt;
    memset(&fmt, 0, sizeof fmt);
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    pick_size(fd, &fmt.fmt.pix.width, &fmt.fmt.pix.height);
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        if (errno == EBUSY) {
            fprintf(stderr, "headsight: %s is in use by another program; close it and try again\n", last_device);
            goto done;
        }
        if (xioctl(fd, VIDIOC_G_FMT, &fmt) < 0) {
            fprintf(stderr, "headsight: %s: can't set a picture format (%s)\n", last_device, strerror(errno));
            goto done;
        }
    }
    if (fmt.fmt.pix.pixelformat != V4L2_PIX_FMT_YUYV) {
        unsigned f = fmt.fmt.pix.pixelformat;
        fprintf(stderr, "headsight: %s offers %c%c%c%c, not YUYV; only YUYV cameras work on Linux so far\n",
                last_device, f & 0xff, (f >> 8) & 0xff, (f >> 16) & 0xff, (f >> 24) & 0xff);
        goto done;
    }
    w = (int)fmt.fmt.pix.width;
    h = (int)fmt.fmt.pix.height;
    stride = fmt.fmt.pix.bytesperline ? (int)fmt.fmt.pix.bytesperline : w * 2;

    struct v4l2_streamparm parm;
    memset(&parm, 0, sizeof parm);
    parm.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    parm.parm.capture.timeperframe.numerator = 1;
    parm.parm.capture.timeperframe.denominator = src->fps > 0 ? (unsigned)src->fps : 30;
    xioctl(fd, VIDIOC_S_PARM, &parm); // a hint; drivers may ignore it

    struct v4l2_requestbuffers req;
    memset(&req, 0, sizeof req);
    req.count = 4;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0 || req.count < 2) {
        if (errno == EBUSY) fprintf(stderr, "headsight: %s is in use by another program; close it and try again\n", last_device);
        else fprintf(stderr, "headsight: %s: no capture buffers (%s)\n", last_device, strerror(errno));
        goto done;
    }
    for (unsigned i = 0; i < req.count && i < 4; i++) {
        struct v4l2_buffer b;
        memset(&b, 0, sizeof b);
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        b.memory = V4L2_MEMORY_MMAP;
        b.index = i;
        if (xioctl(fd, VIDIOC_QUERYBUF, &b) < 0) goto done;
        void *p = mmap(NULL, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, b.m.offset);
        if (p == MAP_FAILED) goto done;
        bufs[nbufs].start = p;
        bufs[nbufs].len = b.length;
        nbufs++;
        if (xioctl(fd, VIDIOC_QBUF, &b) < 0) goto done;
    }
    if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
        if (errno == ENOSPC)
            fprintf(stderr, "headsight: %s: not enough USB bandwidth; another camera on the same USB port or hub may be running\n", last_device);
        else if (errno == EBUSY)
            fprintf(stderr, "headsight: %s is in use by another program; close it and try again\n", last_device);
        else
            fprintf(stderr, "headsight: %s: can't start (%s)\n", last_device, strerror(errno));
        goto done;
    }
    streaming = 1;
    bgra = malloc((size_t)w * h * 4);
    if (!bgra) goto done;

    long long deadline = now_ms() + timeout_ms;
    for (;;) {
        long long left = deadline - now_ms();
        if (left <= 0) { rc = HS_TIMEOUT; break; }
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        int pr = poll(&pfd, 1, left < 100 ? (int)left : 100);
        if (pr < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (pr == 0) { // idle tick, so "still" and timeouts work without frames
            if (cb(ctx, NULL)) { rc = HS_OK; break; }
            continue;
        }
        if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) { rc = HS_GONE; break; }
        struct v4l2_buffer b;
        memset(&b, 0, sizeof b);
        b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        b.memory = V4L2_MEMORY_MMAP;
        if (xioctl(fd, VIDIOC_DQBUF, &b) < 0) {
            if (errno == EAGAIN) continue;
            rc = errno == ENODEV ? HS_GONE : HS_FAIL;
            break;
        }
        int stop = 0;
        // skip frames the driver marks as damaged (uvcvideo passes them on)
        if (b.index < nbufs && !(b.flags & V4L2_BUF_FLAG_ERROR) && b.bytesused >= (unsigned)(stride * (h - 1) + w * 2)) {
            hs_yuyv_to_bgra(bufs[b.index].start, w, h, stride, bgra);
            hs_frame f = { bgra, w, h, w * 4, 1.0f };
            stop = cb(ctx, &f);
        }
        if (xioctl(fd, VIDIOC_QBUF, &b) < 0 && !stop) { rc = errno == ENODEV ? HS_GONE : HS_FAIL; break; }
        if (stop) { rc = HS_OK; break; }
    }

done:
    if (streaming) xioctl(fd, VIDIOC_STREAMOFF, &type);
    for (unsigned i = 0; i < nbufs; i++) munmap(bufs[i].start, bufs[i].len);
    free(bgra);
    close(fd);
    return rc;
}
