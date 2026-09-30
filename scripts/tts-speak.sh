#!/usr/bin/env bash
# tts-companion — speak Claude Code replies (Stop) and alerts (Notification).
# Engines: piper (free, offline, neural) | edge (free, online, no API key) |
#          say (macOS built-in) | espeak (espeak-ng / espeak / spd-say fallback).
# Contract: never block Claude Code. Always exit 0.
# Set TTS_DEBUG=1 to log which engine ran to stderr.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 0
tts_load_config
[[ "$TTS_INNER" == 1 ]] && exit 0
[[ "$ENABLED" == "1" ]] || exit 0

debug() { [[ "${TTS_DEBUG:-0}" == "1" ]] && echo "tts-companion: $*" >&2; return 0; }

input=$(cat)
event=$(tts_json hook_event_name <<<"$input")
case "$event" in
  Stop)         [[ "$SPEAK_REPLIES" == "1" ]]       || exit 0; text=$(tts_json last_assistant_message <<<"$input") ;;
  Notification) [[ "$SPEAK_NOTIFICATIONS" == "1" ]] || exit 0; text=$(tts_json message <<<"$input") ;;
  *)            text=$(tts_json message <<<"$input") ;;
esac

[[ -z "${text//[[:space:]]/}" ]] && exit 0

PIDFILE="$TTS_PIDFILE"
HANDOFF="$PIDFILE.lock"

# Slow steps run as background jobs that we `wait` for: bash interrupts `wait`
# as soon as a signal arrives, so a newer reply, `tts-companion stop`, or your
# next prompt takes effect at once (a foreground command would delay the trap
# until it finished). Temp files live in a private per-run directory inside the
# user-only state dir, created here so cleanup sees them all.
TMPD=$(mktemp -d "$TTS_STATE_DIR/run.XXXXXX") || exit 0
TMP="$TMPD/speech"
cleanup() {
  rm -rf "$TMPD" 2>/dev/null
  # Under the hand-off lock, so a newer run can't write its pid between our
  # check and our delete (which would leave its speech untracked).
  if tts_lock "$HANDOFF" 40; then
    [[ "$(cat "$PIDFILE" 2>/dev/null)" == "$$" ]] && rm -f "$PIDFILE"
    tts_unlock "$HANDOFF"
  fi
}
on_term() {
  tts_unlock "$HANDOFF"
  [[ -n "${JOB:-}" ]] && kill -TERM -- "-$JOB" 2>/dev/null   # the job's whole process group
  # shellcheck disable=SC2046
  kill $(tts_descendants $$) 2>/dev/null
  exit 0
}
trap cleanup EXIT
trap on_term TERM INT
set -m    # each background job gets its own process group (see on_term)
# With job control, `wait` also returns when the job is paused (tts-companion
# pause), so keep waiting until it has really finished.
wait_job() { while :; do wait "$JOB"; kill -0 "$JOB" 2>/dev/null || break; sleep 0.2; done; }

# Don't talk over ourselves: stop the previous run of *this* script (tracked by
# pid file) and its players. Never pattern-match other users' processes. Done
# before the text is prepared, so a new reply or prompt also cancels a
# smart-speech model call that is still running. The hand-off is serialized by
# a short lock (not held while speaking) so two hooks firing at once can't both
# miss each other.
tts_lock "$HANDOFF" 100 || { debug "hand-off lock busy; not speaking"; exit 0; }
if old=$(tts_current_pid) && [[ "$old" != "$$" ]]; then
  tts_signal TERM "$old"
fi
echo "$$" > "$PIDFILE" 2>/dev/null
tts_unlock "$HANDOFF"

# Make the reply speakable (scripts/speechify.py): code blocks, tables and
# diagrams become a short "... on screen" cue; inline code, equations, chemical
# formulas and symbols are read out in words; long replies stop at a sentence
# end. With SMART_SPEECH=1 a small Claude model describes the code blocks,
# tables and diagrams instead. Without python3, a simpler sed version drops
# code and keeps the words.
if command -v python3 >/dev/null 2>&1; then
  SMART_SPEECH="$SMART_SPEECH" SMART_SPEECH_MODEL="$SMART_SPEECH_MODEL" \
    SMART_SPEECH_TIMEOUT="$SMART_SPEECH_TIMEOUT" \
    python3 "$(dirname "${BASH_SOURCE[0]}")/speechify.py" "$MAX_CHARS" <<<"$text" >"$TMP.txt" &
  JOB=$!; wait_job
  text=$(cat "$TMP.txt")
else
  text=$(awk '{ t=$0; sub(/^[[:space:]]+/, "", t) }
             !f && match(t, /^(```+|~~~+)/) { f=substr(t,1,RLENGTH); print "Code block on screen."; next }
             f { c=t; sub(/[[:space:]]+$/, "", c)
                 if (substr(c,1,1) == substr(f,1,1) && c ~ /^(`+|~+)$/ && length(c) >= length(f)) f=""
                 next }
             { print }' <<<"$text" \
    | sed -E -e 's/`([^`]*)`/\1/g' -e 's#https?://[^ )>]*# a link #g' \
             -e 's/^[[:space:]]*([#>]+|[-*+]|[0-9]+\.)[[:space:]]+//' \
             -e 's/(\*\*|__|\*)//g' -e 's/\|/ /g' -e 's/(::|_)/ /g' \
    | tr '\n' ' ' | tr -s ' ')
  if (( MAX_CHARS > 0 && ${#text} > MAX_CHARS )); then     # stop at a sentence end if one is close
    cut="${text:0:MAX_CHARS}"
    sentence="${cut%[.!?] *}"
    if (( ${#sentence} >= MAX_CHARS * 2 / 5 && ${#sentence} < ${#cut} )); then cut="$sentence"; else cut="${cut% *}"; fi
    text="$cut. The rest is on screen."
  fi
fi
[[ -z "${text// /}" ]] && exit 0

have() { command -v "$1" >/dev/null 2>&1; }

# Play an audio file, trying each installed player in turn until one succeeds
# (one may exist but be unable to reach the sound device). SKIP_APLAY=1 skips
# aplay when it has just failed on the streaming path.
play_file() {
  local f="$1" p
  local -a players=()
  if [[ "$f" == *.wav ]]; then
    [[ "${SKIP_APLAY:-0}" == 1 ]] || players+=("aplay -q")
    players+=("paplay" "pw-play")
  fi
  players+=("afplay" "ffplay -nodisp -autoexit -loglevel quiet" "mpv --really-quiet --no-video")
  [[ "$f" == *.mp3 ]] && players+=("mpg123 -q")
  for p in "${players[@]}"; do
    have "${p%% *}" || continue
    # shellcheck disable=SC2086  # $p is a command plus its fixed options
    $p "$f" 2>/dev/null && return 0
    debug "player ${p%% *} failed; trying the next one"
  done
  return 1
}

# Pick the configured voice, else the default voice, else any installed voice.
piper_model() {
  local v m
  for v in "$PIPER_VOICE" "$TTS_DEFAULT_VOICE"; do            # a voice needs both files
    [[ -f "$PIPER_ROOT/$v.onnx" && -f "$PIPER_ROOT/$v.onnx.json" ]] && { echo "$PIPER_ROOT/$v.onnx"; return 0; }
  done
  for m in "$PIPER_ROOT"/*.onnx; do
    [[ -f "$m" && -f "$m.json" ]] && { echo "$m"; return 0; }
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
    (( st[1] == 0 && st[2] == 0 )) && return 0
    # When aplay can't open the device, piper also fails (broken pipe), so any
    # failure retries through a WAV; a real piper failure fails that too.
    debug "streaming playback failed; rendering a WAV for the other players"
    local SKIP_APLAY=0
    (( st[2] != 0 )) && SKIP_APLAY=1
  fi
  f="$TMP"
  printf '%s' "$text" | "$piper" --model "$model" --output_file "$f.wav" >/dev/null 2>&1 \
    && play_file "$f.wav"
}

speak_edge() {
  local edge f
  edge=$(command -v edge-tts || echo "$HOME/.local/share/edge-tts/bin/edge-tts")
  [[ -x "$edge" ]] || { debug "edge: edge-tts not installed"; return 1; }
  f="$TMP"
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

# A newer reply may have taken over while the text was being prepared.
[[ "$(cat "$PIDFILE" 2>/dev/null)" == "$$" ]] || exit 0

speak() {
  case "$ENGINE" in
    piper)  speak_piper  || speak_edge  || speak_say || speak_espeak ;;
    edge)   speak_edge   || speak_piper || speak_say || speak_espeak ;;
    say)    speak_say    || speak_espeak ;;
    piper-only) speak_piper || { echo "tts-companion: Piper could not play voice $PIPER_VOICE" >&2; return 1; } ;;
    *)      speak_espeak || speak_say ;;
  esac
}
speak &
JOB=$!; wait_job
exit 0
