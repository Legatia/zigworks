#!/bin/sh
# Every unit test that starts a browser must be one the browser-test step
# runs: with -Dbrowser-tests=false the others skip it, so a test this misses
# would run nowhere. A test starts a browser by calling cdp.testBrowser.
#
#   scripts/check-browser-tests.sh FILTER...
#
# FILTER: what the browser-test step selects by (build.zig), a part of a
# test's full name, FILE.test.NAME. A call inside a test must match one; a
# call outside a test (a helper any test of that file may use) needs
# "FILE.test." itself, the whole file. Run from harness/.
[ $# -gt 0 ] || { echo "usage: check-browser-tests.sh FILTER..." >&2; exit 2; }
awk -v filters="$*" '
BEGIN { n = split(filters, want, " ") }
FNR == 1 { file = FILENAME; sub(/.*\//, "", file); sub(/\.zig$/, "", file); name = "" }
/^test "/ { name = $0; sub(/^test "/, "", name); sub(/".*$/, "", name) }
/^}/ { name = "" }
/fn testBrowser\(/ { next }
/testBrowser\(/ {
    full = file ".test." name
    ok = 0
    for (i = 1; i <= n; i++) if (want[i] != "" && index(full, want[i]) > 0) ok = 1
    if (!ok) {
        bad = 1
        if (name == "") print "src/" file ".zig:" FNR ": a helper starts a browser, and the browser-test step does not run all of " file ".zig (build.zig, browser_filters)"
        else print "src/" file ".zig:" FNR ": " full " starts a browser, and the browser-test step does not run it (build.zig, browser_filters)"
    }
    found++
}
END {
    if (found == 0) { print "no test calls testBrowser: has it been renamed?"; exit 1 }
    exit bad
}' src/*.zig
