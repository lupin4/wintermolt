# Built-in Tools

Wintermolt ships 20 tools the agent can invoke autonomously. Tools fall
into two groups: **core** (always available, no triggers needed) and
**extended** (activated by keyword matches in the user prompt to keep
the tool-definition payload small).

## Core tools (9)

Always loaded.

| Tool           | Purpose                                                                |
| :------------- | :--------------------------------------------------------------------- |
| `bash`         | Execute shell commands with safety guardrails (configurable allow/deny). |
| `file_read`    | Read any file. Multimodal-aware: images return as base64 for vision models. |
| `file_write`   | Create or overwrite files.                                             |
| `file_edit`    | Surgical find-and-replace editing — exact-match only, no fuzzy.        |
| `glob`         | Recursive file search by pattern (`**/*.zig`, `src/*.json`, etc.).     |
| `grep`         | Content search with regex.                                             |
| `http_request` | HTTP GET / POST / PUT / DELETE to any URL.                             |
| `web_search`   | DuckDuckGo HTML search. No API key needed.                             |
| `skills`       | List + dispatch skills from `skills/` and `~/.wintermolt/skills/`.     |

## Extended tools (11)

Surfaced to the model only when a relevant keyword appears in the
prompt. This keeps the per-turn tool list small.

| Tool                | Triggered by keywords                                  | What it does                                          |
| :------------------ | :----------------------------------------------------- | :---------------------------------------------------- |
| `image_process`     | image, photo, picture, histogram, sobel, edge, resize, blur | Format conversion + filters via `sips` / `ffmpeg`. |
| `camera_capture`    | camera, capture, webcam, look at, screen, image, photo, picture, .png/.jpg/.gif/.webp | Camera frame (`capture`), the screen (`screenshot`), or an image file (`view`), returned as vision input; optionally OAK-D depth. Not offered on a turn whose message already carries an image. |
| `browser_control`   | browser, chrome, tab, webpage, screenshot, click, navigate, scrape, DOM | Chrome automation via DevTools Protocol.        |
| `memory_search`     | remember, recall, before, history, forgot, memory      | Semantic search over conversation + episode history. |
| `schedule`          | schedule, cron, timer, periodic, remind me, recurring  | Add/remove cron jobs (see [DEPLOYMENT.md](DEPLOYMENT.md#scheduler)). |
| `tailscale`         | tailscale, mesh, vpn, devices, peers, tailnet          | Query the Tailscale REST API for the user's tailnet. |
| `canvas_update`     | canvas, ui, dashboard, chart, form, render, widget     | Push A2UI surfaces to the canvas sidecar.            |
| `text_to_speech`    | speak, say, read aloud, voice, tts, audio              | Synthesize via Deepgram / OpenAI / ElevenLabs / Piper / Edge TTS, or the computer's own voice (see [Voice](#voice)). |
| `image_generate`    | generate image, dall-e, draw, illustration, render image | DALL-E 3 image generation.                         |
| `google_workspace`  | gmail, email, calendar, meeting, google drive, inbox   | Read + send via Google APIs (OAuth flow on first use). |
| `spawn_agent`       | subagent, spawn, delegate, parallel, subtask           | Fork a child agent with isolated context to run a subtask. |

## Voice

`/listen [seconds | audio file]` records the microphone (5 s by default),
sends what was said as the prompt, and speaks the reply. `/tts <text>`
speaks text. Keys are your own (`wintermolt --keys`); none is built in.

| Step | Default | Choose with |
| :--- | :------ | :---------- |
| Microphone | ffmpeg: the first DirectShow audio device (Windows), `:0` (macOS), PulseAudio `default` (Linux) | `WINTERMOLT_MIC` |
| Speech to text | whisper.cpp, local, when a `ggml-*.bin` model is in `~/.wintermolt/models`: `whisper-server` on 127.0.0.1:8178, started by the first `/listen` and ended with wintermolt (crash included), else `whisper-cli`; else Deepgram nova-3 with `DEEPGRAM_API_KEY` | `WINTERMOLT_STT_PROVIDER` (`whisper`, `deepgram`), `WINTERMOLT_WHISPER_MODEL` |
| Text to speech | the first with a key: Deepgram Aura-2, OpenAI, ElevenLabs; else the computer's own voice (Windows speech, macOS `say`, `espeak-ng`) | `WINTERMOLT_TTS_PROVIDER` (`deepgram`, `openai`, `elevenlabs`, `piper`, `edge`, `system`), `WINTERMOLT_TTS_VOICE` |
| Playback | `afplay` (macOS), ffmpeg's `ffplay` elsewhere | — |

A whisper.cpp model: `whisper-download-ggml-model.sh large-v3-turbo-q5_0`
(or any from huggingface.co/ggerganov/whisper.cpp), moved into
`~/.wintermolt/models`. Deepgram voices are `aura-2-<name>-en`; give the
name alone (`thalia`, `apollo`, `helena`, …).

## Triggering manually

Trigger detection is keyword-based on the user message. If the model
doesn't see a tool it needs, prompt the trigger word explicitly
("take a screenshot of …", "search the web for …").

## Disabling a tool

Tools are gated by `isToolPermitted(name)`, from two comma-separated
variables (`--keys` offers the blocklist):

- `WINTERMOLT_TOOL_BLOCKLIST="browser_control,tailscale"` removes those
  tools from every turn.
- `WINTERMOLT_TOOL_ALLOWLIST="file_read,grep,glob"` permits only those
  tools. When set, it takes precedence and the blocklist is ignored.

## Safety: the `bash` tool

`bash` runs commands in the user's real shell (`/bin/sh` on macOS and
Linux, `cmd.exe /c` on Windows) without asking. It refuses any command
containing a destructive pattern: `rm -rf /`, `rm -rf ~`, `dd if=`,
`mkfs`, `wipefs`, `shutdown`, `reboot`, `halt`, `init 0`, `init 6`,
`git push --force`, `git push -f`, `git reset --hard`, `git clean -f`.
This is a substring check, not a sandbox.

For isolation, set `WINTERMOLT_SANDBOX=docker` (or `1`). Each command then
runs in `docker run --rm` with the working directory mounted read-only at
`/workspace`:

| Variable                     | Default                     |
| :--------------------------- | :-------------------------- |
| `WINTERMOLT_SANDBOX_IMAGE`   | `wintermolt-sandbox:latest` |
| `WINTERMOLT_SANDBOX_NETWORK` | `none`                      |
| `WINTERMOLT_SANDBOX_MEMORY`  | `256m`                      |
| `WINTERMOLT_SANDBOX_TIMEOUT` | `30` (seconds)              |

If Docker cannot run, Wintermolt prints
`[sandbox] Docker unavailable (...), falling back to host execution` and
runs the command on the host.
