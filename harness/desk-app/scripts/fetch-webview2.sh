#!/bin/sh
# Microsoft's WebView2 package for the Windows app, pinned: its header
# (WebView2.h) for the build and its loader (WebView2Loader.dll), which
# ships beside harness-desk.exe. Downloaded from NuGet, checked against the
# SHA-256 below, and unpacked into DIR; nothing in it is run.
# usage: scripts/fetch-webview2.sh DIR      then: zig build app -Dwebview2=DIR
# To move to a newer package: change both lines, and check the new one's
# licence (LICENSE.txt in it) still lets the loader be passed on.
set -eu

VERSION=1.0.4370.26
SHA256=1c0dacac84b70109b3fd42f90c53a0ba942abc3a87590d7a4e0ccd86e4a06cf4

DIR=${1:?usage: fetch-webview2.sh DIR}
PY=python3
command -v $PY > /dev/null 2>&1 || PY=python
mkdir -p "$DIR"
pkg="$DIR/microsoft.web.webview2.$VERSION.nupkg"
if [ ! -f "$pkg" ]; then
    curl -fsSL --retry 3 -o "$pkg.part" "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$VERSION/microsoft.web.webview2.$VERSION.nupkg"
    mv "$pkg.part" "$pkg"
fi
got=$($PY -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$pkg")
if [ "$got" != "$SHA256" ]; then
    echo "the WebView2 package isn't the pinned one: its SHA-256 is $got, not $SHA256" >&2
    rm -f "$pkg"
    exit 1
fi
# (a .nupkg is a zip)
$PY -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$pkg" "$DIR"
[ -f "$DIR/build/native/include/WebView2.h" ] || { echo "no WebView2.h in the package" >&2; exit 1; }
echo "$DIR: Microsoft.Web.WebView2 $VERSION"
