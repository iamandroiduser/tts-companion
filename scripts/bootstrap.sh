#!/usr/bin/env bash
# tts-companion SessionStart hook: if Piper or the configured voice is missing,
# install it in the background so speech works without a manual setup step.
# Silent by design (SessionStart stdout would be added to Claude's context).
# Log: $PIPER_ROOT/install.log. Opt out with AUTO_INSTALL=0 in ~/.claude/tts.conf.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
# shellcheck source=scripts/lib.sh
source "$HERE/lib.sh" || exit 0
tts_load_config
[[ "$TTS_INNER" == 1 ]] && exit 0
lock="$PIPER_ROOT/.install.lock"
failed="$PIPER_ROOT/.install-failed.${PIPER_VOICE//[^A-Za-z0-9_.-]/_}"   # per voice: fixing a bad name retries at once

# Worker: runs detached, holds the lock until the install finishes.
if [[ "${1:-}" == "--worker" ]]; then
  echo "$$" > "$lock/pid"
  trap 'tts_unlock "$lock"' EXIT
  echo "=== $(date) installing $PIPER_VOICE into $PIPER_ROOT"
  if TTS_INSTALL_LOCKED=1 bash "$HERE/install.sh" "$PIPER_VOICE"; then rm -f "$failed"; else touch "$failed"; fi
  exit 0
fi

tts_write_conf_template 2>/dev/null

# Keep a short `tts-companion` command (stop / pause / resume / toggle) on PATH
# pointing at this plugin version. Only touches ~/.local/bin/tts-companion, and
# never replaces a file there that this plugin didn't create.
link="$HOME/.local/bin/tts-companion"
ours() {   # a link this plugin made: into a tts-companion scripts dir, or at a file with our marker
  local target
  target=$(readlink "$link") || return 1
  [[ "$target" == */tts-companion/*/scripts/tts-ctl.sh || "$target" == */tts-companion/scripts/tts-ctl.sh ]] \
    || grep -q '^# tts-companion speech control' "$target" 2>/dev/null
}
if [[ -d "$HOME/.local/bin" ]] && { [[ ! -e "$link" && ! -L "$link" ]] || { [[ -L "$link" ]] && ours; }; }; then
  ln -sfn "$HERE/tts-ctl.sh" "$link" 2>/dev/null
fi

[[ "$ENABLED" == "1" && "$AUTO_INSTALL" == "1" ]] || exit 0
[[ "$ENGINE" == "piper" || "$ENGINE" == "edge" ]] || exit 0
[[ "$(uname -s)" == "Linux" ]] || exit 0
[[ -x "$PIPER_ROOT/bin/piper" && -f "$PIPER_ROOT/$PIPER_VOICE.onnx" \
   && -f "$PIPER_ROOT/$PIPER_VOICE.onnx.json" ]] && exit 0
command -v curl >/dev/null && command -v tar >/dev/null || exit 0

mkdir -p "$PIPER_ROOT" 2>/dev/null || exit 0
log="$PIPER_ROOT/install.log"

# After a failure, wait 6 hours before retrying (offline, proxy, bad voice name…).
[[ -n "$(find "$failed" -mmin -360 2>/dev/null)" ]] && exit 0
# Another session may be installing. Its lock is reclaimed only if its worker is
# gone (or recorded no pid within 5 minutes), never just because it is slow.
tts_lock "$lock" 1 5 || exit 0

# Detach fully: no stdin/stdout ties to Claude Code, and its own session so it
# survives Claude Code exiting mid-download.
if command -v setsid >/dev/null; then
  setsid bash "$HERE/bootstrap.sh" --worker </dev/null >>"$log" 2>&1 &
else
  nohup bash "$HERE/bootstrap.sh" --worker </dev/null >>"$log" 2>&1 &
fi
# Hand the lock to the worker: it writes its own pid first thing. Stay alive (so
# the lock never looks abandoned) until it has done so, or has already finished
# and released it; never write to the lock ourselves after that point.
worker=$!
for _ in {1..100}; do
  owner=$(cat "$lock/pid" 2>/dev/null) || break          # released already
  [[ "$owner" == "$worker" ]] && break
  kill -0 "$worker" 2>/dev/null || break
  sleep 0.02
done
exit 0
