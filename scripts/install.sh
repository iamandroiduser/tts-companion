#!/usr/bin/env bash
# tts-companion installer: downloads the Piper binary (once) and a voice.
# Usage: install.sh [--force] [voice]    e.g. install.sh en_US-ryan-high
# Runs automatically in the background at session start (see bootstrap.sh);
# run it by hand to add voices. Deps: curl, tar. Linux x86_64 / aarch64 / armv7l.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
tts_load_config

FORCE=0
[[ "${1:-}" == "--force" ]] && { FORCE=1; shift; }
VOICE="${1:-$PIPER_VOICE}"
ROOT="$PIPER_ROOT"

die() { echo "tts-companion: $*" >&2; exit 1; }
for dep in curl tar; do command -v "$dep" >/dev/null || die "missing '$dep' — please install it"; done

[[ "$VOICE" =~ ^[a-z]{2,3}_[A-Z]{2}-[A-Za-z0-9_]+-(x_low|low|medium|high)$ ]] \
  || die "'$VOICE' is not a Piper voice name (expected e.g. $TTS_DEFAULT_VOICE)"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "tts-companion: Piper binaries are Linux-only here; on $(uname -s) the plugin"
  echo "uses the system voice (macOS 'say') instead. Nothing to install."
  exit 0
fi
case "$(uname -m)" in
  x86_64)        asset=piper_linux_x86_64.tar.gz ;;
  aarch64|arm64) asset=piper_linux_aarch64.tar.gz ;;
  armv7l)        asset=piper_linux_armv7l.tar.gz ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

mkdir -p "$ROOT"
# One installer at a time: a manual run takes the same lock the background
# worker holds (the worker, which already owns it, sets TTS_INSTALL_LOCKED=1).
lock="$ROOT/.install.lock"
if [[ "${TTS_INSTALL_LOCKED:-0}" != 1 ]]; then
  echo ">> Waiting for any other install to finish..."
  tts_lock "$lock" 12000 5 || die "another install is still running (see $ROOT/install.log)"
fi
tmp=$(mktemp -d "$ROOT/.install.XXXXXX")
# A voice swap that didn't finish: undo exactly what happened, going by where the
# files are. A new file no longer in $tmp has landed (remove it); an old file in
# voice.old was parked (put it back); an old file never parked was never touched.
restore_voice() {
  local f
  [[ -d "$tmp/voice.old" ]] || return 0                       # no swap started
  [[ ! -e "$tmp/$VOICE.onnx" && ! -e "$tmp/$VOICE.onnx.json" ]] && return 0   # it completed
  for f in "$VOICE.onnx" "$VOICE.onnx.json"; do
    [[ -e "$tmp/$f" ]] || rm -f "$ROOT/$f"
    [[ -e "$tmp/voice.old/$f" ]] && mv -f "$tmp/voice.old/$f" "$ROOT/$f"
  done
  return 0
}
# On any exit, an old bin/ still parked in $tmp means the new one never landed: put it back.
trap '[[ -d "$tmp/bin.old" && ! -e "$ROOT/bin" ]] && mv "$tmp/bin.old" "$ROOT/bin"
      restore_voice
      rm -rf "$tmp"; [[ "${TTS_INSTALL_LOCKED:-0}" == 1 ]] || tts_unlock "$lock"' EXIT
trap 'exit 1' TERM INT HUP    # so the EXIT trap (rollback, cleanup) also runs when killed

# Download to a temp dir first, then move into place, so an interrupted
# download never leaves a half-installed binary or voice behind.
# $ROOT/bin is replaced as a whole, so only ever touch one that is ours: empty,
# marked by this installer, or an unmodified Piper release (older installs) that
# holds nothing but the files a Piper release ships.
piper_release_bin() {
  local b="$1" e
  # Our own install (marker) may be half-removed; an unmarked one must look complete.
  [[ -f "$b/.tts-companion" ]] || [[ -x "$b/piper" && -d "$b/espeak-ng-data" ]] || return 1
  for e in "$b"/* "$b"/.[!.]* "$b"/..?*; do      # every entry, dotfiles included
    [[ -e "$e" || -L "$e" ]] || continue
    case "${e##*/}" in
      piper|piper_phonemize|espeak-ng|espeak-ng-data|pkgconfig|libtashkeel_model.ort|.tts-companion) ;;
      libespeak-ng.so*|libonnxruntime.so*|libpiper_phonemize.so*) ;;
      *) return 1 ;;
    esac
  done
}
piper_owned_bin() {
  local b="$ROOT/bin"
  local listing
  [[ ! -e "$b" && ! -L "$b" ]] && return 0
  # A directory we can't list could hold anything: never treat it as empty.
  [[ -d "$b" && -r "$b" && -x "$b" ]] && listing=$(ls -A "$b") || return 1
  [[ -z "$listing" ]] || piper_release_bin "$b"
}
if [[ "$FORCE" == 1 || ! -x "$ROOT/bin/piper" ]]; then
  piper_owned_bin || die "$ROOT/bin is not a Piper install made by this plugin; set PIPER_ROOT to a dedicated directory"
  echo ">> Installing Piper ($asset) into $ROOT/bin"
  mkdir -p "$tmp/bin"
  curl -fsSL "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/$asset" \
    | tar -xz -C "$tmp/bin" --strip-components=1
  [[ -x "$tmp/bin/piper" ]] || die "Piper archive did not contain bin/piper"
  echo "installed by tts-companion; this whole directory is replaced on reinstall" > "$tmp/bin/.tts-companion"
  # Keep the old bin/ as a rollback until the new one is in place.
  [[ -d "$ROOT/bin" ]] && mv "$ROOT/bin" "$tmp/bin.old"
  if ! mv "$tmp/bin" "$ROOT/bin"; then
    [[ -d "$tmp/bin.old" ]] && mv "$tmp/bin.old" "$ROOT/bin"
    die "could not install Piper into $ROOT/bin (previous version restored)"
  fi
else
  echo ">> Piper already installed in $ROOT/bin"
fi

# Voice naming: en_GB-jenny_dioco-medium -> en/en_GB/jenny_dioco/medium
lang="${VOICE%%-*}"          # en_GB
rest="${VOICE#*-}"           # jenny_dioco-medium
person="${rest%-*}"          # jenny_dioco
quality="${rest##*-}"        # medium
base="https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/${lang%%_*}/$lang/$person/$quality"

if [[ "$FORCE" == 1 || ! -f "$ROOT/$VOICE.onnx" || ! -f "$ROOT/$VOICE.onnx.json" ]]; then
  echo ">> Downloading voice $VOICE"
  curl -fsSLo "$tmp/$VOICE.onnx.json" "$base/$VOICE.onnx.json"
  curl -fsSLo "$tmp/$VOICE.onnx"      "$base/$VOICE.onnx"
  # Park the installed pair (if any) as a rollback, then move the new pair in,
  # .json last: a voice counts as installed only when both files exist. If a
  # move fails or we are interrupted, the EXIT trap puts the old pair back.
  mkdir -p "$tmp/voice.old"
  for f in "$VOICE.onnx.json" "$VOICE.onnx"; do
    [[ -e "$ROOT/$f" ]] && mv "$ROOT/$f" "$tmp/voice.old/"
  done
  mv "$tmp/$VOICE.onnx" "$ROOT/$VOICE.onnx" && mv "$tmp/$VOICE.onnx.json" "$ROOT/$VOICE.onnx.json" \
    || die "could not install voice $VOICE into $ROOT (previous files restored)"
  rm -rf "$tmp/voice.old"
else
  echo ">> Voice $VOICE already installed"
fi

tts_write_conf_template || true

echo ">> Done. Voices in $ROOT:"
for m in "$ROOT"/*.onnx; do [[ -f "$m" ]] && echo "   $(basename "$m" .onnx)"; done
if [[ "$VOICE" != "$PIPER_VOICE" ]]; then
  echo ">> To use it, set PIPER_VOICE=$VOICE in $TTS_USER_CONF"
fi
echo ">> Test: echo '{\"hook_event_name\":\"Stop\",\"last_assistant_message\":\"It works\"}' | TTS_DEBUG=1 \"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tts-speak.sh\""
