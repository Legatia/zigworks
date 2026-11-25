#!/bin/sh
# Downloads the fit's files (MediaPipe tasks-vision 0.10.14 and its face
# landmarker model, Apache 2.0) into DIR/mediapipe/, each checked by
# SHA-256. The desk serves DIR as /desk/assets/ (the data folder's
# desk-assets/). A file already there with the right hash is kept.
#
#   sh tools/fetch-desk-assets.sh DIR
#
# The base head (DIR/base-head.bin) isn't downloaded: tools/make-base-head.html
# makes it from facecap.glb, whose license isn't cleared (README: Avatar packs).
#
# The hashes were taken from the npm package @mediapipe/tasks-vision@0.10.14
# (its tarball checked against the registry's sha512) and match jsDelivr's
# copies; the model's matches the MD5 Google's storage gives for it.
set -eu

if [ $# -ne 1 ]; then
	echo "usage: sh tools/fetch-desk-assets.sh DIR" >&2
	exit 2
fi
dir=$1

npm=https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.14
model=https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task

# path in DIR, URL, SHA-256
files="
mediapipe/vision_bundle.mjs $npm/vision_bundle.mjs e77f281f9619150d937023c355bae170e9120e3b9e43f1e23a2a7bee07197669
mediapipe/wasm/vision_wasm_internal.js $npm/wasm/vision_wasm_internal.js 9440cf0cc0cea21800e31581ec32aeedcc5fbf9df4509796bbc7d3f99e52ab9c
mediapipe/wasm/vision_wasm_internal.wasm $npm/wasm/vision_wasm_internal.wasm f82a8e6c05e08a44cc9f9e7ec5f845935bcbb1b1500ebe8c2f4812fb4e2917dc
mediapipe/wasm/vision_wasm_nosimd_internal.js $npm/wasm/vision_wasm_nosimd_internal.js abe9b6fbeaf86fcb53a5edce3926c82ccb0619e18fed4d9d9ce561ee7f55e054
mediapipe/wasm/vision_wasm_nosimd_internal.wasm $npm/wasm/vision_wasm_nosimd_internal.wasm 38b61feab2fd7934e05cbe9f68baa308978a5e3b7f85c1913bb8ae89b8ef8b97
mediapipe/face_landmarker.task $model 64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff
"

if command -v sha256sum >/dev/null 2>&1; then
	sha() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
	sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
	echo "needs sha256sum or shasum" >&2
	exit 1
fi
command -v curl >/dev/null 2>&1 || { echo "needs curl" >&2; exit 1; }

while read -r path url want; do
	[ -n "$path" ] || continue
	out=$dir/$path
	if [ -f "$out" ] && [ "$(sha "$out")" = "$want" ]; then
		echo "kept $path"
		continue
	fi
	mkdir -p "$(dirname "$out")"
	curl -sSfL --retry 3 -o "$out.part" "$url"
	got=$(sha "$out.part")
	if [ "$got" != "$want" ]; then
		rm -f "$out.part"
		echo "$path: SHA-256 $got, expected $want; not kept" >&2
		exit 1
	fi
	mv "$out.part" "$out"
	echo "fetched $path"
done <<EOF
$files
EOF
