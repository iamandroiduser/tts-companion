#!/usr/bin/env bash
# tts-companion — speak Claude Code replies (Stop) and alerts (Notification).
# Engines: piper (free, offline, neural) | edge (free, online, no API key) | espeak (fallback).
# Contract: never block Claude Code. Always exit 0.

PIPER_ROOT="${CLAUDE_PLUGIN_DATA:-$HOME/.local/share/piper}"
CONF="${CLAUDE_PLUGIN_DATA:-$HOME/.claude}/tts.conf"
[[ -f "$CONF" ]] && source "$CONF"
ENGINE="${ENGINE:-piper}"
PIPER_VOICE="${PIPER_VOICE:-en_US-lessac-medium}"
EDGE_VOICE="${EDGE_VOICE:-en-US-AriaNeural}"
MAX_CHARS="${MAX_CHARS:-400}"

input=$(cat)
event=$(jq -r '.hook_event_name // empty' <<<"$input" 2>/dev/null)
if [[ "$event" == "Stop" ]]; then
  text=$(jq -r '.last_assistant_message // empty' <<<"$input")
else
  text=$(jq -r '.message // empty' <<<"$input")
fi

# Strip code fences, inline code, URLs; flatten; cap length
text=$(awk 'BEGIN{c=0} /^```/{c=!c; next} !c{print}' <<<"$text" \
  | sed -e 's/`[^`]*`//g' -e 's|https\?://[^ ]*| link |g' \
  | tr '\n' ' ' | head -c "$MAX_CHARS")
[[ -z "${text// /}" ]] && exit 0

# Don't talk over ourselves
pkill -f 'piper --model' 2>/dev/null
pkill -f 'edge-tts' 2>/dev/null

speak_piper() {
  local piper="$PIPER_ROOT/bin/piper" model="$PIPER_ROOT/$PIPER_VOICE.onnx" rate
  [[ -x "$piper" && -f "$model" ]] || return 1
  rate=$(jq -r '.audio.sample_rate // 22050' "$model.json" 2>/dev/null)
  printf '%s' "$text" | "$piper" --model "$model" --output-raw 2>/dev/null \
    | aplay -r "${rate:-22050}" -f S16_LE -t raw - 2>/dev/null
}

speak_edge() {
  local edge; edge=$(command -v edge-tts || echo "$HOME/.local/share/edge-tts/bin/edge-tts")
  [[ -x "$edge" ]] || return 1
  local f; f=$(mktemp --suffix=.mp3)
  if ! printf '%s' "$text" | "$edge" --voice "$EDGE_VOICE" --write-media "$f" 2>/dev/null; then
    rm -f "$f"; return 1
  fi
  if   command -v ffplay >/dev/null; then ffplay -nodisp -autoexit "$f" 2>/dev/null
  elif command -v mpv    >/dev/null; then mpv --really-quiet "$f" 2>/dev/null
  elif command -v mpg123 >/dev/null; then mpg123 -q "$f" 2>/dev/null
  else rm -f "$f"; return 1
  fi
  rm -f "$f"
}

speak_espeak() { command -v espeak-ng >/dev/null && espeak-ng -s 165 <<<"$text"; }

case "$ENGINE" in
  piper) speak_piper || speak_edge || speak_espeak ;;
  edge)  speak_edge  || speak_piper || speak_espeak ;;
  *)     speak_espeak ;;
esac
exit 0
