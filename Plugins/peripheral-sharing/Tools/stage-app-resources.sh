#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
contents="${1:?Staging Contents required}"
UNTITLED_AUDIO_ARCHS="${UNTITLED_BUILD_ARCHS:-$(uname -m)}" "$root/scripts/build-sharing-microphone.sh" "$contents/Resources/PeripheralAudio"
