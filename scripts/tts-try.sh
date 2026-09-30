#!/usr/bin/env bash
# Audition every installed Piper voice, then tell the user where to set their favorite.
PIPER_ROOT="${CLAUDE_PLUGIN_DATA:-$HOME/.local/share/piper}"
shopt -s nullglob
found=0
for m in "$PIPER_ROOT"/*.onnx; do
  found=1
  name=$(basename "$m" .onnx)
  rate=$(jq -r '.audio.sample_rate // 22050' "$m.json" 2>/dev/null)
  echo ">>> $name"
  echo "Hello, this is $name. Your tests all passed." \
    | "$PIPER_ROOT/bin/piper" --model "$m" --output-raw 2>/dev/null \
    | aplay -r "${rate:-22050}" -f S16_LE -t raw - 2>/dev/null
done
[[ "$found" == "0" ]] && echo "No voices found in $PIPER_ROOT — run scripts/install.sh first."
echo "Set your favorite in ${CLAUDE_PLUGIN_DATA:-$HOME/.claude}/tts.conf  (PIPER_VOICE=<name>)"
