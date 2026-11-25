#!/bin/sh
# The Windows and the Linux desk app against a stand-in harness
# (test/fake_harness.py), in a window: the checks of scripts/smoke.sh (the
# macOS app's), with what differs on these systems.
# usage: scripts/smoke-other.sh path/to/harness-desk[.exe]  (built by `zig build smoke`)
# Windows: run it from Git Bash; needs the WebView2 Runtime, and says SKIP
# without it. Linux: needs a display; without one it runs itself under
# xvfb-run when that is there, and says SKIP otherwise. WebGL 2 and media
# without a click are required here, and only reported on CI, whose runners
# may have no GPU or audio; speech too on Windows (WebKitGTK has none).
set -u

BIN=${1:?usage: smoke-other.sh path/to/harness-desk}
case $BIN in /* | ?:*) ;; *) BIN=$(pwd)/$BIN ;; esac
HERE=$(cd "$(dirname "$0")/.." && pwd)

case $(uname -s) in
MINGW* | MSYS* | CYGWIN*) OS=windows ;;
Linux) OS=linux ;;
*) echo "SKIP: scripts/smoke.sh is the macOS app's"; exit 0 ;;
esac

PY=python3
if [ $OS = windows ]; then
    PY=python
    if ! reg query 'HKLM\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' //v pv > /dev/null 2>&1 &&
        ! reg query 'HKCU\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' //v pv > /dev/null 2>&1; then
        echo "SKIP: the WebView2 Runtime isn't installed here"
        exit 0
    fi
else
    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        if command -v xvfb-run > /dev/null 2>&1; then
            exec xvfb-run -a -s "-screen 0 1600x1000x24" "$0" "$BIN"
        fi
        echo "SKIP: no display here, and no xvfb-run"
        exit 0
    fi
fi
command -v $PY > /dev/null 2>&1 || { echo "SKIP: no $PY for the stand-in harness"; exit 0; }
STRICT=yes
[ -n "${CI:-}" ] && STRICT=no

D=$(mktemp -d "${TMPDIR:-/tmp}/desk-smoke.XXXXXX")
mkdir -p "$D/home"
if [ $OS = windows ]; then
    # as the app and the stand-in see them
    H=$(cygpath -w "$D/home")
    T=$(cygpath -w "$D/test")
    FAKE=$(cygpath -w "$HERE/test/fake_harness.cmd")
else
    H=$D/home
    T=$D/test
    FAKE=$HERE/test/fake_harness.py
fi
# as this script reads them
HP=$D/home
TP=$D/test
APP_PID=

end_pid() {
    if [ $OS = windows ]; then taskkill //F //PID "$1" > /dev/null 2>&1; else kill "$1" 2> /dev/null; fi
}
cleanup() {
    [ -n "$APP_PID" ] && kill "$APP_PID" 2> /dev/null
    [ -f "$HP/fake.pid" ] && end_pid "$(cat "$HP/fake.pid")"
    if [ "${KEEP:-}" = 1 ]; then
        echo "# kept $D"
    else
        # (Windows: the web view's processes hold its folder a moment longer)
        i=0
        while ! rm -rf "$D" 2> /dev/null && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
    fi
}
trap cleanup EXIT

free_port() { $PY -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
PORT=$(free_port)
OTHER=$(free_port)
export FAKE_OTHER_PORT=$OTHER

N=0
FAILED=0
ok() { N=$((N + 1)); echo "ok $N - $*"; }
not_ok() {
    N=$((N + 1))
    FAILED=$((FAILED + 1))
    echo "not ok $N - $*"
    echo "# app log:" && tail -15 "$TP/log" 2> /dev/null | sed 's/^/#   /'
    echo "# fake log:" && tail -8 "$HP/fake.log" 2> /dev/null | sed 's/^/#   /'
}
# soft: required here, reported on CI
check() {
    if [ "$1" = 0 ]; then ok "$2"; elif [ $STRICT = yes ]; then not_ok "$2"; else echo "# not checked on CI: $2"; fi
}

# wait_for FILE TEXT SECONDS: whether a line of FILE holds TEXT within the time
wait_for() {
    i=0
    while [ $i -lt $(($3 * 10)) ]; do
        grep -qF -- "$2" "$1" 2> /dev/null && return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}
# wait_count FILE TEXT N SECONDS: whether N lines of FILE hold TEXT within the time
wait_count() {
    i=0
    while [ $i -lt $(($4 * 10)) ]; do
        [ "$(count "$1" "$2")" -ge "$3" ] && return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}
in_log() { wait_for "$TP/log" "$1" "${2:-10}"; }
in_fake() { wait_for "$HP/fake.log" "$1" "${2:-10}"; }
count() { grep -cF -- "$2" "$1" 2> /dev/null || true; }
cmd() { echo "$*" >> "$TP/commands"; }
expect_log() { if in_log "$1" "${3:-10}"; then ok "$2"; else not_ok "$2 (no \"$1\")"; fi; }
expect_fake() { if in_fake "$1" "${3:-10}"; then ok "$2"; else not_ok "$2 (no \"$1\" from the fake)"; fi; }
# expect_again TEXT N WHAT [SECONDS]: the log holds TEXT N times
expect_again() { if wait_count "$TP/log" "$1" "$2" "${4:-10}"; then ok "$3"; else not_ok "$3 (\"$1\" fewer than $2 times)"; fi; }

launch() {
    # (an earlier start's log, for whoever keeps the folder: KEEP=1)
    [ -f "$TP/log" ] && cp "$TP/log" "$D/log.before-$N"
    rm -f "$TP/log" "$TP/commands"
    "$BIN" --home "$H" --test-dir "$T" >> "$D/app.out" 2>&1 &
    APP_PID=$!
}
wait_gone() {
    i=0
    while kill -0 "$APP_PID" 2> /dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    ! kill -0 "$APP_PID" 2> /dev/null
}

# ---- before harness ever ran ----
launch
expect_log "ready" "the app starts" 60
expect_log "show setup" "no desk.json: Set up harness first"
expect_log "menu start=0 stop=0 autostart=-" "nothing to start yet"

# ---- desk.json appears, nothing answers ----
mkdir -p "$HP/state"
$PY -c 'import json, sys; json.dump({"binary": sys.argv[1], "port": int(sys.argv[2]), "home": sys.argv[3], "version": "0.0.0-fake"}, open(sys.argv[4], "w"))' "$FAKE" "$PORT" "$H" "$HP/state/desk.json"
expect_log "show down" "desk.json written, nothing on its port: harness isn't running" 10
expect_log "ran autostart_query ok=1" "Open at login's state is asked"
expect_log "menu start=1 stop=0 autostart=off" "Start is offered; Open at login is off"

# ---- [Start harness] ----
cmd "js document.getElementById('start').click()"
expect_log "run $FAKE run --home $H" "[Start harness] runs harness run"
expect_fake "listening $PORT" "harness answers" 15
expect_log "load http://127.0.0.1:$PORT/enter?code=" "the app enters by a one-time code" 15
expect_fake "enter ok" "the code is accepted"
expect_log "finish http://127.0.0.1:$PORT/desk" "the desk page loads"
if [ ! -e "$HP/state/desk-code" ] && [ ! -e "$HP/state/open-request" ]; then ok "no code or request file is left"; else not_ok "a code or request file is left"; fi
expect_log "state in" "the app is in"
expect_log "menu start=0 stop=1 autostart=off" "Stop is offered once harness runs"

# ---- the page ----
expect_log "badge 3" "the page's badge is in the window's title"
expect_fake "report ua=" "the page reports"
if grep -F "report ua=" "$HP/fake.log" | grep -qF "harness-desk/"; then ok "the user agent names harness-desk"; else not_ok "the user agent names harness-desk"; fi
in_fake "report webgl2=" 10
check "$(grep -qF "report webgl2=yes" "$HP/fake.log"; echo $?)" "WebGL 2 is on"
in_fake "report audio=" 10
if grep -qF "report audio=NotAllowedError" "$HP/fake.log"; then not_ok "media plays without a click (NotAllowedError)"; else check "$(grep -qF "report audio=played" "$HP/fake.log"; echo $?)" "media plays without a click"; fi
if [ $OS = windows ]; then
    in_fake "report speech=" 10
    check "$(grep -qF "report speech=started" "$HP/fake.log"; echo $?)" "speech starts without a click"
else
    echo "# WebKitGTK has no speech synthesis: not checked"
fi

# ---- navigation ----
cmd "js click('next')"
expect_log "finish http://127.0.0.1:$PORT/desk/next" "a link on the desk's address stays in the window"
for pair in "ext https://example.com/" "otherport http://127.0.0.1:$OTHER/" "userinfo http://127.0.0.1:$PORT@example.com/" "blank https://example.org/blank"; do
    id=${pair%% *}
    url=${pair#* }
    cmd "js click('$id')"
    expect_log "external $url" "$url goes to the system browser"
done
# (a web view may refuse a file: link from a web page before the app is asked)
cmd "js click('file')"
cmd "js click('selfblank')"
expect_log "finish http://127.0.0.1:$PORT/desk/next?via=blank" "a new window on the desk's address loads in this one"
if grep -qF "file:///etc/hosts" "$TP/log" && ! grep -qF "nav cancel main file:///etc/hosts" "$TP/log"; then
    not_ok "a file: link is neither loaded nor opened"
else
    ok "a file: link is neither loaded nor opened"
fi
elsewhere=$(grep "^finish " "$TP/log" | grep -v "^finish about:blank" | grep -vF "finish http://127.0.0.1:$PORT/")
if [ -z "$elsewhere" ]; then ok "only the desk's address loaded in the window"; else not_ok "only the desk's address loaded in the window: $elsewhere"; fi

# ---- the bridge ----
cmd "js post({badge: 0})"
expect_log "badge -" "a badge of 0 clears it"
cmd "js post({attention: 'urgent'})"
expect_log "attention" "an urgent item asks for attention"
runs=$(count "$TP/log" "run $FAKE run ")
cmd "js post({start: true})"
in_log 'message desk {"start":true}' 5
sleep 1
if [ "$(count "$TP/log" "run $FAKE run ")" = "$runs" ]; then ok "the desk page can't start harness"; else not_ok "the desk page can't start harness"; fi
# a frame in the page is not the desk: its message is no one's
cmd "js frame()"
if in_log 'message other {"badge":77}' 10; then ok "a framed page's message is not the desk's"; else
    if grep -qF 'message desk {"badge":77}' "$TP/log"; then not_ok "a framed page's message is not the desk's"; else echo "# a framed page can't post here at all"; ok "a framed page's message is not the desk's"; fi
fi

# ---- reenter ----
first=$(grep -F "load http://127.0.0.1:$PORT/enter?code=" "$TP/log" | head -1)
cmd "js post({reenter: true})"
if wait_count "$HP/fake.log" "enter ok" 2 15; then
    second=$(grep -F "load http://127.0.0.1:$PORT/enter?code=" "$TP/log" | sed -n 2p)
    if [ -n "$second" ] && [ "$second" != "$first" ]; then ok "reenter enters again with a new code"; else not_ok "reenter enters again with a new code"; fi
else
    not_ok "reenter enters again"
fi
expect_again "badge 3" 2 "the desk page is back"

# ---- the menu ----
cmd "menu autostart"
expect_log "run $FAKE autostart on --home $H" "Open at login runs harness autostart on"
expect_log "menu start=0 stop=1 autostart=on" "Open at login is checked"
cmd "menu autostart"
expect_log "run $FAKE autostart off --home $H" "and off again"
expect_again "menu start=0 stop=1 autostart=off" 2 "Open at login is unchecked"
cmd "menu reload"
expect_log "reload" "Reload reloads the desk"
cmd "menu stop"
expect_log "run $FAKE stop --home $H" "Stop harness runs harness stop"
expect_fake "exited" "harness stops" 10
expect_again "show down" 2 "the window says harness isn't running" 20
expect_log "exit 0 run" "the harness the app started is reaped"

# ---- the frame ----
# One inside the screen's visible part, at least the window's smallest
# frame, and not the one it has. DESK_SMOKE_SCREEN="X Y W H" pretends the
# visible part is that, to try a small screen on a large one.
screen_line=$(grep "^screen " "$TP/log" | head -1)
target=none
if [ -z "$screen_line" ]; then
    not_ok "the app says where its window can go"
else
    # screen X Y W H min MW MH
    # shellcheck disable=SC2086
    set -- $screen_line
    visible="$2 $3 $4 $5"
    minimum="$7 $8"
    [ -n "${DESK_SMOKE_SCREEN:-}" ] && visible=$DESK_SMOKE_SCREEN
    current=$(grep "^frame " "$TP/log" | tail -1 | cut -d' ' -f2-)
    target=$($PY "$HERE/scripts/frame_target.py" "$visible" "$minimum" "$current" | tr -d '\r') || target=none
fi
if [ "$target" = none ]; then
    echo "# SKIP: the screen's visible part ($visible) leaves no room for another frame of at least $minimum, so the frame isn't checked"
else
    cmd "frame $target"
    expect_log "frame $target" "the window takes a new frame ($target, inside $visible)"
fi
cmd "quit"
if wait_gone; then ok "Quit quits"; else not_ok "Quit quits"; fi
launch
expect_log "ready" "the app starts again" 60
if [ "$target" = none ]; then
    echo "# SKIP: the window's frame is remembered (no other frame to set)"
elif [ "$(grep "^frame " "$TP/log" | head -1)" = "frame $target" ]; then
    ok "the window's frame is remembered"
else
    not_ok "the window's frame is remembered ($(grep "^frame " "$TP/log" | head -1), not $target)"
fi
# a second start is the same window, not another
"$BIN" --home "$H" --test-dir "$D/second" >> "$D/app.out" 2>&1 &
SECOND=$!
i=0
while kill -0 "$SECOND" 2> /dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$SECOND" 2> /dev/null; then
    kill "$SECOND" 2> /dev/null
    not_ok "a second start ends at once, leaving the first window"
elif [ -e "$D/second/log" ] && grep -q "^ready" "$D/second/log"; then
    not_ok "a second start ends at once, leaving the first window (it opened one of its own)"
else
    ok "a second start ends at once, leaving the first window"
fi
cmd "quit"
wait_gone
APP_PID=

echo "# $N checks, $FAILED failed"
[ $FAILED = 0 ]
