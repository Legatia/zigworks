#!/bin/sh
# CLI checks that need no screen or camera access (they run in CI).
# usage: scripts/smoke.sh [path/to/headsight]
set -u

HS=${1:-zig-out/bin/headsight}
case $HS in /*) ;; *) HS=$(pwd)/$HS ;; esac

STATE=$(mktemp -d /tmp/headsight-smoke.XXXXXX)
export TMPDIR=$STATE
trap 'rm -rf "$STATE"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# expect <exit code> <text that must appear in stdout+stderr> -- <args...>
expect() {
    want=$1
    text=$2
    shift 3
    out=$("$HS" "$@" 2>&1)
    got=$?
    [ "$got" = "$want" ] || fail "headsight $*: exit $got, want $want; output: $out"
    case $out in *"$text"*) ;; *) fail "headsight $*: output lacks '$text': $out" ;; esac
    echo "ok - headsight $*"
}

expect 0 "snap" -- help
for c in wait diff drop text windows; do
    expect 0 "$c" -- help
done
expect 0 "usage: headsight wait" -- help wait
expect 0 "headsight 0.1.0" -- version
expect 2 "--change" -- wait
expect 2 "--change, --still" -- wait --change --still
expect 2 "X,Y,W,H" -- snap --region 1,2,3
expect 2 "unknown command" -- frobnicate
expect 2 "--since" -- diff
expect 2 'no reference named "missing"' -- drop missing
expect 2 "bad name" -- snap --name ../x

# Output appends when stdout is a file shared by several runs.
OUT=$STATE/out.txt
{ "$HS" version; "$HS" version; "$HS" drop missing; } > "$OUT" 2>&1
[ "$(grep -c 'headsight 0.1.0' "$OUT")" = 2 ] || fail "two runs into one file: $(cat "$OUT")"
grep -q 'no reference named "missing"' "$OUT" || fail "stderr into the same file: $(cat "$OUT")"
echo "ok - output appends to a shared file"

if [ "$(uname)" = Darwin ]; then
    minos=$(otool -l "$HS" | awk '/LC_BUILD_VERSION/ {f=1} f && /minos/ {print $2; exit}')
    [ "$minos" = 14.0 ] || fail "binary needs macOS $minos; the README promises 14.0"
    echo "ok - binary runs on macOS 14"
fi

if [ "$(uname)" != Darwin ]; then
    expect 4 "not supported" -- snap
fi
echo "smoke: all ok"
