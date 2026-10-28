# Deployment

Modes Wintermolt can run in beyond the interactive REPL, and how to
keep them running.

## Run modes

| Flag             | Purpose                                                  |
| :--------------- | :------------------------------------------------------- |
| _(none)_         | Interactive chat: full-screen view in a terminal, plain REPL otherwise. |
| `--plain`        | Plain line-by-line REPL in a terminal (also `WINTERMOLT_PLAIN=1`). |
| `--theme <name>` | Full-screen view theme (also `WINTERMOLT_THEME`, `/theme`). |
| `-e "<prompt>"`  | One-shot execution; prints response, exits. Status 1 if no backend answered. |
| `--version`, `--help` | Print the version, or usage, and exit.              |
| `--keys`         | Interactive credential setup (also `--setup`).           |
| `--chat`         | Spawn the chat-bridge sidecar (see [who can reach the agent](#who-can-reach-the-agent)). |
| `--pairing <cmd>` | Chat access: `list`, `approve <platform> <code>`, `revoke <platform> <sender>`. |
| `--web`          | Spawn the web UI bridge (WebSocket + JSON lines).        |
| `--menubar`      | macOS menu bar sidecar.                                  |
| `--gateway`      | OpenAI-compatible HTTP gateway on `:8080`.               |
| `--mcp-server`   | JSON-RPC 2.0 MCP server over stdio (see [MCP.md](MCP.md)). |
| `--extension <cmd>` | Plugin manager: `list`, `available`, `install`, `remove`. |

## Chat bridges

`./wintermolt --chat` spawns the chat sidecar. Per-platform env vars
gate which integrations come online — anything without credentials
is silently skipped. Sixteen platforms start; Teams and Google Chat
do not yet (below).

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
| Teams      | Not available yet: inbound POSTs are not authenticated and replies are not sent, so the sidecar does not start it |
| Google Chat| Not available yet, for the same two reasons                 |
| LINE       | `LINE_CHANNEL_SECRET` + `LINE_CHANNEL_TOKEN` (the secret verifies every webhook) |
| Feishu/Lark| `FEISHU_APP_ID` + `FEISHU_APP_SECRET` + `FEISHU_VERIFICATION_TOKEN` |
| Mattermost | `MATTERMOST_URL` + `MATTERMOST_TOKEN`                       |
| Twitch     | `TWITCH_ACCESS_TOKEN` + `TWITCH_CHANNELS`                   |
| Nostr      | `NOSTR_PRIVATE_KEY` (+ `NOSTR_RELAYS`)                      |
| XMPP/Jabber| `XMPP_JID` + `XMPP_PASSWORD`                                |
| Zulip      | `ZULIP_EMAIL` + `ZULIP_API_KEY` + `ZULIP_SITE`              |
| Rocket.Chat| `ROCKETCHAT_URL` + `ROCKETCHAT_TOKEN` + `ROCKETCHAT_USER_ID` |

IPC: the Zig binary spawns the sidecar as a child and they exchange
JSON-lines over stdin/stdout. No sockets, no shared memory.

### Who can reach the agent

A chat message ends in an agent that can run `bash` on this host, so
nobody reaches it until you allow them. The rules and defaults are
OpenClaw's.

**Direct messages** follow `WINTERMOLT_CHAT_DM_POLICY`:

| Policy | Behavior |
| :----- | :------- |
| `pairing` (default) | An unknown sender is sent a pairing code, and nothing they write reaches the agent until you approve it. A code lasts one hour; a sender who writes again meanwhile is not sent another. Each platform holds at most 3 pending requests. |
| `allowlist` | Only senders in `WINTERMOLT_CHAT_ALLOW_FROM`. No handshake. |
| `open` | Anyone. |
| `disabled` | No direct message is processed. |

Approve and manage senders from another terminal while `--chat` runs:

```bash
wintermolt --pairing list [platform]           # pending codes and approved senders
wintermolt --pairing approve telegram ACDE3467  # the code the sender was sent
wintermolt --pairing revoke telegram 123456789
```

Approvals live in `~/.wintermolt/chat_access.db` and grant direct
messages only.

**Groups** follow `WINTERMOLT_CHAT_GROUP_POLICY`, checked in this order:

1. `disabled` drops every group message. `open` admits any group and any
   member. `allowlist` (the default) admits a group only if it is in
   `WINTERMOLT_CHAT_GROUPS`, and then only senders in
   `WINTERMOLT_CHAT_GROUP_ALLOW_FROM`. When that is unset it falls back to
   `WINTERMOLT_CHAT_ALLOW_FROM`, never to pairing approvals.
2. The bot must be @-mentioned, or the message must reply to it, unless
   `WINTERMOLT_CHAT_REQUIRE_MENTION=0`.

Lists are comma separated `platform:id` entries, or `*` for everyone.
Only the first `:` splits an entry, so `matrix:@alice:example.org` is one
Matrix user. A group entry can name the chat, or on Discord and Zulip a
whole server or stream: `discord:<guild id>`, `zulip:<stream id>`.

```bash
# One owner, one group where only they can trigger the bot by mentioning it
WINTERMOLT_CHAT_ALLOW_FROM=telegram:123456789 \
WINTERMOLT_CHAT_GROUPS=telegram:-1001234567890 \
wintermolt --chat
```

A value that is not one of the above stops `--chat` at startup rather
than being read as a default. Every dropped message is logged with the
reason.

Per platform:

- **iMessage** groups carry no mention a script can read, so they only
  reach the agent with `WINTERMOLT_CHAT_REQUIRE_MENTION=0`.
- **IRC** nicks are not authenticated. On a network that does not enforce
  registered nicks, someone can take an allowlisted nick while its owner
  is away.
- **Twitch** reads channel chat only (no whispers), so everything there is
  a group message.

## Web UI

```bash
./wintermolt --web
```

Spawns the web sidecar (WebSocket + static files) on port `3000`. `PORT`
or `WINTERMOLT_WEB_PORT` changes it (`PORT` wins when both are set). Visit
`http://localhost:3000`.

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

Listens on `:8080` (`WINTERMOLT_GATEWAY_PORT` changes it) and accepts `POST /v1/chat/completions` requests
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
