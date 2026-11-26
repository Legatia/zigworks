#!/bin/sh
# Copies a desk-assets folder made already (SRC) into DEST by name: the
# files the fit needs (the list scripts/pack-desk-assets.sh checks) and the
# licence and notice files at SRC's top. Nothing else SRC holds is copied: a
# working folder may hold other heads and portraits, which don't ship.
# A file the fit needs that is missing or empty fails, with its one line.
#
#   sh scripts/copy-desk-assets.sh SRC DEST        (run from anywhere)
set -eu

if [ $# -ne 2 ]; then
	echo "usage: sh scripts/copy-desk-assets.sh SRC DEST" >&2
	exit 2
fi
src=$1
dest=$2

say() { echo "copy-desk-assets: $1" >&2; }

if [ ! -d "$src" ]; then
	say "$src isn't a folder."
	exit 1
fi
# what the desk needs (appserver.zig's fit_files)
files="mediapipe/vision_bundle.mjs
mediapipe/wasm/vision_wasm_internal.js mediapipe/wasm/vision_wasm_internal.wasm
mediapipe/wasm/vision_wasm_nosimd_internal.js mediapipe/wasm/vision_wasm_nosimd_internal.wasm
mediapipe/face_landmarker.task base-head.bin LICENSE-mediapipe.txt THIRD-PARTY-mediapipe.txt NOTICE.txt"
for f in $files; do
	if [ ! -s "$src/$f" ]; then
		say "$f is missing from $src; nothing was copied."
		exit 1
	fi
done
mkdir -p "$dest/mediapipe/wasm"
for f in $files; do
	cp "$src/$f" "$dest/$f"
done
# the base head's licence or notice files: *LICENSE* and *NOTICE*, any case
for f in "$src"/*[Ll][Ii][Cc][Ee][Nn][Ss][Ee]* "$src"/*[Nn][Oo][Tt][Ii][Cc][Ee]*; do
	if [ -f "$f" ]; then cp "$f" "$dest/"; fi
done
echo "copied $dest"
