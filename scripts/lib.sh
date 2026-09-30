# shellcheck shell=bash
# tts-companion shared helpers. Sourced by every script, never executed.
#
# Paths and config resolve the same way whether a script runs as a Claude Code
# hook (CLAUDE_PLUGIN_DATA / CLAUDE_PLUGIN_ROOT set) or by hand from a shell.

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
  MAX_CHARS="${MAX_CHARS:-400}"
  SPEAK_REPLIES="${SPEAK_REPLIES:-1}"
  SPEAK_NOTIFICATIONS="${SPEAK_NOTIFICATIONS:-1}"
  AUTO_INSTALL="${AUTO_INSTALL:-1}"

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
#MAX_CHARS=400                    # longer replies are cut at a word boundary
#SPEAK_REPLIES=1                  # speak each finished reply (Stop hook)
#SPEAK_NOTIFICATIONS=1            # speak permission / idle alerts
#AUTO_INSTALL=1                   # 0 stops the background Piper download at session start
#PIPER_ROOT=$TTS_DEFAULT_ROOT
EOF
}
