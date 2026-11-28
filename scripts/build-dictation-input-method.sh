#!/bin/bash
set -euo pipefail
# The caller supplies a fresh staging path; never delete or overwrite an installed input method.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:?output bundle required}"
configuration="${2:-release}"
[[ "$configuration" == release || "$configuration" == debug ]]
[[ ! -e "$out" ]] || { echo '输入法暂存位置已存在。' >&2; exit 1; }
cd "$root"
swift build --configuration "$configuration" --product UntitledDictationInputMethod
bin="$(swift build --configuration "$configuration" --show-bin-path)"
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
cp Plugins/doubao-speech-input/IME/Resources/Waveform.tiff "$out/Contents/Resources/"
cp Plugins/doubao-speech-input/IME/Resources/Info.plist "$out/Contents/Info.plist"
cp "$bin/UntitledDictationInputMethod" "$out/Contents/MacOS/UntitledDictationInputMethod"
