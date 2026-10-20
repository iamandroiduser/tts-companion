#!/usr/bin/env bash
# Audition every installed Piper voice, then tell the user where to set their favorite.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$HERE/lib.sh"
tts_load_config
shopt -s nullglob
found=0
for m in "$PIPER_ROOT"/*.onnx; do
  [[ -f "$m.json" ]] || { echo ">>> $(basename "$m" .onnx): incomplete (no .onnx.json), skipped"; continue; }
  found=1
  name=$(basename "$m" .onnx)
  echo ">>> $name"
  printf '{"hook_event_name":"Preview","message":"Hello, this is %s. Your tests all passed."}' "$name" \
    | TTS_VOICE="$name" TTS_ENGINE=piper-only "$HERE/tts-speak.sh"   # never another engine
done
[[ "$found" == "0" ]] && echo "No voices found in $PIPER_ROOT — run $HERE/install.sh first."
echo "Set your favorite in $TTS_USER_CONF  (PIPER_VOICE=<name>)"
