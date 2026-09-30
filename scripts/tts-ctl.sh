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
stop_all() {
  local locked=0 pid
  tts_lock "$TTS_PIDFILE.lock" 40 && locked=1
  tts_cancel_all
  pid=$(tts_current_pid) && tts_signal TERM "$pid"
  (( locked )) && tts_unlock "$TTS_PIDFILE.lock"
  [[ -n "$pid" ]]
}

cmd="${1:-toggle}"
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
  if stop_all; then echo "Stopped."; else echo "Nothing is being spoken."; fi
  exit 0
fi
# Look up the speaker and act on it under the hand-off lock, so a new reply
# can't replace it in between (we'd pause the old one and say "Paused").
locked=0
tts_lock "$TTS_PIDFILE.lock" 40 && locked=1
trap '(( locked )) && tts_unlock "$TTS_PIDFILE.lock"' EXIT
pid=$(tts_current_pid) || { echo "Nothing is being spoken."; exit 0; }
paused() { [[ "$(ps -o stat= -p "$pid" 2>/dev/null)" == T* ]]; }

case "$cmd" in
  pause)  tts_signal STOP "$pid"; echo "Paused. Resume with: $(basename "$0") resume" ;;
  resume) tts_signal CONT "$pid"; echo "Resumed." ;;
  toggle) if paused; then tts_signal CONT "$pid"; echo "Resumed."
          else tts_signal STOP "$pid"; echo "Paused."; fi ;;
  status) if paused; then echo "Paused."; else echo "Speaking."; fi ;;
  *)      echo "usage: $(basename "$0") stop|pause|resume|toggle|status" >&2; exit 2 ;;
esac
