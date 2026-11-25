#!/bin/sh
# harness.app for Apple Silicon and Intel Macs in one bundle, signed ad hoc
# (it opens through System Settings › Privacy & Security › Open Anyway on
# its first run), zipped, with its SHA-256 beside it.
# usage: scripts/package-macos.sh VERSION OUT.zip
# ZIG names the compiler (default: zig on PATH); ZIG_FLAGS are added to
# each build (e.g. --cache-dir DIR).
set -eu

VERSION=${1:?usage: package-macos.sh VERSION OUT.zip}
OUT=${2:?usage: package-macos.sh VERSION OUT.zip}
case $OUT in /*) ;; *) OUT=$(pwd)/$OUT ;; esac
ZIG=${ZIG:-zig}
cd "$(dirname "$0")/.."

W=$(mktemp -d "${TMPDIR:-/tmp}/desk-package.XXXXXX")
trap 'rm -rf "$W"' EXIT

for arch in aarch64 x86_64; do
    # shellcheck disable=SC2086
    "$ZIG" build app -Doptimize=ReleaseSafe -Dstrip=true -Dtarget=$arch-macos -Dversion="$VERSION" --prefix "$W/$arch" ${ZIG_FLAGS:-}
done
cp -R "$W/aarch64/harness.app" "$W/harness.app"
lipo -create "$W/aarch64/harness.app/Contents/MacOS/harness-desk" "$W/x86_64/harness.app/Contents/MacOS/harness-desk" \
    -output "$W/harness.app/Contents/MacOS/harness-desk"
archs=$(lipo -archs "$W/harness.app/Contents/MacOS/harness-desk")
[ "$archs" = "x86_64 arm64" ] || { echo "the program isn't for both Macs: $archs" >&2; exit 1; }
plutil -lint -s "$W/harness.app/Contents/Info.plist"

codesign --force --sign - --timestamp=none "$W/harness.app"
codesign --verify --strict --verbose=2 "$W/harness.app"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT" "$OUT.sha256"
ditto -c -k --keepParent "$W/harness.app" "$OUT"
(cd "$(dirname "$OUT")" && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "$OUT: harness.app $VERSION ($archs)"
