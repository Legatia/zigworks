#!/bin/sh
# End-to-end test: a desktop with the test client in it, driven through
# the command line. usage: smoke.sh [headdesk] [headdesk-testclient]
set -u
HD=${1:-zig-out/bin/headdesk}
TC=${2:-zig-out/bin/headdesk-testclient}
case $HD in /*) ;; *) HD=$PWD/$HD ;; esac
case $TC in /*) ;; *) TC=$PWD/$TC ;; esac

WORK=$(mktemp -d /tmp/hd-smoke.XXXXXX)
export HEADDESK_DIR=$WORK/d
D=smoke-$$
FAILS=0

cleanup() {
    "$HD" kill "$D" >/dev/null 2>&1
    "$HD" kill "$D-2" >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

# expect CODE 'text the output must hold' -- headdesk arguments...
expect() {
    want=$1
    text=$2
    shift 3
    out=$("$HD" "$@" 2>&1)
    code=$?
    if [ "$code" != "$want" ]; then
        echo "FAIL: headdesk $*: exit $code, expected $want: $out" >&2
        FAILS=$((FAILS + 1))
        return
    fi
    case $out in
    *"$text"*) echo "ok - headdesk $*" ;;
    *)
        echo "FAIL: headdesk $*: output lacks '$text': $out" >&2
        FAILS=$((FAILS + 1))
        ;;
    esac
}

# lacks 'text the output must not hold' -- headdesk arguments...
lacks() {
    text=$1
    shift 2
    out=$("$HD" "$@" 2>&1)
    case $out in
    *"$text"*)
        echo "FAIL: headdesk $*: output holds '$text': $out" >&2
        FAILS=$((FAILS + 1))
        ;;
    *) echo "ok - headdesk $* (without '$text')" ;;
    esac
}

expect 0 "usage: headdesk" -- help
expect 0 "headdesk 0." -- version
expect 2 "usage: headdesk" --
expect 2 "unknown command" -- frobnicate
expect 4 "no desktop named" -- windows nosuchdesk
expect 2 "name is 1 to 32" -- windows 'bad/name'
expect 2 "needs a program" -- start "$D"
expect 2 "WIDTHxHEIGHT" -- start "$D" --size big -- "$TC"

# a desktop, and the window the test client opens
expect 0 "started $D pid=" -- start "$D" --size 640x400 -- "$TC" "first window"
expect 2 "already running" -- start "$D" -- "$TC"
expect 0 "settled" -- wait "$D" --windows 1
expect 0 'window 1 toplevel at=0,0 size=640x400 keyboard app=headdesk.testclient title="first window"' -- windows "$D"
expect 0 "$D size=640x400 windows=1 clients=1 running" -- status "$D"
expect 0 "$D size=640x400" -- list
expect 0 "configure 640x400" -- output "$D"
expect 0 "keymap format 1" -- output "$D"
lacks "unknown" -- status "$D"

# pictures
expect 0 "size=640x400" -- shot "$D" "$WORK/desk.png"
expect 0 "size=640x400" -- shot "$D" "$WORK/win.png" --window 1
expect 2 "no window 9" -- shot "$D" "$WORK/x.png" --window 9
if [ "$(head -c 4 "$WORK/desk.png" | tail -c 3)" = PNG ]; then echo "ok - the shot is a PNG file"; else
    echo "FAIL: the shot is not a PNG file" >&2
    FAILS=$((FAILS + 1))
fi

# a click on the button opens a menu: a second window, placed under the button
expect 0 "at=50,40 window=1" -- click "$D" 50 40
expect 0 "windows=2 changed=20,60,120x80" -- wait "$D" --windows 2
expect 0 "window 2 popup at=20,60 size=120x80 parent=1 keyboard" -- windows "$D"
expect 0 "popup configure 20,60 120x80" -- output "$D"
expect 0 "size=120x80" -- shot "$D" "$WORK/menu.png" --window 2

# a click in the menu, by the menu's own coordinates: it closes and the button changes
expect 0 "at=60,100 window=2" -- click "$D" 40 40 --window 2
expect 0 "windows=1 changed=20,20,120x120" -- wait "$D"
lacks "window 2" -- windows "$D"
expect 0 "enter popup 40,40" -- output "$D"

# a click outside every window of the app that holds a menu open closes the menu
expect 0 "window=1" -- click "$D" 50 40
expect 0 "windows=2" -- wait "$D" --windows 2
expect 0 "window=1" -- click "$D" 400 300
expect 0 "windows=1" -- wait "$D"
expect 0 "popup closed" -- output "$D"

# keys and text
expect 0 "" -- key "$D" a
expect 0 "changed=0,0,10x6" -- wait "$D"
expect 0 "key 30 down" -- output "$D"
expect 0 "" -- key "$D" ctrl+s Return
expect 0 "modifiers 4" -- output "$D"
expect 0 "key 28 down" -- output "$D"
expect 0 "" -- type "$D" 'Hi!'
expect 0 "modifiers 1" -- output "$D"
expect 0 "key 35 down" -- output "$D"
expect 2 "no such key" -- key "$D" nosuchkey
expect 2 "only ASCII" -- type "$D" 'é'
expect 0 "" -- scroll "$D" 3
expect 0 "settled" -- wait "$D"
expect 0 "scroll axis 0 by 45" -- output "$D"

# nothing happens: the wait says so, and a wait for a window that never comes times out
expect 0 "changed=none" -- wait "$D" --idle 100
expect 1 "timeout" -- wait "$D" --windows 5 --idle 50 --timeout 300
expect 2 "off the desktop" -- click "$D" 5000 5

# the log holds input and drawing in order
expect 0 "button left down" -- log "$D"
expect 0 "window 2 opens: popup" -- log "$D"
expect 0 "draw window 1" -- log "$D"
expect 0 "key ctrl+s" -- log "$D"

# a second program on the same desktop: its window goes in front, a click on the first brings that back
expect 0 "pid=" -- exec "$D" -- "$TC" "second window"
expect 0 "windows=2" -- wait "$D" --windows 2
expect 0 'title="second window"' -- windows "$D"
expect 0 "clients=2" -- status "$D"
expect 0 "" -- focus "$D" 1
expect 0 'window 1 toplevel at=0,0 size=640x400 keyboard' -- windows "$D"
expect 0 "" -- close "$D" 1
expect 0 "settled" -- wait "$D" --idle 200
lacks 'title="first window"' -- windows "$D"
expect 0 "exited=0" -- status "$D"

# freezing: an app that draws on every frame stops, one step lets one frame through
expect 0 "started $D-2" -- start "$D-2" --size 320x200 -- "$TC" --frames
# (while it draws all the time, a wait never finds it settled)
expect 1 "timeout" -- wait "$D-2" --windows 1 --idle 100 --timeout 500
expect 0 "frozen" -- freeze "$D-2"
"$HD" wait "$D-2" --idle 150 >/dev/null
before=$("$HD" output "$D-2" | grep -c '^frame ')
expect 0 "changed=none" -- wait "$D-2" --idle 200
expect 0 "1 waiting=yes" -- step "$D-2"
"$HD" wait "$D-2" --idle 150 >/dev/null
after=$("$HD" output "$D-2" | grep -c '^frame ')
if [ "$after" = $((before + 1)) ]; then echo "ok - one step, one frame ($before to $after)"; else
    echo "FAIL: a step let $((after - before)) frames through, expected 1" >&2
    FAILS=$((FAILS + 1))
fi
expect 2 "frozen desktop" -- step "$D"
expect 0 "running" -- thaw "$D-2"
sleep 0.3
later=$("$HD" output "$D-2" | grep -c '^frame ')
if [ "$later" -gt $((after + 3)) ]; then echo "ok - thawed, frames run again"; else
    echo "FAIL: after thaw only $((later - after)) frames" >&2
    FAILS=$((FAILS + 1))
fi

# the end
expect 0 "" -- kill "$D-2"
expect 0 "" -- kill "$D"
sleep 0.3
expect 4 "no desktop named" -- status "$D"
lacks "$D" -- list

if [ "$FAILS" != 0 ]; then
    echo "$FAILS smoke test(s) failed" >&2
    exit 1
fi
echo "all smoke tests passed"
