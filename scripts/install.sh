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
tmp=$(mktemp -d "$ROOT/.install.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# Download to a temp dir first, then move into place, so an interrupted
# download never leaves a half-installed binary or voice behind.
if [[ "$FORCE" == 1 || ! -x "$ROOT/bin/piper" ]]; then
  # $ROOT/bin is replaced wholesale, so refuse unless it is empty or already Piper's.
  if [[ -d "$ROOT/bin" && ! -x "$ROOT/bin/piper" && -n "$(ls -A "$ROOT/bin")" ]]; then
    die "$ROOT/bin exists and is not a Piper install; set PIPER_ROOT to a dedicated directory"
  fi
  echo ">> Installing Piper ($asset) into $ROOT/bin"
  mkdir -p "$tmp/bin"
  curl -fsSL "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/$asset" \
    | tar -xz -C "$tmp/bin" --strip-components=1
  [[ -x "$tmp/bin/piper" ]] || die "Piper archive did not contain bin/piper"
  rm -rf "${ROOT:?}/bin"
  mv "$tmp/bin" "$ROOT/bin"
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
  mv "$tmp/$VOICE.onnx.json" "$ROOT/$VOICE.onnx.json"
  mv "$tmp/$VOICE.onnx"      "$ROOT/$VOICE.onnx"
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
