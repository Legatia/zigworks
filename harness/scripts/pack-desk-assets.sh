#!/bin/sh
# The fit files for a release archive: DEST becomes the desk-assets/ that
# sits beside harness's binary, which the desk serves as /desk/assets/
# when the data folder has no copy. Into DEST:
#   - MediaPipe's files, fetched at their pinned SHA-256s by
#     tools/fetch-desk-assets.sh (a mismatch fails);
#   - the base head, harness/desk-assets/base-head.bin, and the licence or
#     notice files beside it there;
#   - LICENSE-mediapipe.txt (MediaPipe's licence, Apache 2.0),
#     THIRD-PARTY-mediapipe.txt (the libraries its WebAssembly links) and
#     NOTICE.txt (what each file is), from licenses/.
# Then every file the fit needs is checked to be there.
#
#   sh scripts/pack-desk-assets.sh DEST        (any folder; run from anywhere)
#
# FETCH=SCRIPT runs another fetch script in place of tools/fetch-desk-assets.sh
# (for checking this script without the network).
set -eu

if [ $# -ne 1 ]; then
	echo "usage: sh scripts/pack-desk-assets.sh DEST" >&2
	exit 2
fi
dest=$1
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/desk-assets

say() { echo "pack-desk-assets: $1" >&2; }

if [ ! -f "$src/base-head.bin" ]; then
	say "harness/desk-assets/base-head.bin is missing; the archive needs the base head (commit it first)."
	exit 1
fi
# the base head's licence or notice files: *LICENSE* and *NOTICE*, any case
notices() {
	for f in "$src"/*[Ll][Ii][Cc][Ee][Nn][Ss][Ee]* "$src"/*[Nn][Oo][Tt][Ii][Cc][Ee]*; do
		if [ -f "$f" ]; then "$@" "$f"; fi
	done
}
found=0
notices_seen() {
	found=1
	case "$(basename "$1")" in
	NOTICE.txt | LICENSE-mediapipe.txt | THIRD-PARTY-mediapipe.txt)
		say "harness/desk-assets/$(basename "$1") would overwrite the archive's own file of that name; rename it."
		exit 1
		;;
	esac
}
notices notices_seen
if [ $found = 0 ]; then
	say "no LICENSE or NOTICE file beside harness/desk-assets/base-head.bin; the base head's licence must ship with it."
	exit 1
fi

mkdir -p "$dest"
if ! sh "${FETCH:-$here/tools/fetch-desk-assets.sh}" "$dest"; then
	say "MediaPipe's files weren't fetched (a download failed or a hash didn't match); nothing to release."
	exit 1
fi
cp "$src/base-head.bin" "$dest/base-head.bin"
copy_in() { cp "$1" "$dest/"; }
notices copy_in
cp "$here/licenses/mediapipe-LICENSE.txt" "$dest/LICENSE-mediapipe.txt"
cp "$here/licenses/mediapipe-third-party.txt" "$dest/THIRD-PARTY-mediapipe.txt"
cp "$here/licenses/desk-assets-NOTICE.txt" "$dest/NOTICE.txt"

# what the desk needs (appserver.zig's fit_files)
for f in mediapipe/vision_bundle.mjs \
	mediapipe/wasm/vision_wasm_internal.js mediapipe/wasm/vision_wasm_internal.wasm \
	mediapipe/wasm/vision_wasm_nosimd_internal.js mediapipe/wasm/vision_wasm_nosimd_internal.wasm \
	mediapipe/face_landmarker.task base-head.bin LICENSE-mediapipe.txt THIRD-PARTY-mediapipe.txt NOTICE.txt; do
	if [ ! -s "$dest/$f" ]; then
		say "$f is missing from $dest."
		exit 1
	fi
done
echo "packed $dest"
