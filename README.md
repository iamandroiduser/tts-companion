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

## Install

> Users no longer need two commands. This adds marketplace and installs in one step:
```bash
/plugin install tts-companion --marketplace iamandroiduser/tts-companion
```

```bash
# 1. Add the marketplace and install the plugin
claude plugin marketplace add iamandroiduser/<repo-name>
claude plugin install tts-companion@iamandroiduser-plugins

# 2. Install the speech engine (Piper + default voice)
"${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/tts-companion}" # see note below
bash scripts/install.sh          # from the plugin directory, or:
# ~/.claude/plugins/cache/iamandroiduser-plugins/tts-companion/*/scripts/install.sh

# 3. Linux deps if missing: sudo apt install curl jq alsa-utils
```

> If you previously added a TTS hook to `~/.claude/settings.json`, remove that
> block — hooks **merge** across settings and plugins, so both would speak twice.

## Try different voices

```bash
bash scripts/tts-try.sh     # speaks a sample in every installed voice
```

Then edit `tts.conf` (in `$CLAUDE_PLUGIN_DATA` when installed as a plugin, else
`~/.claude/tts.conf`):

```bash
ENGINE=piper
PIPER_VOICE=en_US-ryan-high   # or en_US-amy-medium, en_US-lessac-medium, ...
```

Install more voices (100+ available):

```bash
bash scripts/install.sh en_GB-jenny_dioco-medium
```

Browse voices: <https://github.com/OHF-Voice/piper1-gpl/blob/main/docs/VOICES.md>

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
| `hooks/hooks.json` | Stop + Notification hook definitions |
| `scripts/tts-speak.sh` | The hook handler (engine selection, text cleanup) |
| `scripts/install.sh` | Downloads Piper binary + a voice |
| `scripts/tts-try.sh` | Audition all installed voices |

## macOS / Windows notes

macOS: replace the engine with the built-in `say` command.
Windows: hooks run via Git Bash; use PowerShell `System.Speech` or `edge-tts`.

## License

MIT. Piper voices have per-voice licenses (check the voice's config on Hugging Face).
