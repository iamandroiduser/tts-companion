#!/usr/bin/env bash
# tts-companion SessionStart hook: if Piper or the configured voice is missing,
# install it in the background so speech works without a manual setup step.
# Silent by design (SessionStart stdout would be added to Claude's context).
# Log: $PIPER_ROOT/install.log. Opt out with AUTO_INSTALL=0 in ~/.claude/tts.conf.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
# shellcheck source=scripts/lib.sh
source "$HERE/lib.sh" || exit 0
tts_load_config
lock="$PIPER_ROOT/.install.lock"
failed="$PIPER_ROOT/.install-failed"

# Worker: runs detached, holds the lock until the install finishes.
if [[ "${1:-}" == "--worker" ]]; then
  trap 'rm -rf "$lock"' EXIT
  echo "=== $(date) installing $PIPER_VOICE into $PIPER_ROOT"
  if bash "$HERE/install.sh" "$PIPER_VOICE"; then rm -f "$failed"; else touch "$failed"; fi
  exit 0
fi

tts_write_conf_template 2>/dev/null

[[ "$ENABLED" == "1" && "$AUTO_INSTALL" == "1" ]] || exit 0
[[ "$ENGINE" == "piper" || "$ENGINE" == "edge" ]] || exit 0
[[ "$(uname -s)" == "Linux" ]] || exit 0
[[ -x "$PIPER_ROOT/bin/piper" && -f "$PIPER_ROOT/$PIPER_VOICE.onnx" ]] && exit 0
command -v curl >/dev/null && command -v tar >/dev/null || exit 0

mkdir -p "$PIPER_ROOT" 2>/dev/null || exit 0
log="$PIPER_ROOT/install.log"

# After a failure, wait 6 hours before retrying (offline, proxy, bad voice name…).
[[ -n "$(find "$failed" -mmin -360 2>/dev/null)" ]] && exit 0
# Another session is installing; a lock older than 30 minutes is stale.
[[ -n "$(find "$lock" -maxdepth 0 -mmin +30 2>/dev/null)" ]] && rm -rf "$lock"
mkdir "$lock" 2>/dev/null || exit 0

# Detach fully: no stdin/stdout ties to Claude Code, and its own session so it
# survives Claude Code exiting mid-download.
if command -v setsid >/dev/null; then
  setsid bash "$HERE/bootstrap.sh" --worker </dev/null >>"$log" 2>&1 &
else
  nohup bash "$HERE/bootstrap.sh" --worker </dev/null >>"$log" 2>&1 &
fi
exit 0
