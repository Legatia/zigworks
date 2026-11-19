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

export HEADDESK_BOXES=$WORK/boxes
BOX=box-$$

cleanup() {
    "$HD" kill "$D" >/dev/null 2>&1
    "$HD" kill "$D-2" >/dev/null 2>&1
    "$HD" kill "$D-b" >/dev/null 2>&1
    "$HD" kill "$D-r" >/dev/null 2>&1
    "$HD" kill "$D-f1" >/dev/null 2>&1
    "$HD" kill "$D-f2" >/dev/null 2>&1
    "$HD" box delete "$BOX" >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

# One failed check: counted, printed, and on GitHub also shown as an
# annotation on the run (the first 600 characters, on one line).
failed() {
    FAILS=$((FAILS + 1))
    echo "FAIL: $*" >&2
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::error::$(printf '%s' "$*" | xargs | cut -c1-600)"
    fi
}

# expect CODE 'text the output must hold' -- headdesk arguments...
expect() {
    want=$1
    text=$2
    shift 3
    out=$("$HD" "$@" 2>&1)
    code=$?
    if [ "$code" != "$want" ]; then
        failed "headdesk $*: exit $code, expected $want: $out"
        return
    fi
    case $out in
    *"$text"*) echo "ok - headdesk $*" ;;
    *)
        failed "headdesk $*: output lacks '$text': $out"
        ;;
    esac
}

# await 'text' -- headdesk arguments...: runs the command again and again
# until its output holds the text, 20 s at most. For what a program in a
# box does in its own time: making a box takes a slow machine a second.
await() {
    text=$1
    shift 2
    tries=0
    while [ "$tries" -lt 200 ]; do
        case $("$HD" "$@" 2>&1) in *"$text"*) return 0 ;; esac
        tries=$((tries + 1))
        sleep 0.1
    done
    return 1
}

# lacks 'text the output must not hold' -- headdesk arguments...
lacks() {
    text=$1
    shift 2
    out=$("$HD" "$@" 2>&1)
    case $out in
    *"$text"*)
        failed "headdesk $*: output holds '$text': $out"
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
    failed "the shot is not a PNG file"
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
    failed "a step let $((after - before)) frames through, expected 1"
fi
expect 2 "frozen desktop" -- step "$D"
expect 0 "running" -- thaw "$D-2"
sleep 0.3
later=$("$HD" output "$D-2" | grep -c '^frame ')
if [ "$later" -gt $((after + 3)) ]; then echo "ok - thawed, frames run again"; else
    failed "after thaw only $((later - after)) frames"
fi

# a recording: the log, the inputs, a picture per change, and a page; then the same inputs again
expect 0 "started $D-r" -- start "$D-r" --size 320x200 -- "$TC" recorded
expect 0 "settled" -- wait "$D-r" --windows 1
expect 2 "nothing is being recorded" -- record "$D-r" --stop
expect 0 "recording dir=$WORK/rec fps=20" -- record "$D-r" "$WORK/rec" --fps 20
expect 2 "already running" -- record "$D-r" "$WORK/rec2"
expect 0 "window=1" -- click "$D-r" 50 40
expect 0 "windows=2" -- wait "$D-r" --windows 2
expect 0 "window=2" -- click "$D-r" 40 40 --window 2
expect 0 "windows=1" -- wait "$D-r"
expect 0 "" -- key "$D-r" a ctrl+s
expect 0 "" -- type "$D-r" 'Hi'
expect 0 "settled" -- wait "$D-r"
expect 0 "inputs=4 dir=$WORK/rec" -- record "$D-r" --stop
if [ "$(wc -l <"$WORK/rec/inputs.txt")" = 4 ] && [ -s "$WORK/rec/frames/000003.png" ] && grep -q "20,60,120x80" "$WORK/rec/frames.txt" && grep -q "button left down" "$WORK/rec/events.txt" && grep -q "frames/" "$WORK/rec/index.html"; then echo "ok - the recording has its inputs, pictures, log and page"; else
    failed "the recording is incomplete: $(ls "$WORK/rec" "$WORK/rec/frames" | xargs) $(cat "$WORK/rec/frames.txt" | xargs)"
fi
expect 0 "" -- kill "$D-r"
expect 0 "started $D-r" -- start "$D-r" --size 320x200 -- "$TC" again
expect 0 "settled" -- wait "$D-r" --windows 1
expect 0 "replayed inputs=4 picture=same" -- replay "$D-r" "$WORK/rec" --settle
expect 0 "" -- kill "$D-r"
# a desktop that is not as the recording's was ends up looking different
expect 0 "started $D-r" -- start "$D-r" --size 320x200 -- "$TC" other
expect 0 "settled" -- wait "$D-r" --windows 1
expect 0 "" -- key "$D-r" z
expect 1 "replayed inputs=4 picture=differs" -- replay "$D-r" "$WORK/rec" --settle
expect 0 "" -- kill "$D-r"
expect 2 "the recording is of a 320x200 desktop" -- replay "$D" "$WORK/rec"
expect 2 "no recording in" -- replay "$D" "$WORK/norec"

# frozen from the start: frames come only by steps, each 16 ms later on the apps' clock,
# so two runs of the same steps look the same whatever the real time between them
for run in 1 2; do
    expect 0 "started $D-f$run" -- start "$D-f$run" --frozen --size 320x200 -- "$TC" --frames
    expect 0 "settled" -- wait "$D-f$run" --windows 1 --idle 150
    expect 0 "frozen" -- status "$D-f$run"
    lacks "frame 1" -- output "$D-f$run"
    [ "$run" = 2 ] && sleep 0.4
    expect 0 "frames=5 quiet=no" -- step "$D-f$run" 5 --until-quiet
    "$HD" wait "$D-f$run" --idle 150 >/dev/null
    expect 0 "frame 5 +16" -- output "$D-f$run"
    lacks "frame 6" -- output "$D-f$run"
    expect 0 "clock=80ms" -- status "$D-f$run"
done
first=$("$HD" hash "$D-f1")
second=$("$HD" hash "$D-f2")
if [ -n "$first" ] && [ "$first" = "$second" ]; then echo "ok - two frozen runs of five frames look the same ($first)"; else
    failed "two frozen runs differ: $first and $second"
fi
expect 0 "frames=3 quiet=no" -- step "$D-f1" 3 --until-quiet
"$HD" wait "$D-f1" --idle 150 >/dev/null
third=$("$HD" hash "$D-f1")
if [ "$third" != "$first" ]; then echo "ok - three frames more look different"; else
    failed "the picture did not change after three more frames"
fi
expect 0 "" -- kill "$D-f1"
expect 0 "" -- kill "$D-f2"
# an app that asks for no frames is quiet at once, and the recording replays frozen
expect 0 "started $D-f1" -- start "$D-f1" --frozen --size 320x200 -- "$TC" frozen
expect 0 "settled" -- wait "$D-f1" --windows 1 --idle 150
expect 0 "frames=0 quiet=yes" -- step "$D-f1" --until-quiet
expect 0 "replayed inputs=4 picture=same" -- replay "$D-f1" "$WORK/rec" --frozen
expect 0 "frozen" -- status "$D-f1"
expect 2 "choose one" -- replay "$D-f1" "$WORK/rec" --frozen --settle
expect 0 "" -- kill "$D-f1"

# names instead of pixels need an app that describes itself; the test client does not
expect 2 "accessibility bus" -- tree "$D"
expect 2 "accessibility bus" -- click "$D" --name Save
expect 2 "accessibility bus" -- find "$D" Save

# boxes: apps that read the system but write only into a box
expect 2 "go with --sandbox" -- start "$D-b" --no-network -- "$TC"
expect 4 "no box named" -- box diff nosuchbox
expect 2 "needs list, diff" -- box
if why=$("$HD" check 2>&1); then
    marker=headdesk-smoke-$$
    echo secret >"$WORK/secret"
    mkdir "$WORK/shared"
    expect 0 "box=$BOX" -- start "$D-b" --sandbox --box "$BOX" --as-root --size 320x200 --share-ro "$(dirname "$TC")" --share "$WORK/shared" -- "$TC" boxed
    expect 0 "settled" -- wait "$D-b" --windows 1
    expect 0 'title="boxed"' -- windows "$D-b"
    expect 0 "sandbox box=$BOX network=yes user=root shared=2" -- status "$D-b"
    expect 2 "already open" -- start "$D-b2" --sandbox --box "$BOX" -- "$TC"
    expect 2 "is open in a desktop" -- box snapshot "$BOX" early
    expect 0 "$BOX snapshots=0 open" -- box list
    # a second program joins the box: it is root there, writes to the system and its home, and sees none of ours
    expect 0 "pid=" -- exec "$D-b" -- sh -c "echo \"id=\$(id -u) home=\$HOME procs=\$(ls /proc | grep -c '^[0-9]')\"; touch /etc/$marker; echo one >\$HOME/one; cat $WORK/secret 2>/dev/null || echo cannot-read-secret; echo out >$WORK/shared/from-box"
    await "cannot-read-secret" -- output "$D-b"
    expect 0 "id=0 home=/root procs=" -- output "$D-b"
    expect 0 "cannot-read-secret" -- output "$D-b"
    expect 0 "" -- kill "$D-b"
    sleep 0.3
    if [ ! -e "/etc/$marker" ] && [ "$(cat "$WORK/shared/from-box" 2>/dev/null)" = out ]; then echo "ok - the system is untouched and the shared directory was written"; else
        failed "/etc/$marker exists on the system, or the shared directory was not written"
    fi
    expect 0 "added   /etc/$marker" -- box diff "$BOX"
    expect 0 "added   /root/one" -- box diff "$BOX"

    # snapshots: keep, go on, go back
    expect 0 "" -- box snapshot "$BOX" first
    expect 2 "already has a snapshot" -- box snapshot "$BOX" first
    expect 0 "0 changed" -- box diff "$BOX"
    expect 0 "snapshot first" -- box snapshots "$BOX"
    expect 0 "box=$BOX" -- start "$D-b" --sandbox --box "$BOX" --as-root --no-network --size 320x200 -- sh -c "ls \$HOME; ls /etc/$marker; rm \$HOME/one; echo two >\$HOME/two; echo links: \$(ls /sys/class/net | xargs); sleep 0.3"
    await "exited=0" -- status "$D-b"
    expect 0 "/etc/$marker" -- output "$D-b"
    expect 0 "links: lo" -- output "$D-b"
    expect 0 "network=no" -- status "$D-b"
    expect 0 "exited=0" -- status "$D-b"
    expect 0 "" -- kill "$D-b"
    sleep 0.3
    expect 0 "deleted /root/one" -- box diff "$BOX"
    expect 0 "added   /root/two" -- box diff "$BOX"
    expect 2 "no snapshot with that label" -- box restore "$BOX" nosuch
    expect 0 "" -- box restore "$BOX" first
    expect 0 "0 changed" -- box diff "$BOX"
    expect 0 "$BOX snapshots=1 closed" -- box list
    expect 0 "" -- box reset "$BOX"
    lacks "snapshot" -- box snapshots "$BOX"
    expect 0 "" -- box delete "$BOX"
    lacks "$BOX" -- box list
else
    echo "skip - no boxes on this system: $why"
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
