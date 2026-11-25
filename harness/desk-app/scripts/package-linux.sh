#!/bin/sh
# harness-desk for Linux (x86_64): one program, linked against the system's
# GTK 3 and WebKitGTK 4.1 (it needs libgtk-3-0 and libwebkit2gtk-4.1-0 where
# it runs, and a C library at least as new as this machine's), in a
# .tar.gz with its SHA-256 beside it.
# usage: scripts/package-linux.sh VERSION OUT.tar.gz
# Needs libgtk-3-dev and libwebkit2gtk-4.1-dev here. ZIG names the compiler
# (default: zig on PATH); ZIG_FLAGS are added to the build.
set -eu

VERSION=${1:?usage: package-linux.sh VERSION OUT.tar.gz}
OUT=${2:?usage: package-linux.sh VERSION OUT.tar.gz}
case $OUT in /*) ;; *) OUT=$(pwd)/$OUT ;; esac
ZIG=${ZIG:-zig}
cd "$(dirname "$0")/.."

W=$(mktemp -d "${TMPDIR:-/tmp}/desk-package.XXXXXX")
trap 'rm -rf "$W"' EXIT

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

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT" "$OUT.sha256"
tar -C "$W" -czf "$OUT" "$name"
(cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "$OUT: harness-desk $VERSION for Linux (x86_64)"
