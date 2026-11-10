#!/bin/sh
# compare.sh DIR PATTERN [extra flags]: diff trigrep against ripgrep on DIR.
dir="$1"; pat="$2"; shift 2
TG="${TRIGREP:-$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/trigrep}"
out=$(mktemp -d)
(cd "$dir" && rg -n --no-heading "$@" -e "$pat" . | sort) > "$out/rg"
(cd "$dir" && "$TG" "$@" -e "$pat" . | sort) > "$out/tg"
if cmp -s "$out/rg" "$out/tg"; then echo "same  $(wc -l < "$out/rg" | tr -d ' ') lines  [$pat] $*"
else echo "DIFF  rg=$(wc -l < "$out/rg" | tr -d ' ') tg=$(wc -l < "$out/tg" | tr -d ' ')  [$pat] $*"; diff "$out/rg" "$out/tg" | head -8; fi
rm -rf "$out"
