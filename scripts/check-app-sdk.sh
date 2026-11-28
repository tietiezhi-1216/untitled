#!/bin/bash
# Verify the final linked SDK and minimum OS for every architecture, not just compiler flags.
set -euo pipefail
app="${1:?App bundle required}"
expected_sdk="${2:-$(xcrun --sdk macosx --show-sdk-version)}"
expected_minimum="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$app/Contents/Info.plist")"
executable="$(/usr/bin/plutil -extract CFBundleExecutable raw "$app/Contents/Info.plist")"

for binary in "$app/Contents/MacOS/$executable" \
    "$app/Contents/Helpers/img2webp" \
    "$app/Contents/Resources/PeripheralAudio/UntitledMicrophone.driver/Contents/MacOS/UntitledMicrophone"; do
    architectures="$(xcrun lipo -archs "$binary")"
    read -r -a archs <<< "$architectures"
    for arch in "${archs[@]}"; do
        metadata="$(xcrun vtool -arch "$arch" -show-build "$binary")"
        if ! /usr/bin/awk -v sdk="$expected_sdk" -v minimum="$expected_minimum" '
            function normalize(v) { while (sub(/\.[0]+$/, "", v)) {} return "v" v }
            $1 == "platform" { macos = ($2 == "MACOS") }
            $1 == "minos" { minos = $2 }
            $1 == "sdk" { linked = $2 }
            END { exit !(macos && normalize(minos) == normalize(minimum) && normalize(linked) == normalize(sdk)) }
        ' <<< "$metadata"; then
            printf 'SDK 校验失败：%s (%s)，预期 macOS SDK %s，最低运行版本 %s。\n%s\n' \
                "$binary" "$arch" "$expected_sdk" "$expected_minimum" "$metadata" >&2
            exit 1
        fi
        printf '%s (%s): macOS SDK %s, minos %s\n' "${binary##*/}" "$arch" "$expected_sdk" "$expected_minimum"
    done
done
