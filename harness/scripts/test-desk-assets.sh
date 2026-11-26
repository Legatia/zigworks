#!/bin/sh
# Checks the two scripts that put the fit files in a package, with no
# network (a stand-in fetch writes MediaPipe's file names):
#   - scripts/pack-desk-assets.sh makes the folder a release ships;
#   - scripts/copy-desk-assets.sh copies such a folder by name, so whatever
#     else a working folder holds (other heads, portraits) stays out, and
#     says which file is missing when one is.
#
#   sh scripts/test-desk-assets.sh        (run from anywhere)
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/desk-assets-test.XXXXXX")
trap 'rm -rf "$W"' EXIT
bad=0
check() {
	if eval "$2"; then echo "ok - $1"; else
		echo "not ok - $1"
		bad=1
	fi
}

cat > "$W/fetch.sh" <<'STUB'
#!/bin/sh
set -eu
mkdir -p "$1/mediapipe/wasm"
for f in vision_bundle.mjs face_landmarker.task wasm/vision_wasm_internal.js wasm/vision_wasm_internal.wasm \
	wasm/vision_wasm_nosimd_internal.js wasm/vision_wasm_nosimd_internal.wasm; do
	echo "stand-in $f" > "$1/mediapipe/$f"
done
STUB

FETCH="$W/fetch.sh" sh "$here/scripts/pack-desk-assets.sh" "$W/packed" > /dev/null
check "pack: the release's folder is made" '[ -s "$W/packed/base-head.bin" ] && [ -s "$W/packed/NOTICE.txt" ] && [ -s "$W/packed/mediapipe/face_landmarker.task" ]'
(cd "$W/packed" && find . -type f | sort) > "$W/want.txt"

# a working folder: the same files and what must never ship
cp -R "$W/packed" "$W/working"
echo glb > "$W/working/facecap.glb"
echo jpg > "$W/working/portrait.jpg"
echo bin > "$W/working/mediapipe/other-model.task"
mkdir "$W/working/avatars" && echo x > "$W/working/avatars/still.jpg"
sh "$here/scripts/copy-desk-assets.sh" "$W/working" "$W/copied" > /dev/null
(cd "$W/copied" && find . -type f | sort) > "$W/got.txt"
check "copy: the release's files and nothing else" 'cmp -s "$W/want.txt" "$W/got.txt"'
check "copy: each file whole" 'cmp -s "$W/packed/base-head.bin" "$W/copied/base-head.bin" && cmp -s "$W/packed/mediapipe/wasm/vision_wasm_internal.wasm" "$W/copied/mediapipe/wasm/vision_wasm_internal.wasm"'

rm "$W/working/mediapipe/face_landmarker.task"
check "copy: a missing file is refused, by name" '! sh "$here/scripts/copy-desk-assets.sh" "$W/working" "$W/copied2" > /dev/null 2> "$W/err.txt" && grep -q "mediapipe/face_landmarker.task is missing" "$W/err.txt"'
check "copy: a folder that isn't there is refused" '! sh "$here/scripts/copy-desk-assets.sh" "$W/nowhere" "$W/copied3" > /dev/null 2>&1'

if [ $bad = 0 ]; then echo "desk-assets scripts: ok"; else
	echo "desk-assets scripts: FAILED"
	[ ! -s "$W/got.txt" ] || diff "$W/want.txt" "$W/got.txt" || true
	exit 1
fi
