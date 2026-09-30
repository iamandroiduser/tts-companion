#!/usr/bin/env bash
# tts-companion — speak Claude Code replies (Stop) and alerts (Notification).
# Engines: piper (free, offline, neural) | edge (free, online, no API key) |
#          say (macOS built-in) | espeak (espeak-ng / espeak / spd-say fallback).
# Contract: never block Claude Code. Always exit 0.
# Set TTS_DEBUG=1 to log which engine ran to stderr.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 0
tts_load_config
[[ "$ENABLED" == "1" ]] || exit 0

debug() { [[ "${TTS_DEBUG:-0}" == "1" ]] && echo "tts-companion: $*" >&2; return 0; }

input=$(cat)
event=$(tts_json hook_event_name <<<"$input")
case "$event" in
  Stop)         [[ "$SPEAK_REPLIES" == "1" ]]       || exit 0; text=$(tts_json last_assistant_message <<<"$input") ;;
  Notification) [[ "$SPEAK_NOTIFICATIONS" == "1" ]] || exit 0; text=$(tts_json message <<<"$input") ;;
  *)            text=$(tts_json message <<<"$input") ;;
esac

# Make markdown speakable: drop code blocks, inline code, URLs, heading/quote/list
# markers, emphasis and table pipes; flatten; cap length at a word boundary.
text=$(awk 'BEGIN{c=0} /^[[:space:]]*```/{c=!c; next} !c{print}' <<<"$text" \
  | sed -E -e 's/`[^`]*`//g' -e 's#https?://[^ )>]*# link #g' \
           -e 's/^[[:space:]]*([#>]+|[-*+]|[0-9]+\.)[[:space:]]+//' \
           -e 's/(\*\*|__|\*)//g' -e 's/\|/ /g' \
  | tr '\n' ' ' | tr -s ' ')
if (( ${#text} > MAX_CHARS )); then
  text="${text:0:MAX_CHARS}"
  text="${text% *}"
fi
[[ -z "${text// /}" ]] && exit 0

# Don't talk over ourselves: stop the previous run of *this* script (tracked by
# pid file) and its players. Never pattern-match other users' processes.
PIDFILE="${TMPDIR:-/tmp}/tts-companion-$(id -u).pid"
descendants() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done; }
# Serialize the hand-off (not the speech) so two hooks firing at once can't both
# miss each other; a lock left by a crashed run is taken over after ~1s.
HANDOFF="$PIDFILE.lock"
for _ in {1..20}; do mkdir "$HANDOFF" 2>/dev/null && break; sleep 0.05; done
if old=$(cat "$PIDFILE" 2>/dev/null) && [[ "$old" =~ ^[0-9]+$ && "$old" != "$$" ]] \
   && ps -p "$old" -o args= 2>/dev/null | grep -q 'tts-speak'; then
  kids=$(descendants "$old")
  kill "$old" 2>/dev/null
  # shellcheck disable=SC2086
  [[ -n "$kids" ]] && kill $kids 2>/dev/null
fi
echo "$$" > "$PIDFILE" 2>/dev/null
rmdir "$HANDOFF" 2>/dev/null

TMPFILES=()
cleanup() {
  rm -f "${TMPFILES[@]}" 2>/dev/null
  [[ "$(cat "$PIDFILE" 2>/dev/null)" == "$$" ]] && rm -f "$PIDFILE"
}
trap cleanup EXIT
trap 'exit 0' TERM INT

have() { command -v "$1" >/dev/null 2>&1; }

# Play an audio file with whatever player exists (WAV or MP3).
play_file() {
  local f="$1"
  if   [[ "$f" == *.wav ]] && have aplay;  then aplay -q "$f"
  elif [[ "$f" == *.wav ]] && have paplay; then paplay "$f"
  elif [[ "$f" == *.wav ]] && have pw-play; then pw-play "$f"
  elif have afplay; then afplay "$f"
  elif have ffplay; then ffplay -nodisp -autoexit -loglevel quiet "$f"
  elif have mpv;    then mpv --really-quiet --no-video "$f"
  elif [[ "$f" == *.mp3 ]] && have mpg123; then mpg123 -q "$f"
  else return 1
  fi 2>/dev/null
}

# Pick the configured voice, else the default voice, else any installed voice.
piper_model() {
  local v m
  for v in "$PIPER_VOICE" "$TTS_DEFAULT_VOICE"; do
    [[ -f "$PIPER_ROOT/$v.onnx" ]] && { echo "$PIPER_ROOT/$v.onnx"; return 0; }
  done
  for m in "$PIPER_ROOT"/*.onnx; do
    [[ -f "$m" ]] && { echo "$m"; return 0; }
  done
  return 1
}

speak_piper() {
  local piper="$PIPER_ROOT/bin/piper" model rate f
  [[ -x "$piper" ]] || { debug "piper: no binary at $piper"; return 1; }
  model=$(piper_model) || { debug "piper: no voice in $PIPER_ROOT"; return 1; }
  debug "piper: $model"
  if have aplay; then
    # Stream raw PCM so speech starts before synthesis finishes.
    rate=$(tts_json audio.sample_rate "$model.json")
    printf '%s' "$text" | "$piper" --model "$model" --output_raw 2>/dev/null \
      | aplay -q -r "${rate:-22050}" -f S16_LE -c 1 -t raw - 2>/dev/null
    local st=("${PIPESTATUS[@]}")
    (( st[1] == 0 && st[2] == 0 ))
    return
  fi
  f=$(mktemp "${TMPDIR:-/tmp}/tts-companion.XXXXXX") || return 1
  TMPFILES+=("$f" "$f.wav")
  printf '%s' "$text" | "$piper" --model "$model" --output_file "$f.wav" 2>/dev/null \
    && play_file "$f.wav"
}

speak_edge() {
  local edge f
  edge=$(command -v edge-tts || echo "$HOME/.local/share/edge-tts/bin/edge-tts")
  [[ -x "$edge" ]] || { debug "edge: edge-tts not installed"; return 1; }
  f=$(mktemp "${TMPDIR:-/tmp}/tts-companion.XXXXXX") || return 1
  TMPFILES+=("$f" "$f.mp3")
  debug "edge: $EDGE_VOICE"
  "$edge" --voice "$EDGE_VOICE" --text="$text" --write-media "$f.mp3" 2>/dev/null \
    && play_file "$f.mp3"
}

speak_say() { have say && { debug "say"; say <<<"$text"; }; }

speak_espeak() {
  if   have espeak-ng; then debug "espeak-ng"; espeak-ng -s 165 <<<"$text"
  elif have espeak;    then debug "espeak";    espeak -s 165 <<<"$text"
  elif have spd-say;   then debug "spd-say";   spd-say -w -e <<<"$text" >/dev/null
  else debug "no speech engine found"; return 1
  fi 2>/dev/null
}

case "$ENGINE" in
  piper)  speak_piper  || speak_edge  || speak_say || speak_espeak ;;
  edge)   speak_edge   || speak_piper || speak_say || speak_espeak ;;
  say)    speak_say    || speak_espeak ;;
  *)      speak_espeak || speak_say ;;
esac
exit 0
