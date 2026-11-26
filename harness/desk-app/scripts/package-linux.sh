#!/bin/sh
# harness-desk for Linux (x86_64): one program, linked against the system's
# GTK 3 and WebKitGTK 4.1 (it needs libgtk-3-0 and libwebkit2gtk-4.1-0 where
# it runs, and a C library at least as new as this machine's), in a
# .tar.gz with its SHA-256 beside it. harness in it is static: it needs
# nothing.
#
# One download: harness itself is in it, beside the app (where the app looks
# for it), and the fit files in desk-assets/ beside harness (where harness
# looks for them). HARNESS_ZIG_FLAGS are added to harness's build.
#
# The fit files (DESK_ASSETS), as scripts/package-macos.sh takes them:
#   unset   harness/scripts/pack-desk-assets.sh makes them: MediaPipe's
#           files fetched at their pinned hashes, and the base head from the
#           repository. Anything missing fails, with its one line. (Release.)
#   DIR     a desk-assets folder made already: the same files are copied
#           from it by name (harness/scripts/copy-desk-assets.sh), and
#           nothing else it holds.
#   none    left out, and said: for CI and tests, with no network and no
#           base head. The app then has no fit files; the desk says so.
# usage: scripts/package-linux.sh VERSION OUT.tar.gz
# Needs libgtk-3-dev and libwebkit2gtk-4.1-dev here. ZIG names the compiler
# (default: zig on PATH); ZIG_FLAGS are added to the build.
set -eu

VERSION=${1:?usage: package-linux.sh VERSION OUT.tar.gz}
OUT=${2:?usage: package-linux.sh VERSION OUT.tar.gz}
case $OUT in /*) ;; *) OUT=$(pwd)/$OUT ;; esac
case ${DESK_ASSETS:-} in "" | none | /*) ;; *) DESK_ASSETS=$(pwd)/$DESK_ASSETS ;; esac
ZIG=${ZIG:-zig}
cd "$(dirname "$0")/.."

W=$(mktemp -d "${TMPDIR:-/tmp}/desk-package.XXXXXX")
trap 'rm -rf "$W"' EXIT
HARNESS=$(cd .. && pwd)
fail() {
    echo "package-linux: $1" >&2
    exit 1
}

# the fit files first: a release without them stops before anything is built
case ${DESK_ASSETS:-} in
none) ASSETS= ;;
"")
    ASSETS=$W/desk-assets
    # its own one line says what is missing
    sh "$HARNESS/scripts/pack-desk-assets.sh" "$ASSETS" > /dev/null || exit 1
    ;;
*)
    [ -d "$DESK_ASSETS" ] || fail "DESK_ASSETS=$DESK_ASSETS isn't a folder."
    # by name, never the folder whole: a working folder may hold other heads
    # and portraits (its own one line says what is missing)
    ASSETS=$W/desk-assets
    sh "$HARNESS/scripts/copy-desk-assets.sh" "$DESK_ASSETS" "$ASSETS" > /dev/null || exit 1
    ;;
esac

# (this machine's system, for its libraries; any x86_64 processor)
# shellcheck disable=SC2086
"$ZIG" build app -Doptimize=ReleaseSafe -Dstrip=true -Dcpu=baseline -Dversion="$VERSION" --prefix "$W/out" ${ZIG_FLAGS:-}
name=harness-desk-$VERSION-linux-x86_64
mkdir "$W/$name"
cp "$W/out/harness-desk/harness-desk" "$W/$name/"
[ -x "$W/$name/harness-desk" ] || { echo "the program is missing" >&2; exit 1; }
# it must find its libraries on a machine that has them: none from the build's own folders
if ldd "$W/$name/harness-desk" | grep -q "not found"; then
    echo "the program doesn't find its libraries here:" >&2
    ldd "$W/$name/harness-desk" | grep "not found" >&2
    exit 1
fi

# harness itself beside the app, as its release builds it
# shellcheck disable=SC2086
(cd "$HARNESS" && "$ZIG" build -Doptimize=ReleaseSafe -Dstrip=true -Dtarget=x86_64-linux-musl --prefix "$W/harness-out" ${HARNESS_ZIG_FLAGS:-})
cp "$W/harness-out/bin/harness" "$W/$name/"
cp "$HARNESS/LICENSE" "$W/$name/LICENSE"
[ -s "$W/$name/harness" ] || fail "harness is missing"
if [ -n "$ASSETS" ]; then
    mkdir "$W/$name/desk-assets"
    cp -R "$ASSETS/." "$W/$name/desk-assets/"
else
    echo "package-linux: DESK_ASSETS=none: no fit files in this package (desk-assets/)" >&2
fi

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT" "$OUT.sha256"
tar -C "$W" -czf "$OUT" "$name"
(cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "$OUT: harness-desk $VERSION for Linux (x86_64)"
