#!/bin/bash
set -euo pipefail
tools="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$tools/../../.." && pwd)"
contents="${1:?Staging Contents required}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/untitled-webp.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
cp -R "$tools/../Resources/KaTeX" "$contents/Resources/KaTeX"
license="$contents/Resources/Licenses/libwebp"
mkdir -p "$license"
cp "$tools/WebPEncoder/LICENSE" "$tools/WebPEncoder/PATENTS" "$license/"
encoder="$contents/Helpers/img2webp"
read -r -a archs <<< "${UNTITLED_BUILD_ARCHS:-$(uname -m)}"
binaries=()
for arch in "${archs[@]}"; do
    "$root/scripts/build-webp-encoder.sh" "$scratch/img2webp-$arch" "$arch"
    binaries+=("$scratch/img2webp-$arch")
done
xcrun lipo -create "${binaries[@]}" -output "$encoder"
signing="${UNTITLED_SIGNING_IDENTITY:--}"
if [[ "$signing" == "-" ]]; then
    /usr/bin/codesign --force --sign - "$encoder"
else
    /usr/bin/codesign --force --sign "$signing" --options runtime --timestamp "$encoder"
fi
/usr/bin/codesign --verify --strict "$encoder"
