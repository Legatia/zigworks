#!/bin/sh
# The desk app against a stand-in harness (test/fake_harness.py), in a
# window: on a data folder with no config.ini it shows "Set up", runs
# harness init and config set, takes the key in its own secure field
# (filled by the test build with its fake key, sk-test-not-a-key) and pipes
# it to harness secret add, starts harness, enters by a one-time code,
# shows the badge, keeps navigation on 127.0.0.1:PORT and hands other links
# to the system browser, enters again, runs the menu's commands ("Provider
# and key…" too), and remembers its frame. The stand-in is put in the app
# as Contents/MacOS/harness, where the release carries harness, and taken
# out after. DESK_SMOKE_HARNESS=PATH runs the setup once more against that
# real harness (its own data folder and file store under the smoke's temp
# folder, HERMES_HOME nowhere, and a provider of its own on a dead local
# address, so no model is ever called).
# usage: scripts/smoke.sh path/to/harness-desk.app  (built by `zig build smoke`)
# Needs a window session (Aqua); says SKIP without one. WebGL 2, media and
# speech without a click are required here, and only reported on CI, whose
# runners may have no GPU or audio. DESK_SMOKE_SCREEN="X Y W H" pretends the
# screen's visible part is that, for the frame checks.
set -u

APP=${1:?usage: smoke.sh path/to/harness-desk.app}
case $APP in /*) ;; *) APP=$(pwd)/$APP ;; esac
# as the app finds itself: no ./ and no symbolic links
APP=$(cd "$APP" && pwd -P)
HERE=$(cd "$(dirname "$0")/.." && pwd)
FAKE=$HERE/test/fake_harness.py
BIN=$APP/Contents/MacOS/harness-desk
OWN=$APP/Contents/MacOS/harness
FAKE_KEY=sk-test-not-a-key
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
    [ -n "${REAL_HOME:-}" ] && [ -f "$REAL_HOME/config.ini" ] && "$OWN" stop --home "$REAL_HOME" > /dev/null 2>&1
    rm -f "$OWN"
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
# the stand-in's harness init writes this port, as harness init writes one
export FAKE_PORT=$PORT
# nothing of the owner's: no Hermes setup to notice, and a real harness's
# secrets in a folder of the smoke's own
export HERMES_HOME="$D/no-hermes" HARNESS_STORE="$D/store"
cp "$FAKE" "$OWN"
chmod +x "$OWN"

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
    "$BIN" --home "${1:-$H}" --test-dir "$T" >> "$D/app.out" 2>&1 &
    APP_PID=$!
}

# probe NAME JS: the page posts {probe: {NAME: JS's value}}, which the app
# logs; the line is in $PROBE (empty when it didn't come)
probe() {
    before=$(count "$T/log" "\"probe\":{\"$1\"")
    cmd "js post({probe: {$1: $2}})"
    PROBE=
    if wait_count "$T/log" "\"probe\":{\"$1\"" $((before + 1)) 10; then
        PROBE=$(grep -F "\"probe\":{\"$1\"" "$T/log" | tail -1)
    fi
}
expect_probe() {
    case $PROBE in *"$1"*) ok "$2" ;; *) not_ok "$2 (the page said: ${PROBE:-nothing})" ;; esac
}
# wait_page N: the setup page shown for the Nth time, and loaded since
wait_page() {
    i=0
    while [ $i -lt 150 ]; do
        awk -v n="$1" '/^show setup/ { c++; if (c == n) at = NR } at && NR > at && /^finish about:blank/ { found = 1 } END { exit !found }' "$T/log" 2>/dev/null && return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}
js_provider() { echo "var p = document.getElementById('provider'); p.value = '$1'; p.dispatchEvent(new Event('change'));"; }
js_set() { echo "document.getElementById('$1').value = '$2';"; }
js_continue="document.getElementById('continue').click();"

# ---- before harness was ever set up: "Set up" ----
launch
expect_log "ready" "the app starts" 30
expect_log "show setup" "no config.ini: the Set up screen"
expect_log "menu start=0 stop=0 autostart=- provider=0" "nothing to start or change before it is set up"
wait_page 1
probe options "Array.prototype.map.call(document.querySelectorAll('#provider option'), function (o) { return o.textContent; }).join(',')"
expect_probe "Anthropic,OpenAI,OpenRouter,opencode,omnigate,Other" "Provider offers Anthropic, OpenAI, OpenRouter, opencode, omnigate and Other"
probe model "document.getElementById('model').value"
expect_probe '"claude-opus-4-8"' "Model starts with Anthropic's usual one"
probe fields "[document.querySelectorAll('input[type=password]').length, document.getElementById('address-row').hidden, document.getElementById('api-row').hidden].join(',')"
expect_probe '"0,true,true"' "no key field on the page; no Address or Format for Anthropic"
cmd "js $(js_provider omnigate)"
probe switched "[document.getElementById('model').value, document.getElementById('address-row').hidden].join(',')"
expect_probe '"claude-sonnet,false"' "omnigate: its usual model and an Address"
cmd "js $(js_set url og.example.com) $js_continue"
wait_page 2
probe note "document.getElementById('note').textContent"
expect_probe "Address must start with http:" "an address without http(s):// is refused on the screen"
if grep -q "^step " "$T/log"; then not_ok "nothing runs for a form with a problem"; else ok "nothing runs for a form with a problem"; fi

# a step that fails: its own line, and what was typed stays
cmd "js $(js_provider anthropic) $(js_set model refuse-me) $js_continue"
expect_log "step $OWN init --home $H" "Continue runs harness init (the app's own copy)"
expect_log "step $OWN config set model.provider anthropic model.model refuse-me model.memory_model claude-haiku-4-5 model.worker_model claude-haiku-4-5 --home $H" "then harness config set, every pair in one call"
wait_page 4
probe refused "[document.getElementById('note').textContent, document.getElementById('model').value, document.getElementById('provider').value].join('|')"
expect_probe "model.model refuse-me is refused by the stand-in|refuse-me|anthropic" "the refused step's own line is shown, and what was typed stays"

# Continue again: no second init; the key in the app's own secure field
cmd "js $(js_set model claude-opus-4-8) $js_continue"
expect_again "step $OWN config set model.provider anthropic model.model claude-opus-4-8" 1 "Continue again runs config set"
if [ "$(count "$T/log" "init --home")" = 1 ]; then ok "harness init isn't run again"; else not_ok "harness init isn't run again"; fi
expect_log "ask key Anthropic key" "the key is asked for in the app's own sheet"
cmd "key cancel"
expect_log "key-sheet cancel secure=1" "the sheet's field is an NSSecureTextField"
expect_log "key cancelled" "Cancel answers"
wait_page 6
probe cancelled "document.getElementById('note').textContent"
expect_probe "The key wasn't stored." "a cancelled key says so"
if [ -e "$H/fake-store/anthropic" ]; then not_ok "nothing is stored on Cancel"; else ok "nothing is stored on Cancel"; fi
cmd "js $js_continue"
expect_again "ask key Anthropic key" 2 "Continue asks for the key again"
cmd "key fill"
expect_log "key given" "the key is given"
expect_log "store $OWN secret add anthropic --stdin --home $H" "it goes to harness secret add anthropic --stdin"
expect_fake "secret add anthropic (17 bytes)" "harness gets it on its input"
if [ "$(cat "$H/fake-store/anthropic" 2>/dev/null)" = "$FAKE_KEY" ]; then ok "the stored key is the one typed"; else not_ok "the stored key is the one typed"; fi
grep -qF '"model.provider": "anthropic"' "$H/fake-settings.json" && grep -qF '"model.model": "claude-opus-4-8"' "$H/fake-settings.json" && ok "config.ini has the provider and model" || not_ok "config.ini has the provider and model"

# ---- then harness is started and entered ----
expect_log "run $OWN run --home $H" "then harness run is started"
expect_fake "listening $PORT" "harness answers" 10
expect_log "load http://127.0.0.1:$PORT/enter?code=" "the app enters by a one-time code" 15
expect_fake "enter ok" "the code is accepted"
expect_log "finish http://127.0.0.1:$PORT/desk" "the desk page loads"
if [ ! -e "$H/state/desk-code" ] && [ ! -e "$H/state/open-request" ]; then ok "no code or request file is left"; else not_ok "a code or request file is left"; fi
expect_log "state in" "the app is in"
expect_log "ran autostart_query ok=1" "Open at login's state is asked"
expect_log "menu start=0 stop=1 autostart=off provider=1" "Stop and Provider and key… are offered once harness runs"

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
runs=$(count "$T/log" "run $OWN run ")
cmd "js post({start: true})"
in_log 'message desk {"start":true}' 5
sleep 1
if [ "$(count "$T/log" "run $OWN run ")" = "$runs" ]; then ok "the desk page can't start harness"; else not_ok "the desk page can't start harness"; fi

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
expect_log "run $OWN autostart on --home $H" "Open at login runs harness autostart on"
expect_log "menu start=0 stop=1 autostart=on provider=1" "Open at login is checked"
cmd "menu autostart"
expect_log "run $OWN autostart off --home $H" "and off again"
expect_again "menu start=0 stop=1 autostart=off provider=1" 2 "Open at login is unchecked"
cmd "menu reload"
expect_log "reload" "Reload reloads the desk"

# ---- Provider and key… ----
enters=$(count "$H/fake.log" "enter ok")
setups=$(count "$T/log" "show setup")
cmd "menu provider"
expect_log "read ok=1" "Provider and key… reads the values in use"
wait_page $((setups + 1))
probe inuse "[document.querySelector('h1').textContent, document.getElementById('provider').value, document.getElementById('model').value, !!document.getElementById('replace'), document.getElementById('replace').checked].join('|')"
expect_probe "Provider and key|anthropic|claude-opus-4-8|true|false" "it opens with the values in use, the key not asked for unless chosen"
cmd "js document.getElementById('cancel').click()"
if wait_count "$H/fake.log" "enter ok" $((enters + 1)) 15; then ok "Cancel goes back to the desk"; else not_ok "Cancel goes back to the desk"; fi
asks=$(count "$T/log" "ask key")
cmd "menu provider"
wait_page $((setups + 2))
cmd "js $(js_set model claude-opus-4-8-x) $js_continue"
expect_log "step $OWN config set model.provider anthropic model.model claude-opus-4-8-x --home $H" "a new model alone: config set, the helpers left as they are"
expect_log "alert Saved | harness is running: send /reload to use it." "config set's own line says what the change waits for"
if wait_count "$H/fake.log" "enter ok" $((enters + 2)) 15; then ok "then the desk again"; else not_ok "then the desk again"; fi
if [ "$(count "$T/log" "ask key")" = "$asks" ]; then ok "the key isn't asked for again unless chosen"; else not_ok "the key isn't asked for again unless chosen"; fi
cmd "menu provider"
wait_page $((setups + 4))
cmd "js document.getElementById('replace').checked = true; $js_continue"
expect_again "ask key Anthropic key" 3 "Replace the key asks for it"
cmd "key fill"
expect_again "store $OWN secret add anthropic --stdin --home $H" 2 "and stores it again"
if wait_count "$H/fake.log" "enter ok" $((enters + 3)) 15; then ok "then the desk again"; else not_ok "then the desk again"; fi

cmd "menu stop"
expect_log "run $OWN stop --home $H" "Stop harness runs harness stop"
expect_fake "exited" "harness stops" 10
expect_again "show down" 1 "the window says harness isn't running" 20
expect_log "exit 0 run" "the harness the app started is reaped"

# ---- the frame ----
# One inside the screen's visible part, at least the window's smallest
# frame, and not the one it has (a CI runner's screen may be 1024×768).
# DESK_SMOKE_SCREEN="X Y W H" pretends the visible part is that, to try a
# small screen on a large one.
screen_line=$(grep "^screen " "$T/log" | head -1)
target=none
if [ -z "$screen_line" ]; then
    not_ok "the app says where its window can go"
else
    # screen X Y W H min MW MH
    set -- $screen_line
    visible="$2 $3 $4 $5"
    minimum="$7 $8"
    [ -n "${DESK_SMOKE_SCREEN:-}" ] && visible=$DESK_SMOKE_SCREEN
    current=$(grep "^frame " "$T/log" | tail -1 | cut -d' ' -f2-)
    target=$(python3 "$HERE/scripts/frame_target.py" "$visible" "$minimum" "$current") || target=none
fi
if [ "$target" = none ]; then
    echo "# SKIP: the screen's visible part ($visible) leaves no room for another frame of at least $minimum, so the frame isn't checked"
else
    cmd "frame $target"
    expect_log "frame $target" "the window takes a new frame ($target, inside $visible)"
fi
cmd "quit"
i=0
while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$APP_PID" 2>/dev/null; then not_ok "Quit quits"; else ok "Quit quits"; fi
launch
expect_log "ready" "the app starts again" 30
if [ "$target" = none ]; then
    echo "# SKIP: the window's frame is remembered (no other frame to set)"
elif [ "$(grep "^frame " "$T/log" | head -1)" = "frame $target" ]; then
    ok "the window's frame is remembered"
else
    not_ok "the window's frame is remembered ($(grep "^frame " "$T/log" | head -1), not $target)"
fi
cmd "quit"
i=0
while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
APP_PID=

# ---- the key went nowhere but harness's input ----
leaked=
for f in "$T/log" "$D/app.out" "$H/fake.log" "$H/fake-settings.json" "$H/config.ini"; do
    grep -qF "$FAKE_KEY" "$f" 2>/dev/null && leaked="$leaked $f"
done
if [ -z "$leaked" ]; then ok "the key is in no log, output, setting or command line"; else not_ok "the key is in no log, output, setting or command line:$leaked"; fi

# ---- the same setup against a real harness ----
if [ -n "${DESK_SMOKE_HARNESS:-}" ]; then
    REAL_HOME=$D/real-home
    cp "$DESK_SMOKE_HARNESS" "$OWN"
    launch "$REAL_HOME"
    expect_log "show setup" "real harness: the Set up screen" 30
    wait_page 1
    cmd "js $(js_provider other) $(js_set model smoke-model) $(js_set url http://127.0.0.1:9/v1) $js_continue"
    expect_log "step $OWN init --home $REAL_HOME" "real harness: init"
    expect_log "step $OWN config set provider other.api openai provider other.url http://127.0.0.1:9/v1 model.provider other model.model smoke-model" "real harness: config set"
    expect_log "ask key Key" "real harness: the key is asked for"
    cmd "key fill"
    expect_log "store $OWN secret add other --stdin --home $REAL_HOME" "real harness: secret add other --stdin"
    expect_again "stepped ok=1" 3 "real harness: init, config set and the key all succeed"
    expect_log "run $OWN run --home $REAL_HOME" "real harness: harness run is started" 15
    expect_log "load http://127.0.0.1:" "real harness: the app enters by a one-time code" 30
    expect_log "state in" "real harness: the app is in" 30
    if grep -q "^finish http://127.0.0.1:[0-9]*/desk" "$T/log"; then ok "real harness: the desk page loads"; else in_log "finish http://127.0.0.1:" 15; grep -q "^finish http://127.0.0.1:[0-9]*/desk" "$T/log" && ok "real harness: the desk page loads" || not_ok "real harness: the desk page loads"; fi
    [ "$("$OWN" config get model.provider --home "$REAL_HOME")" = other ] && [ "$("$OWN" config get "provider other.url" --home "$REAL_HOME")" = http://127.0.0.1:9/v1 ] && ok "real harness: config.ini has them" || not_ok "real harness: config.ini has them"
    if [ -e "$HARNESS_STORE/other" ]; then ok "real harness: the key is in its store (the smoke's own folder)"; else not_ok "real harness: the key is in its store (the smoke's own folder)"; fi
    cmd "menu provider"
    expect_log "read ok=1" "real harness: Provider and key… reads the values in use"
    wait_page 3
    probe real "[document.getElementById('provider').value, document.getElementById('model').value, document.getElementById('api').value].join('|')"
    expect_probe "other|smoke-model|openai" "real harness: the form has them"
    cmd "js document.getElementById('cancel').click()"
    cmd "menu stop"
    expect_log "run $OWN stop --home $REAL_HOME" "real harness: Stop"
    expect_log "show down" "real harness: it stops" 30
    for f in "$T/log" "$D/app.out" "$REAL_HOME/config.ini"; do
        grep -qF "$FAKE_KEY" "$f" 2>/dev/null && not_ok "real harness: the key isn't in $f"
    done
    grep -rqF "$FAKE_KEY" "$REAL_HOME/log" 2>/dev/null && not_ok "real harness: the key isn't in harness's log"
    cmd "quit"
    i=0
    while kill -0 "$APP_PID" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    APP_PID=
fi

echo "# $N checks, $FAILED failed"
[ $FAILED = 0 ]
