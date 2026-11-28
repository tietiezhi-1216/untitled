#!/bin/bash
# Runs only reviewed build hooks in the source checkout, never files from an installed plugin ZIP.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:?Build output .app required}"
[[ "$app" == *.app && -d "$app/Contents" && ! -L "$app" ]]
work="$(mktemp -d "${TMPDIR:-/tmp}/untitled-native-assets.XXXXXX")"
trap 'rm -rf "$work"' EXIT
stage="$work/Contents"
mkdir -p "$stage/Resources/Licenses" "$stage/Helpers"
cp "$root/LICENSE" "$stage/Resources/Licenses/Untitled.txt"
export UNTITLED_SIGNING_IDENTITY="${UNTITLED_SIGNING_IDENTITY:--}"
export UNTITLED_BUILD_ARCHS="${UNTITLED_BUILD_ARCHS:-$(uname -m)}"
read -r -a archs <<< "$UNTITLED_BUILD_ARCHS"
[[ "${#archs[@]}" -gt 0 ]]
for arch in "${archs[@]}"; do
    case "$arch" in arm64|x86_64) ;; *) echo "Unsupported app architecture: $arch" >&2; exit 1 ;; esac
done
for hook in "$root"/Plugins/*/Tools/stage-app-resources.sh; do
    [[ -f "$hook" && ! -L "$hook" ]] || continue
    /bin/bash "$hook" "$stage"
done
# Xcode may leave previous build outputs in place; only merge the generated contents.
# Nothing is copied into the destination until all hooks have succeeded.
/usr/bin/ditto "$stage" "$app/Contents"
