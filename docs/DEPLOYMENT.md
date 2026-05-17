# Deployment

Modes Wintermolt can run in beyond the interactive REPL, and how to
keep them running.

## Run modes

| Flag             | Purpose                                                  |
| :--------------- | :------------------------------------------------------- |
| _(none)_         | Interactive REPL.                                        |
| `-e "<prompt>"`  | One-shot execution; prints response, exits.              |
| `--keys`         | Interactive credential setup (also `--setup`).           |
| `--chat`         | Spawn the chat-bridge sidecar (18 platforms).            |
| `--web`          | Spawn the web UI bridge (WebSocket + JSON lines).        |
| `--menubar`      | macOS menu bar sidecar.                                  |
| `--gateway`      | OpenAI-compatible HTTP gateway on `:8080`.               |
| `--mcp-server`   | JSON-RPC 2.0 MCP server over stdio (see [MCP.md](MCP.md)). |
| `--extension <cmd>` | Plugin manager: `list`, `available`, `install`, `remove`. |

## Chat bridges (18 platforms)

`./wintermolt --chat` spawns the chat sidecar. Per-platform env vars
gate which integrations come online — anything without credentials
is silently skipped.

| Platform   | Required env                                                |
| :--------- | :---------------------------------------------------------- |
| Discord    | `DISCORD_BOT_TOKEN`                                         |
| Telegram   | `TELEGRAM_BOT_TOKEN`                                        |
| WhatsApp   | `WHATSAPP_PHONE_ID` + `WHATSAPP_ACCESS_TOKEN`               |
| Slack      | `SLACK_BOT_TOKEN` (+ `SLACK_APP_TOKEN` for Socket Mode)     |
| Signal     | `SIGNAL_PHONE_NUMBER` (requires `signal-cli` on PATH)       |
| iMessage   | `IMESSAGE_APPLEID` (macOS only)                             |
| IRC        | `IRC_SERVER` + `IRC_NICK` + `IRC_CHANNELS`                  |
| Matrix     | `MATRIX_HOMESERVER` + `MATRIX_ACCESS_TOKEN` + `MATRIX_USER_ID` |
| Teams      | `TEAMS_APP_ID` + `TEAMS_APP_PASSWORD`                       |
| Google Chat| `GOOGLE_CHAT_CREDENTIALS`                                   |
| LINE       | `LINE_CHANNEL_SECRET` + `LINE_CHANNEL_TOKEN`                |
| Feishu/Lark| `FEISHU_APP_ID` + `FEISHU_APP_SECRET`                       |
| Mattermost | `MATTERMOST_URL` + `MATTERMOST_TOKEN`                       |
| Twitch     | `TWITCH_ACCESS_TOKEN` + `TWITCH_CHANNELS`                   |
| Nostr      | `NOSTR_PRIVATE_KEY` (+ `NOSTR_RELAYS`)                      |
| XMPP/Jabber| `XMPP_JID` + `XMPP_PASSWORD`                                |
| Zulip      | `ZULIP_EMAIL` + `ZULIP_API_KEY` + `ZULIP_SITE`              |
| Rocket.Chat| `ROCKETCHAT_URL` + `ROCKETCHAT_TOKEN` + `ROCKETCHAT_USER_ID` |

IPC: the Zig binary spawns the sidecar as a child and they exchange
JSON-lines over stdin/stdout. No sockets, no shared memory.

## Web UI

```bash
./wintermolt --web
```

Spawns the web sidecar (WebSocket + static files). Default port is
configurable via `WINTERMOLT_WEB_PORT` (defaults to `7878`). Visit
`http://localhost:7878`.

## macOS menu bar

```bash
./wintermolt --menubar
```

Runs the `menubar/` Swift sidecar (`NSStatusBar` app, ~270 lines).
Click the menu bar icon to chat without a terminal. macOS-only.

## OpenAI-compatible gateway

```bash
./wintermolt --gateway
```

Listens on `:8080` and accepts `POST /v1/chat/completions` requests
in the OpenAI Chat Completions format. Useful for routing existing
OpenAI-client code through Wintermolt's backend dispatcher.

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "ollama:qwen3:0.6b", "messages": [{"role": "user", "content": "hi"}]}'
```

## Scheduler

Wintermolt has a built-in cron scheduler that persists across restarts
via SQLite (`~/.wintermolt/scheduler.db`).

From the REPL:

```
> /schedule add health-check every 5m bash curl -s https://myapp.com/health
> /schedule add backup at 03:00 bash ./scripts/backup.sh
> /schedule add report cron "0 9 * * 1" bash ./generate_weekly_report.sh
> /schedule list
> /schedule remove health-check
```

The scheduler ticks on every REPL turn. For background scheduling, run
Wintermolt with `--chat` or `--web` — both keep a tick loop running.

## Tailscale

Set `TAILSCALE_API_KEY` to enable the `tailscale` tool, which queries
your tailnet for connected peers, devices, and reachability. Tailscale
itself doesn't need to run on the host where Wintermolt is — the tool
hits the REST API.

```
> /tailscale
```

## Persistent storage

| Path                              | Contents                                  |
| :-------------------------------- | :---------------------------------------- |
| `~/.wintermolt/.env`              | API keys and config (from `--keys`).      |
| `~/.wintermolt/history.db`        | SQLite — conversation history, sessions.  |
| `~/.wintermolt/scheduler.db`      | SQLite — cron jobs.                       |
| `~/.wintermolt/mcp.json`          | MCP client config (see [MCP.md](MCP.md)). |
| `~/.wintermolt/skills/`           | User-installed [skills](SKILLS.md).       |
| `~/.wintermolt/plugins/`          | User extensions.                          |

Disable history persistence: `WINTERMOLT_NO_HISTORY=1`.
