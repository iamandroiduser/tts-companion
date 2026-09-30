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

cmd="${1:-toggle}"
if [[ "$cmd" == "prompt-stop" ]]; then
  cat >/dev/null                       # drain the hook's JSON input
  [[ "$TTS_INNER" == 1 ]] && exit 0
  [[ "$STOP_ON_PROMPT" == "1" ]] && pid=$(tts_current_pid) && tts_signal TERM "$pid"
  exit 0
fi

pid=$(tts_current_pid) || { echo "Nothing is being spoken."; exit 0; }
paused() { [[ "$(ps -o stat= -p "$pid" 2>/dev/null)" == T* ]]; }

case "$cmd" in
  stop)   tts_signal TERM "$pid"; echo "Stopped." ;;
  pause)  tts_signal STOP "$pid"; echo "Paused. Resume with: $(basename "$0") resume" ;;
  resume) tts_signal CONT "$pid"; echo "Resumed." ;;
  toggle) if paused; then tts_signal CONT "$pid"; echo "Resumed."
          else tts_signal STOP "$pid"; echo "Paused."; fi ;;
  status) if paused; then echo "Paused."; else echo "Speaking."; fi ;;
  *)      echo "usage: $(basename "$0") stop|pause|resume|toggle|status" >&2; exit 2 ;;
esac
