#!/bin/bash
# Build the Thunderstore package (r2modman / Thunderstore Mod Manager layout for
# unreal-shimloader: the "mod" folder goes to shimloader's --mod-dir).
#   votv/mod/package.sh [OUT_DIR]
set -euo pipefail
HERE=$(dirname "$(readlink -f "$0")")
OUT="${1:-$HERE/dist}"
ver=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version_number'])" "$HERE/manifest.json")
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp "$HERE/manifest.json" "$HERE/icon.png" "$stage/"
cp "$HERE/README.md" "$stage/README.md"
mkdir -p "$stage/mod"
cp -r "$HERE/TotVOS/Scripts" "$stage/mod/Scripts"
touch "$stage/mod/enabled.txt"
mkdir -p "$OUT"
(cd "$stage" && zip -qr "$OUT/TotV-TotVOS-$ver.zip" .)
echo "$OUT/TotV-TotVOS-$ver.zip"
