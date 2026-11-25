#!/bin/sh
# The desk app against a stand-in harness (test/fake_harness.py), in a
# window: it starts, finds no harness, starts it, enters by a one-time code,
# shows the badge, keeps navigation on 127.0.0.1:PORT and hands other links
# to the system browser, enters again, runs the menu's commands, and
# remembers its frame.
# usage: scripts/smoke.sh path/to/harness-desk.app  (built by `zig build smoke`)
# Needs a window session (Aqua); says SKIP without one. WebGL 2, media and
# speech without a click are required here, and only reported on CI, whose
# runners may have no GPU or audio.
set -u

APP=${1:?usage: smoke.sh path/to/harness-desk.app}
case $APP in /*) ;; *) APP=$(pwd)/$APP ;; esac
HERE=$(cd "$(dirname "$0")/.." && pwd)
FAKE=$HERE/test/fake_harness.py
BIN=$APP/Contents/MacOS/harness-desk
ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
case $ID in *.smoke) ;; *) echo "FAIL: $APP isn't the smoke's app (its id is $ID)" >&2; exit 1 ;; esac

if [ "$(launchctl managername 2>/dev/null)" != Aqua ]; then
    echo "SKIP: no window session here (launchctl managername isn't Aqua)"
    exit 0
fi
STRICT=yes
[ -n "${CI:-}" ] && STRICT=no

D=$(mktemp -d "${TMPDIR:-/tmp}/desk-smoke.XXXXXX")
H=$D/home
T=$D/test
mkdir -p "$H"
APP_PID=

cleanup() {
    [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null
    [ -f "$H/fake.pid" ] && kill "$(cat "$H/fake.pid")" 2>/dev/null
    # the smoke app's own leftovers, by its own id only
    defaults delete "$ID" > /dev/null 2>&1
    for dir in WebKit Caches HTTPStorages "Saved Application State"; do
        rm -rf "$HOME/Library/$dir/$ID" "$HOME/Library/$dir/$ID.savedState"
    done
    if [ "${KEEP:-}" = 1 ]; then echo "# kept $D"; else rm -rf "$D"; fi
}
trap cleanup EXIT

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
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
    echo "# app log:" && tail -15 "$T/log" 2>/dev/null | sed 's/^/#   /'
    echo "# fake log:" && tail -8 "$H/fake.log" 2>/dev/null | sed 's/^/#   /'
}
# soft: required here, reported on CI
check() {
    if [ "$1" = 0 ]; then ok "$2"; elif [ $STRICT = yes ]; then not_ok "$2"; else echo "# not checked on CI: $2"; fi
}

# wait_for FILE TEXT SECONDS: whether a line of FILE holds TEXT within the time
wait_for() {
    i=0
    while [ $i -lt $(($3 * 10)) ]; do
        grep -qF -- "$2" "$1" 2>/dev/null && return 0
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
in_log() { wait_for "$T/log" "$1" "${2:-10}"; }
in_fake() { wait_for "$H/fake.log" "$1" "${2:-10}"; }
count() { grep -cF -- "$2" "$1" 2>/dev/null || true; }
cmd() { echo "$*" >> "$T/commands"; }
expect_log() { if in_log "$1" "${3:-10}"; then ok "$2"; else not_ok "$2 (no \"$1\")"; fi; }
expect_fake() { if in_fake "$1" "${3:-10}"; then ok "$2"; else not_ok "$2 (no \"$1\" from the fake)"; fi; }
# expect_again TEXT N WHAT [SECONDS]: the log holds TEXT N times
expect_again() { if wait_count "$T/log" "$1" "$2" "${4:-10}"; then ok "$3"; else not_ok "$3 (\"$1\" fewer than $2 times)"; fi; }

launch() {
    rm -f "$T/log" "$T/commands"
    "$BIN" --home "$H" --test-dir "$T" >> "$D/app.out" 2>&1 &
    APP_PID=$!
}

# ---- before harness ever ran ----
launch
expect_log "ready" "the app starts" 30
expect_log "show setup" "no desk.json: Set up harness first"
expect_log "menu start=0 stop=0 autostart=-" "nothing to start yet"

# ---- desk.json appears, nothing answers ----
mkdir -p "$H/state"
printf '{"binary": "%s", "port": %s, "home": "%s", "version": "0.0.0-fake"}\n' "$FAKE" "$PORT" "$H" > "$H/state/desk.json"
expect_log "show down" "desk.json written, nothing on its port: harness isn't running" 10
expect_log "ran autostart_query ok=1" "Open at login's state is asked"
expect_log "menu start=1 stop=0 autostart=off" "Start is offered; Open at login is off"

# ---- [Start harness] ----
cmd "js document.getElementById('start').click()"
expect_log "run $FAKE run --home $H" "[Start harness] runs harness run"
expect_fake "listening $PORT" "harness answers" 10
expect_log "load http://127.0.0.1:$PORT/enter?code=" "the app enters by a one-time code" 15
expect_fake "enter ok" "the code is accepted"
expect_log "finish http://127.0.0.1:$PORT/desk" "the desk page loads"
if [ ! -e "$H/state/desk-code" ] && [ ! -e "$H/state/open-request" ]; then ok "no code or request file is left"; else not_ok "a code or request file is left"; fi
expect_log "state in" "the app is in"
expect_log "menu start=0 stop=1 autostart=off" "Stop is offered once harness runs"

# ---- the page ----
expect_log "badge 3" "the page's badge is on the Dock tile"
expect_fake "report ua=" "the page reports"
if grep -F "report ua=" "$H/fake.log" | grep -qF "harness-desk/"; then ok "the user agent names harness-desk"; else not_ok "the user agent names harness-desk"; fi
in_fake "report webgl2=" 10
check "$(grep -qF "report webgl2=yes" "$H/fake.log"; echo $?)" "WebGL 2 is on"
in_fake "report audio=" 10
if grep -qF "report audio=NotAllowedError" "$H/fake.log"; then not_ok "media plays without a click (NotAllowedError)"; else check "$(grep -qF "report audio=played" "$H/fake.log"; echo $?)" "media plays without a click"; fi
in_fake "report speech=" 10
check "$(grep -qF "report speech=started" "$H/fake.log"; echo $?)" "speech starts without a click"

# ---- navigation ----
cmd "js click('next')"
expect_log "finish http://127.0.0.1:$PORT/desk/next" "a link on the desk's address stays in the window"
for pair in "ext https://example.com/" "otherport http://127.0.0.1:$OTHER/" "userinfo http://127.0.0.1:$PORT@example.com/" "blank https://example.org/blank"; do
    id=${pair%% *}
    url=${pair#* }
    cmd "js click('$id')"
    expect_log "external $url" "$url goes to the system browser"
done
# (WebKit refuses a file: link from a web page before the app is asked)
cmd "js click('file')"
cmd "js click('selfblank')"
expect_log "finish http://127.0.0.1:$PORT/desk/next?via=blank" "a new window on the desk's address loads in this one"
if grep -qF "file:///etc/hosts" "$T/log" && ! grep -qF "nav cancel main file:///etc/hosts" "$T/log"; then
    not_ok "a file: link is neither loaded nor opened"
else
    ok "a file: link is neither loaded nor opened"
fi
elsewhere=$(grep "^finish " "$T/log" | grep -v "^finish about:blank" | grep -vF "finish http://127.0.0.1:$PORT/")
if [ -z "$elsewhere" ]; then ok "only the desk's address loaded in the window"; else not_ok "only the desk's address loaded in the window: $elsewhere"; fi

# ---- the bridge ----
cmd "js post({badge: 0})"
expect_log "badge -" "a badge of 0 clears it"
cmd "js post({attention: 'urgent'})"
expect_log "attention" "an urgent item asks for attention"
runs=$(count "$T/log" "run $FAKE run ")
cmd "js post({start: true})"
in_log 'message desk {"start":true}' 5
sleep 1
if [ "$(count "$T/log" "run $FAKE run ")" = "$runs" ]; then ok "the desk page can't start harness"; else not_ok "the desk page can't start harness"; fi

# ---- reenter ----
first=$(grep -F "load http://127.0.0.1:$PORT/enter?code=" "$T/log" | head -1)
cmd "js post({reenter: true})"
if wait_count "$H/fake.log" "enter ok" 2 15; then
    second=$(grep -F "load http://127.0.0.1:$PORT/enter?code=" "$T/log" | sed -n 2p)
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
cmd "frame 120 140 1100 760"
expect_log "frame 120 140 1100 760" "the window takes a new frame"
cmd "quit"
i=0
while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$APP_PID" 2>/dev/null; then not_ok "Quit quits"; else ok "Quit quits"; fi
launch
expect_log "ready" "the app starts again" 30
if [ "$(grep "^frame " "$T/log" | head -1)" = "frame 120 140 1100 760" ]; then ok "the window's frame is remembered"; else not_ok "the window's frame is remembered ($(grep "^frame " "$T/log" | head -1))"; fi
cmd "quit"
i=0
while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
APP_PID=

echo "# $N checks, $FAILED failed"
[ $FAILED = 0 ]
