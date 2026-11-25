#!/bin/sh
# harness-desk.app for Apple Silicon and Intel Macs in one bundle, signed ad
# hoc (it opens through System Settings › Privacy & Security › Open Anyway on
# its first run), zipped, with its SHA-256 beside it. One download: the
# bundle carries harness (both kinds of Mac too) at Contents/MacOS/harness,
# where the app looks for it, and the fit files at
# Contents/Resources/desk-assets/, where harness looks for them.
#
# usage: scripts/package-macos.sh VERSION OUT.zip
#
# ZIG names the compiler (default: zig on PATH); ZIG_FLAGS are added to each
# of the app's builds and HARNESS_ZIG_FLAGS to each of harness's (e.g.
# --cache-dir DIR).
#
# The fit files (DESK_ASSETS):
#   unset   harness/scripts/pack-desk-assets.sh makes them: MediaPipe's
#           files fetched at their pinned hashes, and the base head from the
#           repository. Anything missing fails, with its one line. (Release.)
#   DIR     a desk-assets folder made already, checked for the same files.
#   none    left out, and said: for CI and tests, with no network and no
#           base head. The app then has no fit files; the desk says so.
set -eu

VERSION=${1:?usage: package-macos.sh VERSION OUT.zip}
OUT=${2:?usage: package-macos.sh VERSION OUT.zip}
case $OUT in /*) ;; *) OUT=$(pwd)/$OUT ;; esac
ZIG=${ZIG:-zig}
case ${DESK_ASSETS:-} in "" | none | /*) ;; *) DESK_ASSETS=$(pwd)/$DESK_ASSETS ;; esac
cd "$(dirname "$0")/.."
HARNESS=$(cd .. && pwd)

W=$(mktemp -d "${TMPDIR:-/tmp}/desk-package.XXXXXX")
trap 'rm -rf "$W"' EXIT
fail() {
    echo "package-macos: $1" >&2
    exit 1
}

# what the desk's fit needs (harness's appserver.zig fit_files; the same list
# as harness/scripts/pack-desk-assets.sh)
FIT_FILES="mediapipe/vision_bundle.mjs mediapipe/wasm/vision_wasm_internal.js mediapipe/wasm/vision_wasm_internal.wasm
mediapipe/wasm/vision_wasm_nosimd_internal.js mediapipe/wasm/vision_wasm_nosimd_internal.wasm mediapipe/face_landmarker.task
base-head.bin LICENSE-mediapipe.txt THIRD-PARTY-mediapipe.txt NOTICE.txt"

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
    ASSETS=$DESK_ASSETS
    ;;
esac
if [ -n "$ASSETS" ]; then
    for f in $FIT_FILES; do
        [ -s "$ASSETS/$f" ] || fail "$f is missing from $ASSETS; nothing was packaged."
    done
fi

for arch in aarch64 x86_64; do
    # shellcheck disable=SC2086
    "$ZIG" build app -Doptimize=ReleaseSafe -Dstrip=true -Dtarget=$arch-macos -Dversion="$VERSION" --prefix "$W/$arch" ${ZIG_FLAGS:-}
    # harness, as its release builds it, for macOS 12 and later like the app
    # shellcheck disable=SC2086
    (cd "$HARNESS" && "$ZIG" build -Doptimize=ReleaseSafe -Dstrip=true -Dtarget=$arch-macos.12.0 --prefix "$W/harness-$arch" ${HARNESS_ZIG_FLAGS:-})
done
APP=$W/harness-desk.app
cp -R "$W/aarch64/harness-desk.app" "$APP"
lipo -create "$W/aarch64/harness-desk.app/Contents/MacOS/harness-desk" "$W/x86_64/harness-desk.app/Contents/MacOS/harness-desk" \
    -output "$APP/Contents/MacOS/harness-desk"
lipo -create "$W/harness-aarch64/bin/harness" "$W/harness-x86_64/bin/harness" -output "$APP/Contents/MacOS/harness"
for bin in harness-desk harness; do
    archs=$(lipo -archs "$APP/Contents/MacOS/$bin")
    [ "$archs" = "x86_64 arm64" ] || fail "$bin isn't for both Macs: $archs"
done
plutil -lint -s "$APP/Contents/Info.plist"

if [ -n "$ASSETS" ]; then
    cp -R "$ASSETS" "$APP/Contents/Resources/desk-assets"
    echo "desk-assets: from $ASSETS"
else
    echo "desk-assets: left out (DESK_ASSETS=none); this app has no fit files"
fi

# the program inside first, then the bundle, which seals it and the
# resources (codesign signs nested code from the inside out)
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/harness"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT" "$OUT.sha256"
ditto -c -k --keepParent "$APP" "$OUT"
(cd "$(dirname "$OUT")" && shasum -a 256 "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "$OUT: harness-desk.app $VERSION (x86_64 arm64), harness $("$APP/Contents/MacOS/harness" version | sed 's/^harness //')"
