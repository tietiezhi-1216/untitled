#!/bin/bash
set -euo pipefail

# This script is run by the protected GitHub-hosted macOS release job.
channel="${1:?Specify preview or stable}"
output="${2:?Specify a new package directory}"
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${UNTITLED_DEVELOPER_ID_P12:?Configure UNTITLED_DEVELOPER_ID_P12 in the release environment}"
: "${UNTITLED_DEVELOPER_ID_PASSWORD:?Configure UNTITLED_DEVELOPER_ID_PASSWORD in the release environment}"

package_flags=(--require-developer-id)
if [[ -n "${UNTITLED_DEVELOPER_ID_TEAM:-}" ]]; then
    package_flags+=(--team "$UNTITLED_DEVELOPER_ID_TEAM")
fi
case "$channel" in
    preview) package_flags+=(--preview) ;;
    stable)
        : "${UNTITLED_DEVELOPER_ID_TEAM:?Configure the Developer ID team for notarization}"
        : "${UNTITLED_NOTARY_APPLE_ID:?Configure UNTITLED_NOTARY_APPLE_ID in the release environment}"
        : "${UNTITLED_NOTARY_PASSWORD:?Configure UNTITLED_NOTARY_PASSWORD in the release environment}"
        ;;
    *) echo "Unknown release channel: $channel" >&2; exit 1 ;;
esac

umask 077
temporary="$(mktemp -d "${RUNNER_TEMP:?}/untitled-sign.XXXXXX")"
keychain="$temporary/signing.keychain-db"
keychain_password="$(/usr/bin/openssl rand -hex 32)"
original_keychains=()
while IFS= read -r existing; do
    original_keychains+=("$existing")
done < <(/usr/bin/security list-keychains -d user | /usr/bin/sed -nE 's/^[[:space:]]*"(.+)"$/\1/p')

cleanup() {
    /usr/bin/security list-keychains -d user -s ${original_keychains[@]+"${original_keychains[@]}"} || true
    /usr/bin/security delete-keychain "$keychain" >/dev/null 2>&1 || true
    rm -rf "$temporary"
}
trap cleanup EXIT

printf '%s' "$UNTITLED_DEVELOPER_ID_P12" | /usr/bin/base64 -D > "$temporary/signing.p12"
/usr/bin/security create-keychain -p "$keychain_password" "$keychain"
/usr/bin/security set-keychain-settings -lut 3600 "$keychain"
/usr/bin/security unlock-keychain -p "$keychain_password" "$keychain"
/usr/bin/security import "$temporary/signing.p12" -f pkcs12 -P "$UNTITLED_DEVELOPER_ID_PASSWORD" -t agg -k "$keychain" -T /usr/bin/codesign
/usr/bin/security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
/usr/bin/security list-keychains -d user -s "$keychain" ${original_keychains[@]+"${original_keychains[@]}"}
rm "$temporary/signing.p12"
unset UNTITLED_DEVELOPER_ID_P12 UNTITLED_DEVELOPER_ID_PASSWORD

identity="$(/usr/bin/security find-identity -v -p codesigning "$keychain" |
    /usr/bin/awk '/"Developer ID Application:/ { print $2 }')"
if [[ ! "$identity" =~ ^[[:xdigit:]]{40}$ ]]; then
    echo "The certificate must provide exactly one valid Developer ID Application identity and private key." >&2
    exit 1
fi

# The build receives the certificate selector. The notarization login stays in this shell.
/usr/bin/env -u UNTITLED_NOTARY_APPLE_ID -u UNTITLED_NOTARY_PASSWORD \
    UNTITLED_SIGNING_IDENTITY="$identity" ./scripts/build-app.sh release
app="$PWD/dist/release/Untitled.app"
if [[ "$channel" == stable ]]; then
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$temporary/Untitled.zip"
    /usr/bin/xcrun notarytool submit "$temporary/Untitled.zip" \
        --apple-id "$UNTITLED_NOTARY_APPLE_ID" --team-id "$UNTITLED_DEVELOPER_ID_TEAM" \
        --password "$UNTITLED_NOTARY_PASSWORD" --wait --timeout 30m --output-format json > "$temporary/notary.json"
    python3 - "$temporary/notary.json" <<'PY'
import json
from pathlib import Path
import sys

result = json.loads(Path(sys.argv[1]).read_text())
if result["status"] != "Accepted":
    sys.exit(f"Apple notarization {result['id']}: {result['status']}. Inspect it with notarytool log.")
print(f"Apple notarization accepted: {result['id']}")
PY
    /usr/bin/xcrun stapler staple "$app"
fi
python3 "$script_directory/package-app-release.py" --app "$app" --output "$output" "${package_flags[@]}"
