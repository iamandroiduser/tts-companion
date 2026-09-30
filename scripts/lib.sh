# shellcheck shell=bash
# tts-companion shared helpers. Sourced by every script, never executed.
#
# Paths and config resolve the same way whether a script runs as a Claude Code
# hook (CLAUDE_PLUGIN_DATA / CLAUDE_PLUGIN_ROOT set) or by hand from a shell.

# Set for the `claude -p` run that smart speech starts; our hooks do nothing inside it.
# shellcheck disable=SC2034  # used by the scripts that source this file
[[ "${TTS_COMPANION_INNER:-}" == "1" ]] && TTS_INNER=1 || TTS_INNER=0

TTS_DEFAULT_VOICE="en_GB-jenny_dioco-medium"
TTS_USER_CONF="$HOME/.claude/tts.conf"
TTS_DEFAULT_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/piper"

# Load settings. Later sources win: plugin data dir (legacy), then ~/.claude/tts.conf.
tts_load_config() {
  # shellcheck disable=SC1090,SC1091
  [[ -n "${CLAUDE_PLUGIN_DATA:-}" && -f "$CLAUDE_PLUGIN_DATA/tts.conf" ]] && source "$CLAUDE_PLUGIN_DATA/tts.conf"
  # shellcheck disable=SC1090
  [[ -f "$TTS_USER_CONF" ]] && source "$TTS_USER_CONF"

  # One-off overrides from the environment (used by tts-try.sh).
  [[ -n "${TTS_VOICE:-}" ]] && PIPER_VOICE="$TTS_VOICE"
  [[ -n "${TTS_ENGINE:-}" ]] && ENGINE="$TTS_ENGINE"

  ENABLED="${ENABLED:-1}"
  ENGINE="${ENGINE:-piper}"
  PIPER_VOICE="${PIPER_VOICE:-$TTS_DEFAULT_VOICE}"
  EDGE_VOICE="${EDGE_VOICE:-en-US-AriaNeural}"
  MAX_CHARS="${MAX_CHARS:-1500}"
  SPEAK_REPLIES="${SPEAK_REPLIES:-1}"
  SPEAK_NOTIFICATIONS="${SPEAK_NOTIFICATIONS:-1}"
  AUTO_INSTALL="${AUTO_INSTALL:-1}"
  STOP_ON_PROMPT="${STOP_ON_PROMPT:-1}"
  SMART_SPEECH="${SMART_SPEECH:-0}"
  SMART_SPEECH_MODEL="${SMART_SPEECH_MODEL:-haiku}"
  SMART_SPEECH_TIMEOUT="${SMART_SPEECH_TIMEOUT:-25}"

  # Piper install dir: explicit PIPER_ROOT, else the first candidate that has the
  # binary, else the default. The plugin data dir is only a legacy candidate.
  if [[ -z "${PIPER_ROOT:-}" ]]; then
    PIPER_ROOT="$TTS_DEFAULT_ROOT"
    local c
    for c in "$TTS_DEFAULT_ROOT" "${CLAUDE_PLUGIN_DATA:-}"; do
      if [[ -n "$c" && -x "$c/bin/piper" ]]; then PIPER_ROOT="$c"; break; fi
    done
  fi
}

# tts_json <dotted.path> [file] — print a JSON value (empty if missing). jq, else python3.
tts_json() {
  local path="$1" file="${2:-/dev/stdin}"
  if command -v jq >/dev/null 2>&1; then
    jq -r ".$path // empty" "$file" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
v = json.load(open(sys.argv[2]))
for k in sys.argv[1].split("."):
    v = v.get(k) if isinstance(v, dict) else None
if v is not None:
    print(v)' "$path" "$file" 2>/dev/null
  fi
}

# Write a commented settings template once, so users know where settings live.
tts_write_conf_template() {
  [[ -e "$TTS_USER_CONF" ]] && return 0
  mkdir -p "${TTS_USER_CONF%/*}" || return 1
  cat > "$TTS_USER_CONF" <<EOF
# tts-companion settings. Uncomment a line to override the default.
#ENABLED=1                        # 0 mutes all speech
#ENGINE=piper                     # piper | edge | say | espeak
#PIPER_VOICE=$TTS_DEFAULT_VOICE
#EDGE_VOICE=en-US-AriaNeural
#MAX_CHARS=1500                   # longer replies stop at a sentence end ("The rest is on screen"); 0 = no limit
#SPEAK_REPLIES=1                  # speak each finished reply (Stop hook)
#SPEAK_NOTIFICATIONS=1            # speak permission / idle alerts
#STOP_ON_PROMPT=1                 # sending your next prompt stops the current speech
#SMART_SPEECH=0                   # 1: a small Claude model describes code/tables/diagrams in a sentence
#SMART_SPEECH_MODEL=haiku         #    (uses your Claude Code login; adds ~5 s before such replies are spoken)
#AUTO_INSTALL=1                   # 0 stops the background Piper download at session start
#PIPER_ROOT=$TTS_DEFAULT_ROOT
EOF
}

# ---- the speech currently playing (shared by tts-speak.sh and tts-ctl.sh) ----
# Kept in a directory only this user can write (not a guessable path in a shared
# /tmp, where another user could plant a symlink): $XDG_RUNTIME_DIR, else ~/.cache.
TTS_STATE_DIR="${XDG_RUNTIME_DIR:-$HOME/.cache}/tts-companion"
[[ -d "$TTS_STATE_DIR" ]] || { mkdir -p "${TTS_STATE_DIR%/*}" && mkdir -m 700 "$TTS_STATE_DIR"; } 2>/dev/null
TTS_PIDFILE="$TTS_STATE_DIR/speaking.pid"
# Changed by every stop (tts-companion stop, your next prompt). A speak run notes
# it before reading its input and gives up if it changed, so a reply still being
# read in when you stop it (or send your next prompt) can't start speaking later.
TTS_CANCELFILE="$TTS_STATE_DIR/cancelled"
tts_cancel_token() { cat "$TTS_CANCELFILE" 2>/dev/null; }
tts_cancel_all() { echo "$(date +%s%N 2>/dev/null).$$.$RANDOM" > "$TTS_CANCELFILE" 2>/dev/null; }

# tts_lock DIR [TRIES] [STALE_MIN] — take a mkdir lock recording our pid, retrying
# every 50 ms. A lock is taken over only when its recorded owner is dead (or it has
# no owner after STALE_MIN minutes), re-checked under DIR.reclaim so two waiters
# can't both reclaim it and delete a lock someone else has just taken.
tts_lock() {
  local dir="$1" tries="${2:-100}" stale="${3:-1}" n owner
  for ((n = 0; n < tries; n++)); do
    if mkdir "$dir" 2>/dev/null; then echo "$$" > "$dir/pid"; return 0; fi
    if tts_lock_is_stale "$dir" "$stale"; then
      if mkdir "$dir.reclaim" 2>/dev/null; then
        tts_lock_is_stale "$dir" "$stale" && rm -rf "$dir"
        if mkdir "$dir" 2>/dev/null; then                 # take it while still holding .reclaim
          echo "$$" > "$dir/pid"; rmdir "$dir.reclaim" 2>/dev/null; return 0
        fi
        rmdir "$dir.reclaim" 2>/dev/null
      fi
      # a reclaimer that died mid-way leaves DIR.reclaim behind
      [[ -n "$(find "$dir.reclaim" -prune -mmin +1 2>/dev/null)" ]] && rmdir "$dir.reclaim" 2>/dev/null
    fi
    sleep 0.05
  done
  return 1
}
tts_lock_is_stale() {
  local owner
  owner=$(cat "$1/pid" 2>/dev/null)
  if [[ "$owner" =~ ^[0-9]+$ ]]; then
    ! kill -0 "$owner" 2>/dev/null
  else
    [[ -d "$1" && -n "$(find "$1" -prune -mmin "+$2" 2>/dev/null)" ]]
  fi
}
# Release a lock only if we still own it.
tts_unlock() {
  [[ "$(cat "$1/pid" 2>/dev/null)" == "${2:-$$}" ]] && rm -rf "$1"
  return 0
}

tts_descendants() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; tts_descendants "$c"; done
}

# Print the pid of the tts-speak.sh run that is speaking now, if any.
tts_current_pid() {
  local pid
  pid=$(cat "$TTS_PIDFILE" 2>/dev/null) || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] && ps -p "$pid" -o args= 2>/dev/null | grep -q 'tts-speak' || return 1
  echo "$pid"
}

# Send a signal to a speaking run and its engine/player processes.
# The run is paused with SIGSTOP, so SIGCONT follows SIGTERM or it would never die.
# shellcheck disable=SC2086  # $kids is a whitespace-separated pid list
tts_signal() {
  local sig="$1" pid="$2" kids
  kids=$(tts_descendants "$pid")
  case "$sig" in
    TERM) kill -TERM "$pid" $kids 2>/dev/null; kill -CONT "$pid" $kids 2>/dev/null ;;
    STOP) kill -STOP $kids "$pid" 2>/dev/null ;;   # players first, then the script
    CONT) kill -CONT "$pid" $kids 2>/dev/null ;;
  esac
}
