#!/bin/sh
# harness-desk for Windows (x86_64): harness-desk.exe with Microsoft's
# WebView2Loader.dll beside it and the loader's licence, zipped, with its
# SHA-256 beside it. It isn't signed: Windows asks before its first run
# (More info › Run anyway).
#
# One download: harness itself is in it, beside the app (where the app looks
# for it), and the fit files in desk-assets/ beside harness (where harness
# looks for them). HARNESS_ZIG_FLAGS are added to harness's build.
#
# The fit files (DESK_ASSETS), as scripts/package-macos.sh takes them:
#   unset   harness/scripts/pack-desk-assets.sh makes them: MediaPipe's
#           files fetched at their pinned hashes, and the base head from the
#           repository. Anything missing fails, with its one line. (Release.)
#   DIR     a desk-assets folder made already, checked for the same files.
#   none    left out, and said: for CI and tests, with no network and no
#           base head. The app then has no fit files; the desk says so.
# usage: scripts/package-windows.sh VERSION OUT.zip WEBVIEW2_DIR
# WEBVIEW2_DIR is what scripts/fetch-webview2.sh unpacked. ZIG names the
# compiler (default: zig on PATH); ZIG_FLAGS are added to the build.
set -eu

VERSION=${1:?usage: package-windows.sh VERSION OUT.zip WEBVIEW2_DIR}
OUT=${2:?usage: package-windows.sh VERSION OUT.zip WEBVIEW2_DIR}
SDK=${3:?usage: package-windows.sh VERSION OUT.zip WEBVIEW2_DIR}
case $OUT in /* | ?:*) ;; *) OUT=$(pwd)/$OUT ;; esac
case $SDK in /* | ?:*) ;; *) SDK=$(pwd)/$SDK ;; esac
case ${DESK_ASSETS:-} in "" | none | /* | ?:*) ;; *) DESK_ASSETS=$(pwd)/$DESK_ASSETS ;; esac
ZIG=${ZIG:-zig}
PY=python3
command -v $PY > /dev/null 2>&1 || PY=python
cd "$(dirname "$0")/.."

W=$(mktemp -d "${TMPDIR:-/tmp}/desk-package.XXXXXX")
trap 'rm -rf "$W"' EXIT
HARNESS=$(cd .. && pwd)
fail() {
    echo "package-windows: $1" >&2
    exit 1
}

# what the desk's fit needs (the same list as scripts/package-macos.sh)
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

# shellcheck disable=SC2086
"$ZIG" build app -Doptimize=ReleaseSafe -Dstrip=true -Dtarget=x86_64-windows-gnu -Dversion="$VERSION" -Dwebview2="$SDK" --prefix "$W/out" ${ZIG_FLAGS:-}
name=harness-desk-$VERSION-windows
mkdir "$W/$name"
cp "$W/out/harness-desk/harness-desk.exe" "$W/out/harness-desk/WebView2Loader.dll" "$W/$name/"
# the loader is Microsoft's, passed on under its licence, which goes with it
{
    echo "WebView2Loader.dll is Microsoft's, from the NuGet package Microsoft.Web.WebView2, under this licence:"
    echo
    cat "$SDK/LICENSE.txt"
} > "$W/$name/WebView2Loader-LICENSE.txt"
[ -s "$W/$name/harness-desk.exe" ] && [ -s "$W/$name/WebView2Loader.dll" ] || { echo "the program or its loader is missing" >&2; exit 1; }

# harness itself beside the app, as its release builds it
# shellcheck disable=SC2086
(cd "$HARNESS" && "$ZIG" build -Doptimize=ReleaseSafe -Dstrip=true -Dtarget=x86_64-windows-gnu --prefix "$W/harness-out" ${HARNESS_ZIG_FLAGS:-})
cp "$W/harness-out/bin/harness.exe" "$W/$name/"
cp "$HARNESS/LICENSE" "$W/$name/LICENSE"
[ -s "$W/$name/harness.exe" ] || fail "harness is missing"
if [ -n "$ASSETS" ]; then
    mkdir "$W/$name/desk-assets"
    cp -R "$ASSETS/." "$W/$name/desk-assets/"
else
    echo "package-windows: DESK_ASSETS=none: no fit files in this package (desk-assets/)" >&2
fi

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT" "$OUT.sha256"
(cd "$W" && $PY -c 'import sys, zipfile, os
with zipfile.ZipFile(sys.argv[2], "w", zipfile.ZIP_DEFLATED) as z:
    for d, dirs, files in os.walk(sys.argv[1]):
        dirs.sort()
        for f in sorted(files):
            p = os.path.join(d, f)
            z.write(p, p.replace(os.sep, "/"))' "$name" "$OUT")
(cd "$(dirname "$OUT")" && $PY -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest() + "  " + sys.argv[1])' "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "$OUT: harness-desk $VERSION for Windows (x86_64)"
