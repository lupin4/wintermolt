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
| `camera_capture`    | camera, capture, webcam, see, look at, photo           | Camera / screenshot capture, optionally with OAK-D depth. |
| `browser_control`   | browser, chrome, tab, webpage, screenshot, click, navigate, scrape, DOM | Chrome automation via DevTools Protocol.        |
| `memory_search`     | remember, recall, before, history, forgot, memory      | Semantic search over conversation + episode history. |
| `schedule`          | schedule, cron, timer, periodic, remind me, recurring  | Add/remove cron jobs (see [DEPLOYMENT.md](DEPLOYMENT.md#scheduler)). |
| `tailscale`         | tailscale, mesh, vpn, devices, peers, tailnet          | Query the Tailscale REST API for the user's tailnet. |
| `canvas_update`     | canvas, ui, dashboard, chart, form, render, widget     | Push A2UI surfaces to the canvas sidecar.            |
| `text_to_speech`    | speak, say, read aloud, voice, tts, audio              | Synthesize via OpenAI / ElevenLabs / Edge TTS.       |
| `image_generate`    | generate image, dall-e, draw, illustration, render image | DALL-E 3 image generation.                         |
| `google_workspace`  | gmail, email, calendar, meeting, google drive, inbox   | Read + send via Google APIs (OAuth flow on first use). |
| `spawn_agent`       | subagent, spawn, delegate, parallel, subtask           | Fork a child agent with isolated context to run a subtask. |

## Triggering manually

Trigger detection is keyword-based on the user message. If the model
doesn't see a tool it needs, prompt the trigger word explicitly
("take a screenshot of …", "search the web for …").

## Disabling a tool

Tools are gated by `isToolPermitted(name)`. Set
`WINTERMOLT_DISABLE_TOOLS="browser_control,tailscale"` (comma-separated)
to remove specific tools from every turn.

## Safety: the `bash` tool

`bash` runs against the user's actual shell. Defaults to an allowlist
of safe commands (`ls`, `cat`, `grep`, `find`, …) and prompts on
anything else. Override with `WINTERMOLT_BASH_MODE=auto` (no prompt;
use only in trusted/sandboxed environments).
