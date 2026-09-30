#!/usr/bin/env bash
# tts-companion speech control.
#   tts-ctl.sh stop | pause | resume | toggle | status
# toggle pauses speech that is playing and resumes speech that is paused.
# Also run as a UserPromptSubmit hook ("prompt-stop") so sending your next
# prompt stops the reply being read; that mode prints nothing (hook stdout
# would be added to Claude's context).

# Resolve ~/.local/bin/tts-companion (a symlink) back to the plugin's scripts dir.
self="${BASH_SOURCE[0]}"
while [[ -L "$self" ]]; do
  target=$(readlink "$self")
  [[ "$target" == /* ]] && self="$target" || self="$(dirname "$self")/$target"
done
# shellcheck source=scripts/lib.sh
source "$(dirname "$self")/lib.sh" || exit 0
tts_load_config

# Stop what is playing and cancel replies still being prepared. Done under the
# speak hand-off lock, so a run can't register itself between the two steps.
# Returns 0 if something was stopped, 1 if nothing was playing, 2 if the lock
# stayed busy: speech is cancelled even then (see below), but the speaker is only
# looked up and signalled directly while we hold the lock.
stop_all() {
  local pid
  # First, before waiting for the lock: every run (a speaking one included)
  # checks this and stops within about 0.1 s, even if the lock stays busy or
  # this hook is cut off by its timeout.
  tts_cancel_all
  tts_lock "$TTS_PIDFILE.lock" 40 || return 2
  pid=$(tts_current_pid) && tts_signal TERM "$pid"
  tts_unlock "$TTS_PIDFILE.lock"
  [[ -n "$pid" ]]
}

cmd="${1:-toggle}"
case "$cmd" in
  prompt-stop|stop|pause|resume|toggle|status) ;;
  *) echo "usage: $(basename "$0") stop|pause|resume|toggle|status" >&2; exit 2 ;;
esac
if [[ "$cmd" == "prompt-stop" ]]; then
  cat >/dev/null                       # drain the hook's JSON input
  [[ "$TTS_INNER" == 1 || -z "$TTS_STATE_DIR" ]] && exit 0
  [[ "$STOP_ON_PROMPT" == "1" ]] && stop_all
  exit 0
fi

if [[ -z "$TTS_STATE_DIR" ]]; then
  echo "tts-companion: ${XDG_RUNTIME_DIR:-$HOME/.cache}/tts-companion is not a private directory owned by you; not touching it." >&2
  exit 1
fi
if [[ "$cmd" == "stop" ]]; then
  stop_all
  case $? in
    0) echo "Stopped." ;;
    1) echo "Nothing is being spoken." ;;
    *) echo "tts-companion: busy (a reply is just starting); run stop again." >&2; exit 1 ;;
  esac
  exit 0
fi
# Look up the speaker and act on it under the hand-off lock, so a new reply
# can't replace it in between (we'd pause the old one and say "Paused").
if ! tts_lock "$TTS_PIDFILE.lock" 40; then
  echo "tts-companion: busy (a reply is just starting); try again." >&2
  exit 1
fi
trap 'tts_unlock "$TTS_PIDFILE.lock"' EXIT
pid=$(tts_current_pid) || { echo "Nothing is being spoken."; exit 0; }
paused() { [[ "$(ps -o stat= -p "$pid" 2>/dev/null)" == T* ]]; }

case "$cmd" in
  pause)  tts_signal STOP "$pid"; echo "Paused. Resume with: $(basename "$0") resume" ;;
  resume) tts_signal CONT "$pid"; echo "Resumed." ;;
  toggle) if paused; then tts_signal CONT "$pid"; echo "Resumed."
          else tts_signal STOP "$pid"; echo "Paused."; fi ;;
  status) if paused; then echo "Paused."
          elif [[ "$(cat "$TTS_STATE_DIR/playing" 2>/dev/null)" == "$(cat "$TTS_PIDFILE" 2>/dev/null)" ]]; then echo "Speaking."
          else echo "Preparing speech."; fi ;;   # text preparation or the smart-speech model call
  *)      echo "usage: $(basename "$0") stop|pause|resume|toggle|status" >&2; exit 2 ;;
esac
