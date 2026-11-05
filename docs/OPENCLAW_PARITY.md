# OpenClaw parity

What [OpenClaw](https://docs.openclaw.ai) does that wintermolt does not, and the
order we close it. Statuses come from reading wintermolt's code on 2026-11-03,
not from its README; OpenClaw's side from docs.openclaw.ai the same day.
Step 2's rows were updated on 2026-11-04.

**Have** = works as OpenClaw's does. **Part** = exists, with the gap named.
**No** = absent. **Out** = not planned for wintermolt (Wintermute or a
companion app is the place, or OpenClaw itself retired it).

## Order

1. **Sessions and context.** Chat session isolation (groups never share the
   owner's DM history), workspace files in the system prompt, `SKILL.md`
   skills.
2. **Control of a run.** `/stop`, bash approval (`/approve`, `ask`), slash
   commands from chat, a message queue while a run is busy.
3. **Observability.** Token usage from each backend, `/status`, `/usage`,
   `/context`, `/think` passed to the backends that take it.
4. **Agent tools.** `apply_patch`, background processes, `web_fetch` (HTML to
   text), `message` (send to a chat), `sessions_*`.
5. **Chat media.** Inbound images and voice notes (transcribed), outbound
   files and voice, typing indicators.
6. **Operations.** `doctor`, a service install, skills install from git or a
   registry, Tailscale serve.

## Matrix

### Sessions and routing (`--chat`)

| OpenClaw | wintermolt | Status | Step |
|---|---|---|---|
| DMs share the `main` session; `session.dmScope` splits them per peer | DMs share one; `WINTERMOLT_CHAT_DM_SCOPE=per-peer` | Have | 1 |
| One session per group | one per group (`chat/access.zig` `sessionKey`) | Have | 1 |
| Sessions persist on disk | a pooled session closed after 30 min idle restarts empty | Part | 2 |
| Multi-agent routing by binding | `/route` bindings, agent pool | Have | |
| `requireMention`, `/activation mention\|always` | `WINTERMOLT_CHAT_REQUIRE_MENTION`, global, startup only | Part | 2 |
| Queue while busy: `/queue`, `/followup`, `/steer` | followup only: messages wait (20 at most) and are answered in order; no `/queue`, steer or collect | Part | 2 |
| Slash commands from a chat message | `/stop`, `/new`, `/reset`, `/status`, `/help`, `/approve`; any other text goes to the model | Part | 2 |
| Typing indicators | none | No | 5 |
| Inbound media, voice-note transcription | attachments parsed, never read | No | 5 |
| DM pairing, allowlists | pairing codes, `WINTERMOLT_CHAT_*` policies | Have | |

### Channels

wintermolt's sidecar (`chat/src/index.ts`) has Discord, Telegram, WhatsApp,
Slack, Signal, IRC, Matrix, LINE, Feishu, Mattermost, Twitch, Nostr, XMPP,
Zulip, Rocket.Chat and iMessage. Teams and Google Chat refuse to start until
they verify their platform's JWT. OpenClaw also has SMS (Twilio), Zalo, QQ,
Nextcloud Talk, Synology Chat, X, WebChat and voice calls: **No**, after
step 5.

### Workspace, memory, skills

| OpenClaw | wintermolt | Status | Step |
|---|---|---|---|
| `AGENTS.md`, `SOUL.md`, `USER.md`, `IDENTITY.md` in the system prompt every turn (20,000 chars per file, 60,000 total, `USER.md` 4,000) | same files and limits, `agent/workspace.zig` | Have | 1 |
| `MEMORY.md` in the prompt, private sessions only | same; groups and per-peer sessions never see it | Have | 1 |
| Templates seeded by `onboard`, `BOOTSTRAP.md` first-run ritual | none; create the files yourself | No | 6 |
| `memory/YYYY-MM-DD.md` daily notes, `memory_search`, `memory_get` | `memory_search` over SQLite history and Pinecone | Part | 4 |
| `SKILL.md` with frontmatter; `<available_skills>` lists name, description, location, read on demand; gated by `os`, `requires.bins`, `requires.env` | same, `agent/skill_md.zig`; loaded through the `skills` tool rather than `read`; `requires.config` not checked | Have | 1 |
| Skill roots: `<workspace>/skills`, `<workspace>/.agents/skills`, `~/.agents/skills`, `~/.openclaw/skills` | those, with `~/.wintermolt/skills`, after the project's `./skills` and `./.agents/skills` | Have | 1 |
| Grouped skill layouts, 6 levels deep | one level below each root | Part | 6 |
| `openclaw skills install` from ClawHub, git, a path | `--extension install` writes a stub | No | 6 |
| Heartbeat | retired upstream, now a scheduled job | Out | |

### Commands

| OpenClaw | wintermolt | Status | Step |
|---|---|---|---|
| `/new`, `/reset` | `/new` = `/clear` | Have | |
| `/compact` summarizes the conversation | drops the oldest messages | Part | 3 |
| `/stop` | `/stop` (full-screen view, chat), Esc (full-screen view, web page), Ctrl+C (plain REPL, `-e`) | Have | 2 |
| `/status`, `/usage`, `/context` | `/stats` with a characters/3 estimate | No | 3 |
| `/think`, `/reasoning`, `/verbose` | none | No | 3 |
| `/elevated`, `/exec`, `/approve` | `WINTERMOLT_BASH_APPROVAL=ask`: `/approve` in chat, y/a/n in the terminal, buttons on the web page; no `/elevated`, `/exec` | Part | 2 |
| `/model`, `/models` | `/model` | Part | 3 |
| `/skill <name> [input]` | `/skill [name] [input]` | Have | 1 |
| A skill's own slash command (`/<name>`) | none | No | 2 |
| `/tts`, `/voice` | `/tts <text>`, `/listen` | Part | |
| `/export-session` | `/export` | Have | |
| `/fork`, `/name`, `/btw`, `/loop`, `/goal` | none | No | 3 |
| `/config`, `/restart`, `/update`, `/whoami`, `/tools`, `/commands` | none | No | 6 |

### Tools

| OpenClaw | wintermolt | Status | Step |
|---|---|---|---|
| `exec`, `read`, `write`, `edit` | `bash`, `file_read`, `file_write`, `file_edit` | Have | |
| `apply_patch` | none | No | 4 |
| `process` (background commands) | none | No | 4 |
| `web_search`, `web_fetch` | `web_search`; `http_request` returns raw HTML | Part | 4 |
| `browser` | `browser_control` (CDP) | Have | |
| `message` | none | No | 4 |
| `sessions_*`, `subagents` | `spawn_agent` | Part | 4 |
| `automations` / `cron` | `schedule` (shell commands only) | Part | 4 |
| `view_image`, `image_generate`, `tts` | `camera_capture view`, `image_generate`, `text_to_speech` | Have | |
| `video_generate`, `music_generate` | none | No | later |
| `ask_user` | none | No | 4 |
| Tool profiles per agent and channel | global allow/block lists | Part | 2 |

### Models and safety

| OpenClaw | wintermolt | Status | Step |
|---|---|---|---|
| Failover, auth-profile rotation | fixed chain: vision, primary, Ollama, OpenAI | Part | 3 |
| Model aliases | none | No | 3 |
| Usage and cost per response | none parsed | No | 3 |
| Docker sandbox for non-main sessions | `WINTERMOLT_SANDBOX` for bash; falls back to the host if Docker fails | Part | 2 |
| OAuth subscriptions | API keys | Out | |

### Gateway, apps, operations

| OpenClaw | wintermolt | Status | Step |
|---|---|---|---|
| Control UI (sessions, config, nodes) | `--web`, served by the binary: chat, the terminal's commands, history you can carry on, skills, workspace files, which keys are set | Part | later |
| WebSocket gateway, nodes | `--gateway`, served by the binary: OpenAI's chat completions (streamed or whole) and models, with an API key. No nodes, no device pairing | Part | later |
| macOS menu bar app | `--menubar` | Have | |
| iOS, Android, watchOS nodes; Voice Wake, Talk Mode | none | Out | |
| `openclaw doctor` | none | No | 6 |
| `gateway install` (service) | none | No | 6 |
| Tailscale serve and funnel | `tailscale` tool: status, devices, ping | Part | 6 |
| Plugins, ClawHub | `~/.wintermolt/plugins` skill manifests | Part | 6 |
