#!/bin/sh
# Live check on a Mac with Screen Recording allowed for the app running this
# script. Builds scripts/fixture.swift (a window with timed changes), runs
# every command against it, and closes it.
# usage: scripts/live.sh [path/to/headsight]
set -u
cd "$(dirname "$0")/.."
HS=${1:-zig-out/bin/headsight}
case $HS in /*) ;; *) HS=$(pwd)/$HS ;; esac
W="headsight fixture"
FIX=${TMPDIR:-/tmp}/headsight-fixture
swiftc -O scripts/fixture.swift -o "$FIX" || { echo "FAIL: building the fixture" >&2; exit 1; }
PID=

start() { "$FIX" "$@" & PID=$!; sleep 1.5; }
stop() { [ -n "$PID" ] && kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=; }
fail() { echo "FAIL: $*" >&2; stop; exit 1; }
ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

# run <want exit> <text> -- args: runs headsight, checks exit and output, prints time taken
run() {
    want=$1; text=$2; shift 3
    t0=$(ms)
    out=$("$HS" "$@" 2>&1); got=$?
    t1=$(ms)
    [ "$got" = "$want" ] || fail "headsight $*: exit $got, want $want; output: $out"
    case $out in *"$text"*) ;; *) fail "headsight $*: output lacks '$text': $out" ;; esac
    echo "ok - headsight $* ($((t1 - t0)) ms)"
    echo "$out" | sed 's/^/     /' | head -4
}
trap stop EXIT

start --count --done 6 --side 8
run 0 "$W" -- windows
run 0 "snap source=window" -- snap --window "$W" --name live
run 0 "still after=" -- wait --still --window "$W" --timeout 20
run 0 "found=\"Export Done: 42 files\"" -- wait --text "Export Done" --window "$W" --timeout 20
run 0 "changed after=0." -- wait --change --since live --timeout 5
run 0 "Plan: Pro" -- wait --text "Plan: Pro" --window "$W" --timeout 10
run 0 "boxes=" -- diff --since live
run 0 "Export Done" -- text --window "$W"
# the title bar (focus, recording indicator) is left out by default
run 1 "timeout after=" -- wait --change --window "$W" --timeout 2
run 1 "timeout after=" -- wait --change --window "$W" --ignore 100,180,900,120 --timeout 2
run 0 "\"event\":\"still\"" -- wait --still --window "$W" --json --timeout 10
run 2 "outside the source" -- snap --window "$W" --region 0,0,99999,10
stop

start --toast 3
run 0 "Saved to Downloads" -- wait --text "Saved" --window "$W" --timeout 15
# the window closes while waiting
( sleep 2; kill "$PID" ) &
run 4 "window gone" -- wait --change --window "$W" --region 100,700,10,10 --timeout 20
wait
PID=

# the window is minimised while waiting
start --minimize 2
run 4 "window gone" -- wait --change --window "$W" --region 100,700,10,10 --timeout 20
stop

# errors that end a stream before it starts
run 4 "no camera matches" -- snap --camera nosuchcamera
run 2 "no window matches" -- wait --change --window nosuchwindow --timeout 2

run 0 "dropped live" -- drop live
run 2 "no reference" -- diff --since live
echo "live: all ok"
