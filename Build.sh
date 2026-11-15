#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd -P)"
scratch="${1:?Specify a fresh build directory outside the source tree}"
mkdir -p "$scratch"
scratch="$(cd "$scratch" && pwd -P)"
case "$scratch/" in "$source_dir/"*) echo "Build outside the source tree." >&2; exit 1;; esac
app="$scratch/Plattersong.app"
[[ ! -e "$app" ]]
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$scratch/cache"
for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target "$arch-apple-macosx13.0" \
    -module-cache-path "$scratch/cache" "$source_dir"/Sources/*.swift -o "$scratch/Plattersong-$arch"
done
xcrun lipo -create "$scratch/Plattersong-arm64" "$scratch/Plattersong-x86_64" -output "$app/Contents/MacOS/Plattersong"
cp "$source_dir/Info.plist" "$app/Contents/Info.plist"
cp "$source_dir/Manual.html" "$source_dir/LICENSE.txt" "$app/Contents/Resources/"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
else
  codesign --force --sign - "$app"
fi
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/Plattersong" --self-test
