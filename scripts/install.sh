#!/usr/bin/env bash
# tts-companion installer — downloads the Piper binary and a default voice.
# Deps: curl, jq, alsa-utils (aplay). Debian/Ubuntu: sudo apt install curl jq alsa-utils
set -euo pipefail

ROOT="${CLAUDE_PLUGIN_DATA:-$HOME/.local/share/piper}"
VOICE="${1:-en_US-lessac-medium}"
mkdir -p "$ROOT/bin"

case "$(uname -m)" in
  x86_64)  asset=piper_linux_x86_64.tar.gz ;;
  aarch64) asset=piper_linux_aarch64.tar.gz ;;
  armv7l)  asset=piper_linux_armv7l.tar.gz ;;
  *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

echo ">> Installing Piper ($asset) into $ROOT/bin"
curl -fL "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/$asset" \
  | tar -xz -C "$ROOT/bin" --strip-components=1

# Voice naming: en_US-lessac-medium -> en/en_US/lessac/medium
lang="${VOICE%%-*}"; lang="${lang%%_*}_${lang#*_}"    # en_US / en_GB (everything before first '-')
name="${VOICE#*-}"                                    # lessac-medium / jenny_dioco-medium
person="${name%-*}"; quality="${name##*-}"            # lessac / medium
base="https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/${lang%%_*}/${lang}/${person}/${quality}"
echo ">> Downloading voice $VOICE"
curl -fLo "$ROOT/$VOICE.onnx"      "$base/$VOICE.onnx"
curl -fLo "$ROOT/$VOICE.onnx.json" "$base/$VOICE.onnx.json"

cat > "${CLAUDE_PLUGIN_DATA:-$HOME/.claude}/tts.conf" <<EOF
ENGINE=piper
PIPER_VOICE=$VOICE
EDGE_VOICE=en-US-AriaNeural
MAX_CHARS=400
EOF

echo ">> Done. Test with:"
echo "   echo '{\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"It works\"}' | \"${CLAUDE_PLUGIN_ROOT:-$HOME/.claude}/scripts/tts-speak.sh\""
