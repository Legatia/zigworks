#!/bin/sh
# End-to-end test: drives real sessions through the CLI.
# usage: scripts/smoke.sh [path/to/headterm]
set -eu

HT=${1:-zig-out/bin/headterm}
case $HT in /*) ;; *) HT=$(pwd)/$HT ;; esac

# Private session directory so the test never touches real sessions.
STATE=$(mktemp -d /tmp/headterm-smoke.XXXXXX)
unset XDG_RUNTIME_DIR
export TMPDIR=$STATE
S=smoke$$

cleanup() {
    "$HT" kill "$S" >/dev/null 2>&1 || true
    "$HT" kill "$S-x" >/dev/null 2>&1 || true
    "$HT" kill "$S-m" >/dev/null 2>&1 || true
    "$HT" kill "$S-w" >/dev/null 2>&1 || true
    "$HT" kill "$S-t" >/dev/null 2>&1 || true
    "$HT" kill "$S-r" >/dev/null 2>&1 || true
    rm -rf "$STATE"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

quiet() { "$@" >/dev/null; }

check() { # check <description> <command...>
    desc=$1
    shift
    if "$@"; then echo "ok - $desc"; else fail "$desc"; fi
}

"$HT" start "$S" --cols 40 --rows 6 -- /bin/sh -c 'printf "ready\n"; read x; echo got:$x; read y; echo second:$y; exit 3' >/dev/null
check "wait for initial text" quiet "$HT" wait "$S" --text ready --timeout 5000

"$HT" send "$S" hello '<Enter>'
out=$("$HT" wait "$S" --text got:hello --timeout 5000)
check "screen shows echoed input" sh -c 'printf "%s\n" "$1" | grep -qx "got:hello"' _ "$out"

json=$("$HT" screen "$S" --json)
check "json reports running" sh -c 'printf "%s" "$1" | grep -q "\"exited\":false"' _ "$json"
check "json has lines" sh -c 'printf "%s" "$1" | grep -q "\"lines\":\[\"ready\",\"hello\",\"got:hello\""' _ "$json"

diff=$("$HT" screen "$S" --diff)
check "diff with no changes is empty" sh -c 'printf "%s\n" "$1" | grep -q "changed=0"' _ "$diff"

"$HT" send "$S" world '<Enter>'
diff=$("$HT" wait "$S" --exit --diff --timeout 5000) || fail "wait --exit"
check "diff shows changed rows" sh -c 'printf "%s\n" "$1" | grep -q "^4|second:world$"' _ "$diff"
check "exit status reported" sh -c 'printf "%s\n" "$1" | grep -q "exited=3"' _ "$diff"
check "screen after wait has no new changes" sh -c '"$1" screen "$2" --diff | grep -q "changed=0"' _ "$HT" "$S"

set +e
"$HT" wait "$S" --text never-appears --timeout 300 >/dev/null
rc=$?
set -e
check "wait for missing text on exited session fails" test "$rc" -eq 1

check "list shows session" sh -c '"$1" list | grep -q "^$2 "' _ "$HT" "$S"
"$HT" kill "$S"
check "kill removes session" sh -c '! "$1" list | grep -q "^$2 "' _ "$HT" "$S"

# Idle wait, resize and cursor-key mode on a second session.
"$HT" start "$S-x" --cols 30 --rows 5 -- /bin/sh -c 'printf "\033[?1h"; stty -echo raw; dd bs=1 count=3 2>/dev/null | od -An -c; sleep 30' >/dev/null
"$HT" wait "$S-x" --idle 300 --timeout 5000 >/dev/null || fail "wait --idle"
check "DECCKM tracked" sh -c '"$1" screen "$2" --json | grep -q "\"app_cursor_keys\":true"' _ "$HT" "$S-x"
"$HT" send "$S-x" '<Up>'
out=$("$HT" wait "$S-x" --text O --timeout 5000)
check "arrow sent in application mode" sh -c 'printf "%s\n" "$1" | grep -q "033   O   A"' _ "$out"
"$HT" resize "$S-x" 50 7
check "resize" sh -c '"$1" screen "$2" | grep -q " 50x7 "' _ "$HT" "$S-x"
"$HT" kill "$S-x"

# Styles: a menu whose selection (inverse) moves when a key is pressed.
"$HT" start "$S-m" --cols 20 --rows 4 -- /bin/sh -c 'printf "  Open\r\n\033[7m  Save  \033[m\r\n"; read x; printf "\033[1;1H\033[7m  Open  \033[m\033[2;1H  Save  "; sleep 30' >/dev/null
out=$("$HT" wait "$S-m" --text Save --styles --timeout 5000)
check "styled run reported" sh -c 'printf "%s\n" "$1" | grep -qF "row 1: [0-8 inverse \"  Save\"]"' _ "$out"
check "styles in json" sh -c '"$1" screen "$2" --json --styles | grep -qF "\"attrs\":[\"inverse\"]"' _ "$HT" "$S-m"
"$HT" send "$S-m" '<Enter>'
out=$("$HT" wait "$S-m" --idle 300 --diff --styles --timeout 5000)
check "style-only change shows in diff" sh -c 'printf "%s\n" "$1" | grep -qx "0|  Open" && printf "%s\n" "$1" | grep -qF "row 0: [0-8 inverse \"  Open\"]"' _ "$out"
"$HT" kill "$S-m"

# Waits on wrapped text, regex and disappearing text.
"$HT" start "$S-w" --cols 20 --rows 5 -- /bin/sh -c 'printf "Downloading package-name-that-is-long 42%%\n"; read x; printf "Loading..."; sleep 1; printf "\r\033[KDone\n"; sleep 30' >/dev/null
check "text across a wrapped row" quiet "$HT" wait "$S-w" --text package-name-that-is-long --timeout 5000
check "regex across a wrapped row" quiet "$HT" wait "$S-w" --regex '^Down.*long \d+%$' --timeout 5000
set +e
err=$("$HT" wait "$S-w" --regex '(abc' 2>&1)
rc=$?
set -e
check "bad regex is rejected" sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -q "missing .). at offset 4"' _ "$rc" "$err"
"$HT" send "$S-w" '<Enter>'
"$HT" wait "$S-w" --text Loading --timeout 5000 >/dev/null
out=$("$HT" wait "$S-w" --text-gone Loading --timeout 5000)
check "text-gone waits for the text to go" sh -c 'printf "%s\n" "$1" | grep -q "wait=ok(gone)" && printf "%s\n" "$1" | grep -qx Done' _ "$out"

# Diff markers per --client.
"$HT" screen "$S-w" --diff --client one >/dev/null
check "client one has seen everything" sh -c '"$1" screen "$2" --diff --client one | grep -q "changed=0"' _ "$HT" "$S-w"
# A client that has seen nothing yet gets every row.
check "client two has its own marker" sh -c '"$1" screen "$2" --diff --client two | grep -q "changed=5"' _ "$HT" "$S-w"
"$HT" kill "$S-w"

# Mouse input is refused unless the program asked for it.
"$HT" start "$S-x" -- sleep 30 >/dev/null
set +e
err=$("$HT" send "$S-x" '<Click 1,2>' 2>&1)
rc=$?
set -e
check "mouse refused without mouse reporting" sh -c '[ "$1" -eq 2 ] && printf "%s" "$2" | grep -q "has not enabled mouse reporting"' _ "$rc" "$err"
"$HT" kill "$S-x"

# Mouse: a drag in SGR mode with button-event tracking (1002) sends press,
# motion and release.
"$HT" start "$S-x" --cols 40 --rows 4 -- /bin/sh -c 'printf "\033[?1002h\033[?1006h"; stty raw -echo; dd bs=1 count=38 2>/dev/null | tr "\033" E; sleep 30' >/dev/null
"$HT" wait "$S-x" --idle 300 --timeout 5000 >/dev/null
"$HT" send "$S-x" '<Drag 0,0 0,2>'
check "drag sends press, motion and release" quiet "$HT" wait "$S-x" --text 'E[<0;1;1ME[<32;2;1ME[<32;3;1ME[<0;3;1m' --timeout 5000
"$HT" kill "$S-x"

# Recording.
"$HT" start "$S-r" --record "$STATE/s.cast" --cols 30 --rows 4 -- /bin/sh -c 'read x; echo got:$x' >/dev/null
"$HT" send "$S-r" hi '<Enter>'
"$HT" wait "$S-r" --exit --timeout 5000 >/dev/null
"$HT" kill "$S-r"
check "recording header" sh -c 'head -1 "$1" | grep -q "^{\"version\":2,\"width\":30,\"height\":4,"' _ "$STATE/s.cast"
check "recording has input and output events" sh -c 'grep -q "\"i\", \"hi\\\\r\"" "$1" && grep -q "\"o\", .*got:hi" "$1"' _ "$STATE/s.cast"

# Help and version.
check "version" sh -c '"$1" --version | grep -q "^headterm [0-9]"' _ "$HT"
check "help for a command" sh -c '"$1" help wait | grep -q -- "--text-gone" && "$1" send --help | grep -q "<Drag r1,c1 r2,c2>"' _ "$HT"

# A session with --ttl ends by itself once idle.
"$HT" start "$S-t" --ttl 1 -- sleep 30 >/dev/null
check "ttl is reported" sh -c '"$1" list --json | grep -q "\"ttl_s\":1"' _ "$HT"
sleep 2.5
check "session expired after its ttl" sh -c '! "$1" list | grep -q "^$2 "' _ "$HT" "$S-t"

set +e
err=$("$HT" start "$S" -- /nonexistent/program 2>&1)
rc=$?
set -e
check "exec failure reported by start" sh -c '[ "$1" -ne 0 ] && printf "%s" "$2" | grep -q "FileNotFound"' _ "$rc" "$err"

echo "smoke: all passed"
