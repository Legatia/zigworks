#!/bin/sh
# harness-desk for Windows (x86_64): harness-desk.exe with Microsoft's
# WebView2Loader.dll beside it and the loader's licence, zipped, with its
# SHA-256 beside it. It isn't signed: Windows asks before its first run
# (More info › Run anyway).
# usage: scripts/package-windows.sh VERSION OUT.zip WEBVIEW2_DIR
# WEBVIEW2_DIR is what scripts/fetch-webview2.sh unpacked. ZIG names the
# compiler (default: zig on PATH); ZIG_FLAGS are added to the build.
set -eu

VERSION=${1:?usage: package-windows.sh VERSION OUT.zip WEBVIEW2_DIR}
OUT=${2:?usage: package-windows.sh VERSION OUT.zip WEBVIEW2_DIR}
SDK=${3:?usage: package-windows.sh VERSION OUT.zip WEBVIEW2_DIR}
case $OUT in /* | ?:*) ;; *) OUT=$(pwd)/$OUT ;; esac
case $SDK in /* | ?:*) ;; *) SDK=$(pwd)/$SDK ;; esac
ZIG=${ZIG:-zig}
PY=python3
command -v $PY > /dev/null 2>&1 || PY=python
cd "$(dirname "$0")/.."

W=$(mktemp -d "${TMPDIR:-/tmp}/desk-package.XXXXXX")
trap 'rm -rf "$W"' EXIT

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

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT" "$OUT.sha256"
(cd "$W" && $PY -c 'import sys, zipfile, os
with zipfile.ZipFile(sys.argv[2], "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted(os.listdir(sys.argv[1])):
        z.write(os.path.join(sys.argv[1], f), sys.argv[1] + "/" + f)' "$name" "$OUT")
(cd "$(dirname "$OUT")" && $PY -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest() + "  " + sys.argv[1])' "$(basename "$OUT")" > "$(basename "$OUT").sha256")
echo "$OUT: harness-desk $VERSION for Windows (x86_64)"
