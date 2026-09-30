# tts-companion

Free text-to-speech for [Claude Code](https://code.claude.com). Speaks assistant
replies aloud when a turn finishes, and speaks alerts when Claude needs your
attention. 100% free: offline neural voices via [Piper](https://github.com/OHF-Voice/piper1-gpl)
by default — no API keys, no accounts, no cloud.

## How it works

A [Stop hook](https://code.claude.com/docs/en/hooks) receives the just-finished
reply as `last_assistant_message` on stdin and pipes it to a speech engine.
A Notification hook (`permission_prompt`, `idle_prompt`) speaks short alerts.
Both run `async`, exit `0`, and never block Claude Code.

A SessionStart hook installs the engine for you: on Linux, the first session
after installing the plugin downloads the Piper binary (~26 MB) and the default
voice, `en_GB-jenny_dioco-medium` (~63 MB). The download runs in the background.
Until it finishes, replies use whatever is already available: `espeak-ng`, or
`say` on macOS. There is no manual setup step.

## Install

```bash
claude plugin marketplace add iamandroiduser/tts-companion
claude plugin install tts-companion@iamandroiduser-plugins
```

Then start a new Claude Code session. Requirements:

- `curl` and `tar` (for the one-time download)
- An audio player: `aplay` (alsa-utils), `paplay`, `pw-play`, `ffplay` or `mpv`
- `jq` or `python3` (to read the hook input)

On Debian/Ubuntu: `sudo apt install curl jq alsa-utils`.

> If you previously added a TTS hook to `~/.claude/settings.json`, remove that
> block. Hooks **merge** across settings and plugins, so both would speak.

## Where things live

| What | Path |
|---|---|
| Settings | `~/.claude/tts.conf` (created with every option commented out) |
| Piper binary + voices | `~/.local/share/piper/` (or `$XDG_DATA_HOME/piper`) |
| Background install log | `~/.local/share/piper/install.log` |

The scripts use the same paths whether Claude Code or you run them, so a manual
test behaves the same as the hook.

## Settings

Edit `~/.claude/tts.conf`:

```bash
ENABLED=1                        # 0 mutes all speech
ENGINE=piper                     # piper | edge | say | espeak
PIPER_VOICE=en_GB-jenny_dioco-medium
MAX_CHARS=1500                   # longer replies stop at a sentence end + "The rest is on screen"; 0 = no limit
STOP_ON_PROMPT=1                 # sending your next prompt stops the current speech
SMART_SPEECH=0                   # 1: a small Claude model describes code, tables and diagrams
SPEAK_REPLIES=1                  # speak each finished reply
SPEAK_NOTIFICATIONS=1            # speak permission / idle alerts
AUTO_INSTALL=1                   # 0 disables the background download
```

If the configured voice isn't installed, the plugin falls back to the default
voice, then to any installed voice. The next session start downloads the
configured voice.

Engine fallback order: `piper` → `edge` → `say` (macOS) → `espeak-ng` /
`espeak` / `spd-say`.

## What gets read aloud

Replies are rewritten for listening before they are spoken (`scripts/speechify.py`):

| In the reply | Spoken as |
|---|---|
| Code blocks, tables, diagrams (Mermaid, ASCII / box drawings) | "Python code on screen.", "Table on screen.", "Diagram on screen." |
| Long or symbol-heavy inline code, URLs, emoji | "code", "a link", dropped |
| `std::vector<int>`, `getUserName()`, `scripts/tts-speak.sh` | "standard vector of int", "get User Name", "tts speak dot sh" |
| `v = ir`, `E = mc^2`, `$\frac{1}{2}mv^2$` | "v equals i r", "E equals m c squared", "1 over 2 m v squared" |
| CH4, H₂O, C6H12O6 | "C H 4", "H 2 O", "C 6 H 12 O 6" |
| π, θ, ≤, ≈, →, x² | "pi", "theta", "less than or equal to", "approximately", "to", "x squared" |

This needs `python3`; without it a simpler filter drops code blocks and keeps the words.

### Smart speech (optional)

With `SMART_SPEECH=1` in `~/.claude/tts.conf`, code blocks, tables, diagrams and
long equations are sent (in one batched request per reply) to a small Claude
model, Haiku by default, through your local `claude` CLI and existing Claude
Code login; no API key needed. For each block it returns a one- or two-sentence
description, e.g. *"A retry helper that tries up to 3 times with exponential
backoff"* or *"Cold start improved from 820 to 310 milliseconds"*. For blocks
not worth hearing, such as install logs, it answers SKIP, and you get the usual
"… on screen" cue.

- Only those blocks are sent. The prose of the reply is never sent or rewritten.
- Adds roughly 5–10 seconds before such replies are spoken, and uses your Claude
  plan (or API credits) for each reply that contains such blocks.
- Any failure (no `claude` on PATH, not logged in, timeout after
  `SMART_SPEECH_TIMEOUT` seconds, unusable answer) falls back to the cues.
- The model runs with no tools, no saved session, and without your settings,
  hooks or plugins (`--setting-sources ""`), so it can't act or re-trigger this plugin.

```bash
SMART_SPEECH=1
SMART_SPEECH_MODEL=haiku      # any `claude --model` value
SMART_SPEECH_TIMEOUT=25
```

## Stop, pause and resume

- **Send your next prompt:** the current speech stops (`STOP_ON_PROMPT=1`).
- **From a terminal**, or from Claude Code's `!` shell mode (`! tts-companion stop`):

  ```bash
  tts-companion stop      # stop the reply being read
  tts-companion pause     # pause; resume continues where it paused
  tts-companion resume
  tts-companion toggle    # pause if playing, resume if paused
  ```

  The plugin keeps `~/.local/bin/tts-companion` pointing at its current version
  (creating `~/.local/bin` if needed; it never replaces another file of that name).
  If `~/.local/bin` isn't on your PATH, run it as `~/.local/bin/tts-companion stop`.
- **A real button:** bind `~/.local/bin/tts-companion toggle` (and `stop`) to a
  keyboard shortcut in your desktop's settings, e.g. GNOME: Settings → Keyboard →
  Custom Shortcuts.

## Try different voices

The scripts live in the plugin cache:

```bash
dir=$(ls -d ~/.claude/plugins/cache/iamandroiduser-plugins/tts-companion/*/scripts | tail -1)
bash "$dir/install.sh" en_US-ryan-high   # add a voice (100+ available)
bash "$dir/tts-try.sh"                   # speak a sample in every installed voice
```

Then set `PIPER_VOICE=<name>` in `~/.claude/tts.conf`.

Browse voices: <https://github.com/OHF-Voice/piper1-gpl/blob/main/docs/VOICES.md>

## Troubleshooting

Check which engine runs, the same way the hook runs it:

```bash
dir=$(ls -d ~/.claude/plugins/cache/iamandroiduser-plugins/tts-companion/*/scripts | tail -1)
echo '{"hook_event_name":"Stop","last_assistant_message":"It works"}' \
  | TTS_DEBUG=1 bash "$dir/tts-speak.sh"
```

`TTS_DEBUG=1` prints each engine it tries and why it skipped it. If Piper is
missing, check `~/.local/share/piper/install.log`. After a failed download, the
plugin waits 6 hours before retrying; to retry now:

```bash
dir=$(ls -d ~/.claude/plugins/cache/iamandroiduser-plugins/tts-companion/*/scripts | tail -1)
bash "$dir/install.sh"
```

## Optional: best-quality online voices (still free, still no API key)

Microsoft Edge neural voices via [edge-tts](https://github.com/rany2/edge-tts)
(requires internet; unofficial endpoint — could break):

```bash
python3 -m venv ~/.local/share/edge-tts
~/.local/share/edge-tts/bin/pip install edge-tts
# then set in tts.conf:  ENGINE=edge
```

## Files

| Path | Purpose |
|---|---|
| `.claude-plugin/plugin.json` | Plugin manifest |
| `.claude-plugin/marketplace.json` | Lets this repo be installed via `plugin marketplace add` |
| `hooks/hooks.json` | SessionStart, UserPromptSubmit, Stop and Notification hook definitions |
| `scripts/lib.sh` | Shared config and path resolution |
| `scripts/bootstrap.sh` | SessionStart: background install of Piper and the voice |
| `scripts/tts-speak.sh` | The hook handler (engine selection, playback) |
| `scripts/speechify.py` | Rewrites Markdown into speakable text |
| `scripts/tts-ctl.sh` | stop / pause / resume / toggle; also the UserPromptSubmit hook |
| `scripts/install.sh` | Downloads the Piper binary and a voice |
| `scripts/tts-try.sh` | Audition all installed voices |

## Platform notes

- **Linux:** full support. Piper is installed automatically.
- **macOS:** works out of the box with the built-in `say` voice. The Piper
  binaries this installer uses are Linux-only.
- **Windows:** not supported yet. Hooks run under Git Bash; the `edge` engine
  may work if `edge-tts` and `ffplay` are on PATH.

## License

MIT. Piper voices have per-voice licenses (check the voice's config on Hugging Face).
