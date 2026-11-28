#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${1:-debug}"

case "$configuration" in
    debug|release) ;;
    *) echo "用法：$0 [debug|release]" >&2; exit 1 ;;
esac

if [[ ${UNTITLED_SIGNING_IDENTITY+x} ]]; then
    signing_identity="$UNTITLED_SIGNING_IDENTITY"
elif [[ -f "$project_root/.signing-identity" ]]; then
    signing_identity="$(tr -d '\r\n' < "$project_root/.signing-identity")"
else
    signing_identity="-"
fi

signing_arguments=(--sign "$signing_identity")
if [[ "$signing_identity" != "-" ]]; then
    if [[ ! "$signing_identity" =~ ^[[:xdigit:]]{40}$ ]]; then
        echo "签名配置必须是证书的 40 位 SHA-1，或显式使用 - 进行临时签名。" >&2
        exit 1
    fi
    signing_identity="$(printf '%s' "$signing_identity" | tr '[:lower:]' '[:upper:]')"
    available_identities="$(/usr/bin/security find-identity -v -p codesigning)"
    if ! /usr/bin/grep -Fq -- "$signing_identity" <<< "$available_identities"; then
        echo "找不到配置的有效签名身份，请先导入证书及配对私钥：$signing_identity" >&2
        exit 1
    fi
    signing_arguments=(--sign "$signing_identity" --options runtime --timestamp
        --entitlements "$project_root/Resources/Untitled-DeveloperID.entitlements")
fi

cd "$project_root"
# Float with the active developer toolchain, not a stale SDKROOT from the caller.
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
minimum_version="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw Resources/Info.plist)"
if [[ ! -d "$SDKROOT" || ! "$sdk_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ || ${sdk_version%%.*} -lt 26 ]]; then
    echo '需要 macOS 26 或更新的 SDK；请更新或切换 Xcode / Command Line Tools。' >&2
    exit 1
fi
printf '使用 macOS SDK %s，最低运行版本 %s\n' "$sdk_version" "$minimum_version"

python3 scripts/prepare-plugin-resources.py --check
# SwiftPM's Swift Build backend can use the SDK headers but record the deployment
# version as the linked SDK. Pass the actual SDK version to ld as well.
build_arguments=(--configuration "$configuration" --sdk "$SDKROOT"
    -Xlinker -platform_version -Xlinker macos -Xlinker "$minimum_version" -Xlinker "$sdk_version")
swift build "${build_arguments[@]}" --product Untitled
binary_directory="$(swift build "${build_arguments[@]}" --show-bin-path)"
output_directory="$project_root/dist/$configuration"
app_bundle="$output_directory/Untitled.app"
mkdir -p "$output_directory"
staging_directory="$(mktemp -d "$output_directory/.build.XXXXXX")"
trap 'rm -rf "$staging_directory"' EXIT
staged_bundle="$staging_directory/Untitled.app"

mkdir -p "$staged_bundle/Contents/MacOS" "$staged_bundle/Contents/Resources"
cp "$binary_directory/Untitled" "$staged_bundle/Contents/MacOS/Untitled"
cp "$project_root/Resources/Info.plist" "$staged_bundle/Contents/Info.plist"
cp "$project_root/Sources/Untitled/Resources/BundledPlugins.json" "$staged_bundle/Contents/Resources/BundledPlugins.json"
"$project_root/scripts/build-icon.sh" "$staged_bundle/Contents/Resources/AppIcon.icns"

if [[ -d "$project_root/Resources/KaTeX" ]]; then
    cp -R "$project_root/Resources/KaTeX" "$staged_bundle/Contents/Resources/KaTeX"
fi

UNTITLED_SIGNING_IDENTITY="$signing_identity" "$project_root/scripts/build-sharing-microphone.sh" "$staged_bundle/Contents/Resources/PeripheralAudio"

mkdir -p "$staged_bundle/Contents/Helpers" "$staged_bundle/Contents/Resources/Licenses/libwebp"
cp "$project_root/LICENSE" "$staged_bundle/Contents/Resources/Licenses/Untitled.txt"
"$project_root/scripts/build-webp-encoder.sh" "$staged_bundle/Contents/Helpers/img2webp"
cp "$project_root/Tools/WebPEncoder/LICENSE" "$project_root/Tools/WebPEncoder/PATENTS" "$staged_bundle/Contents/Resources/Licenses/libwebp/"
if [[ "$signing_identity" == "-" ]]; then
    /usr/bin/codesign --force --sign - "$staged_bundle/Contents/Helpers/img2webp"
else
    /usr/bin/codesign --force --sign "$signing_identity" --options runtime --timestamp "$staged_bundle/Contents/Helpers/img2webp"
fi
/usr/bin/codesign --verify --strict "$staged_bundle/Contents/Helpers/img2webp"
/bin/bash scripts/check-app-sdk.sh "$staged_bundle" "$sdk_version"
/usr/bin/codesign --force "${signing_arguments[@]}" "$staged_bundle"
/usr/bin/codesign --verify --strict "$staged_bundle"

# 签名成功后才替换现有构建，失败时保留原应用。
if [[ -e "$app_bundle" ]]; then
    mv "$app_bundle" "$staging_directory/previous.app"
fi
if ! mv "$staged_bundle" "$app_bundle"; then
    if [[ -e "$staging_directory/previous.app" ]]; then
        mv "$staging_directory/previous.app" "$app_bundle"
    fi
    exit 1
fi
echo "已生成：$app_bundle"
echo "签名身份：$signing_identity"
