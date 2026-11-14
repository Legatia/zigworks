#!/bin/sh
# Live check of the Linux camera path against virtual cameras: v4l2loopback
# fed by ffmpeg (a still picture, then motion that stops) and, if present, the
# kernel's vivid test camera. Needs read/write access to the devices (video group).
#
# Setup (Ubuntu): sudo apt install v4l2loopback-dkms linux-modules-extra-$(uname -r) ffmpeg
#                 sudo modprobe v4l2loopback video_nr=10 card_label="Loop Cam" exclusive_caps=1
#                 sudo modprobe vivid n_devs=1        (optional)
# usage: scripts/live-linux.sh [path/to/headsight] [loopback device]
set -u
cd "$(dirname "$0")/.."
HS=${1:-zig-out/bin/headsight}
case $HS in /*) ;; *) HS=$(pwd)/$HS ;; esac
DEV=${2:-/dev/video10}
TMP=$(mktemp -d)
FEED=

feed() {
    stop_feed
    ffmpeg -nostdin -loglevel error -re "$@" -pix_fmt yuyv422 -f v4l2 "$DEV" >/dev/null 2>&1 &
    FEED=$!
    sleep 1.5
}
stop_feed() { [ -n "$FEED" ] && kill "$FEED" 2>/dev/null; [ -n "$FEED" ] && wait "$FEED" 2>/dev/null; FEED=; }
fail() { echo "FAIL: $*" >&2; stop_feed; exit 1; }
ms() { date +%s%3N; }
cleanup() { stop_feed; rm -rf "$TMP"; "$HS" drop lbase >/dev/null 2>&1; }
trap cleanup EXIT

# run <want exit> <text> -- args
run() {
    want=$1; text=$2; shift 3
    t0=$(ms)
    out=$("$HS" "$@" 2>&1); got=$?
    t1=$(ms)
    [ "$got" = "$want" ] || fail "headsight $*: exit $got, want $want; output: $out"
    case $out in *"$text"*) ;; *) fail "headsight $*: output lacks '$text': $out" ;; esac
    echo "ok - headsight $* ($((t1 - t0)) ms)"
    echo "$out" | sed 's/^/     /' | head -3
}

command -v ffmpeg >/dev/null || fail "ffmpeg is not installed"
[ -e "$DEV" ] || fail "$DEV missing; load v4l2loopback (see the top of this script)"
ffmpeg -nostdin -loglevel error -y -f lavfi -i "testsrc2=size=1280x720:rate=1" -frames:v 1 "$TMP/still.png" || fail "ffmpeg"

# what needs macOS says so
run 4 "only be captured on macOS" -- snap
run 4 "only be captured on macOS" -- windows
run 4 "text recognition only works on macOS" -- text --camera Loop
run 4 "text recognition only works on macOS" -- wait --text Done --camera Loop

# a still picture
feed -loop 1 -framerate 30 -i "$TMP/still.png"
run 0 "snap source=camera size=1280x720" -- snap --camera Loop --name lbase
run 1 "timeout after=" -- wait --change --camera Loop --timeout 4
run 0 "still after=" -- wait --still --camera Loop --timeout 10
run 0 "\"event\":\"still\"" -- wait --still --camera "$DEV" --json --timeout 10

# motion for 3 s, then the last frame held
feed -f lavfi -i "testsrc2=size=1280x720:rate=30,trim=duration=3,tpad=stop_mode=clone:stop_duration=120"
run 0 "changed after=" -- wait --change --since lbase --timeout 5
run 0 "still after=" -- wait --still --camera Loop --timeout 15
run 0 "boxes=" -- diff --since lbase
stop_feed

# no such camera; a reference that's gone
run 4 "no camera matches" -- snap --camera nosuchcamera
run 0 "dropped lbase" -- drop lbase

# the kernel's test camera, by path, if loaded (its clock overlay changes every frame)
VIVID=$(for d in /dev/video*; do v4l2-ctl -d "$d" --info 2>/dev/null | grep -q "Card type *: vivid" && { echo "$d"; break; }; done)
if [ -n "$VIVID" ]; then
    run 0 "changed after=" -- wait --change --camera "$VIVID" --timeout 5
    # the size picked runs at 15 fps or more (vivid offers several sizes)
    run 0 "snap source=camera" -- snap --source camera
    # a camera another program holds is reported as in use, not as unsupported
    # (vivid, like a real webcam, has one reader at a time; v4l2loopback allows many)
    "$HS" wait --change --camera "$VIVID" --region 0,600,10,10 --timeout 6 >/dev/null 2>&1 &
    HOLD=$!
    sleep 1.5
    run 4 "in use by another program" -- snap --camera "$VIVID"
    wait "$HOLD" 2>/dev/null
else
    echo "skip - vivid not loaded"
fi
echo "live-linux: all ok"
