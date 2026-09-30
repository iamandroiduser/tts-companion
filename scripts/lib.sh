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
# An existing directory is used only if it is a real directory (not a symlink)
# owned by this user, and it is made private; otherwise TTS_STATE_DIR is empty
# and speech / speech control stay off rather than write somewhere unsafe.
TTS_STATE_DIR="${XDG_RUNTIME_DIR:-$HOME/.cache}/tts-companion"
[[ -e "$TTS_STATE_DIR" || -L "$TTS_STATE_DIR" ]] \
  || { mkdir -p "${TTS_STATE_DIR%/*}" && mkdir -m 700 "$TTS_STATE_DIR"; } 2>/dev/null
if [[ -d "$TTS_STATE_DIR" && ! -L "$TTS_STATE_DIR" && -O "$TTS_STATE_DIR" ]] && chmod 700 "$TTS_STATE_DIR" 2>/dev/null; then
  TTS_PIDFILE="$TTS_STATE_DIR/speaking.pid"
  TTS_CANCELFILE="$TTS_STATE_DIR/cancelled"
else
  TTS_STATE_DIR="" TTS_PIDFILE="" TTS_CANCELFILE=""
fi

# tts_proc_start PID — when the process started, in clock ticks since boot (Linux).
tts_proc_start() {
  local s
  s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  s=${s##*) }                            # fields after "(command) ", from field 3
  # shellcheck disable=SC2086
  set -- $s
  [[ "${20:-}" =~ ^[0-9]+$ ]] && echo "${20}"
}
# tts_start_epoch PID — when the process started, in whole seconds since the
# epoch (portable: from ps's elapsed time, [[dd-]hh:]mm:ss; may be 1 s off).
tts_start_epoch() {
  local e d=0 h=0 m=0 s
  e=$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ') && [[ -n "$e" ]] || return 1
  [[ "$e" == *-* ]] && { d=${e%%-*}; e=${e#*-}; }
  IFS=: read -r -a p <<<"$e"
  case ${#p[@]} in
    3) h=${p[0]} m=${p[1]} s=${p[2]} ;;
    2) m=${p[0]} s=${p[1]} ;;
    *) return 1 ;;
  esac
  echo $(( $(date +%s) - ((10#$d * 24 + 10#$h) * 60 + 10#$m) * 60 - 10#$s ))
}
# Every stop (tts-companion stop, your next prompt) rewrites the cancel file with
# the time it happened. A speak run gives up if a stop came at or after the time
# the run was started, which also covers a hook that Claude Code had already
# launched but that hadn't got going yet. On Linux this compares process start
# times in clock ticks; elsewhere in seconds, counting a stop up to 1 s before
# the run's start as later (ps's rounding). Any change to the file after the run
# first read it also counts.
tts_cancel_token() { [[ -n "$TTS_CANCELFILE" ]] && cat "$TTS_CANCELFILE" 2>/dev/null; }
tts_cancel_all() {
  [[ -n "$TTS_CANCELFILE" ]] || return 0
  echo "$(tts_proc_start $$ || echo -) $(date +%s) $$.$RANDOM" > "$TTS_CANCELFILE" 2>/dev/null
}
# tts_cancelled TOKEN_AT_START MY_START_TICKS MY_START_EPOCH
tts_cancelled() {
  local now ticks epoch _
  now=$(tts_cancel_token)
  [[ "$now" != "$1" ]] && return 0                  # a stop since we first looked
  read -r ticks epoch _ <<<"$now"
  # Wall clock first: a stop clearly older than this run (e.g. from before a
  # reboot, when clock ticks started again from zero) never cancels it.
  if [[ "$epoch" =~ ^[0-9]+$ && "$3" =~ ^[0-9]+$ ]] && (( epoch + 1 < $3 )); then
    return 1
  fi
  if [[ "$ticks" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]]; then
    (( ticks >= $2 ))
  elif [[ "$epoch" =~ ^[0-9]+$ && "$3" =~ ^[0-9]+$ ]]; then
    (( epoch + 1 >= $3 ))
  else
    return 1
  fi
}

# tts_started_after PID MY_START_TICKS MY_START_EPOCH — did PID start after us?
# Clock ticks on Linux; elsewhere whole seconds, where only a clear gap counts.
tts_started_after() {
  local t e
  if [[ "$2" =~ ^[0-9]+$ ]] && t=$(tts_proc_start "$1"); then
    (( t > $2 ))
  elif [[ "$3" =~ ^[0-9]+$ ]] && e=$(tts_start_epoch "$1"); then
    (( e > $3 + 1 ))
  else
    return 1
  fi
}

# A process's identity: its pid plus its start time (ps lstart, Linux and macOS),
# so a pid that has been reused by another process doesn't count as the same one.
tts_ident() {
  local t
  t=$(ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' '_') || return 1
  t=${t#_}; t=${t%_}
  [[ -n "$t" ]] && echo "$1 $t"
}
TTS_SELF=$(tts_ident $$ || echo $$)
# Is the process recorded as "PID START" (or a bare PID from an older version) still that process?
tts_ident_alive() {
  local pid=${1%% *}
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  if [[ "$1" == *" "* ]]; then [[ "$(tts_ident "$pid")" == "$1" ]]; else kill -0 "$pid" 2>/dev/null; fi
}

# tts_lock DIR [TRIES] [STALE_MIN] — take a mkdir lock recording our identity, retrying
# every 50 ms. A lock is taken over only when its recorded owner is gone (or it has
# no owner after STALE_MIN minutes), re-checked under DIR.reclaim so two waiters
# can't both reclaim it and delete a lock someone else has just taken.
tts_lock() {
  local dir="$1" tries="${2:-100}" stale="${3:-1}" n owner
  for ((n = 0; n < tries; n++)); do
    if mkdir "$dir" 2>/dev/null; then echo "$TTS_SELF" > "$dir/pid"; return 0; fi
    if tts_lock_is_stale "$dir" "$stale"; then
      if mkdir "$dir.reclaim" 2>/dev/null; then
        echo "$TTS_SELF" > "$dir.reclaim/pid"
        tts_lock_is_stale "$dir" "$stale" && rm -rf "$dir"
        if mkdir "$dir" 2>/dev/null; then                 # take it while still holding .reclaim
          echo "$TTS_SELF" > "$dir/pid"; tts_unlock "$dir.reclaim"; return 0
        fi
        tts_unlock "$dir.reclaim"
      else
        tts_clear_dead_mutex "$dir.reclaim"               # a reclaimer that died mid-way
      fi
    fi
    sleep 0.05
  done
  return 1
}
# Remove a DIR.reclaim mutex only if its owner is gone (or it recorded none within
# a minute), never a live owner's. It is renamed aside first and re-checked there,
# so a mutex someone else has just created in its place is never deleted.
tts_clear_dead_mutex() {
  local m="$1" aside
  tts_lock_is_stale "$m" 1 || return 0
  aside="$m.dead.$$.$RANDOM"
  mv "$m" "$aside" 2>/dev/null || return 0
  if tts_lock_is_stale "$aside" 1; then
    rm -rf "$aside"
  else
    mv "$aside" "$m" 2>/dev/null || rm -rf "$aside"   # not dead after all: put it back
  fi
}
tts_lock_is_stale() {
  local owner
  owner=$(cat "$1/pid" 2>/dev/null)
  if [[ "${owner%% *}" =~ ^[0-9]+$ ]]; then
    ! tts_ident_alive "$owner"                       # gone, or its pid now belongs to another process
  else
    [[ -d "$1" && -n "$(find "$1" -prune -mmin "+$2" 2>/dev/null)" ]]
  fi
}
# Release a lock only if we still own it.
tts_unlock() {
  [[ "$(cat "$1/pid" 2>/dev/null)" == "$TTS_SELF" ]] && rm -rf "$1"
  return 0
}

tts_descendants() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; tts_descendants "$c"; done
}

# Print the pid of the tts-speak.sh run that is speaking now, if any.
tts_current_pid() {
  local rec pid
  rec=$(cat "$TTS_PIDFILE" 2>/dev/null) || return 1
  pid=${rec%% *}
  tts_ident_alive "$rec" && ps -p "$pid" -o args= 2>/dev/null | grep -q 'tts-speak' || return 1
  echo "$pid"
}

# Send a signal to a speaking run and its engine/player processes.
# The run is paused with SIGSTOP, so SIGCONT follows SIGTERM or it would never die.
# shellcheck disable=SC2086  # $kids is a whitespace-separated pid list
# The run's jobs each have their own process group (tts-speak.sh uses set -m), so
# pause and resume signal those whole groups too: a player started between our
# listing and the signal is in its job's group and is paused with it.
tts_signal() {
  local sig="$1" pid="$2" kids groups own g
  [[ "$sig" == STOP ]] && kill -STOP "$pid" 2>/dev/null   # first, so it starts nothing new
  kids=$(tts_descendants "$pid")
  own=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  groups=$(for k in $kids; do ps -o pgid= -p "$k" 2>/dev/null; done | tr -d ' ' | sort -u)
  for g in $groups; do                                   # never the group the script itself is in
    [[ -n "$g" && "$g" != "$own" && "$g" != 0 && "$g" != 1 ]] && kill -"$sig" -- "-$g" 2>/dev/null
  done
  case "$sig" in
    TERM) kill -TERM "$pid" $kids 2>/dev/null; kill -CONT "$pid" $kids 2>/dev/null ;;
    STOP) kill -STOP $kids 2>/dev/null ;;
    CONT) kill -CONT "$pid" $kids 2>/dev/null ;;
  esac
}
