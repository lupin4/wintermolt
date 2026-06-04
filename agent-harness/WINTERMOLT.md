# WINTERMOLT.md — CLI-Anything Standard Operating Procedure

## Software Overview

**Wintermolt** is an autonomous AI agent CLI written in Zig. Single 3MB binary, zero runtime,
6 AI backends (Claude, Ollama, OpenAI, DeepSeek, Qwen, Gemini), 16+ built-in tools,
cron scheduler, Tailscale mesh, MCP client+server, 18 chat platform bridges, web UI, macOS menu bar.

## Architecture

Wintermolt is a self-contained Zig binary that communicates with AI backends via HTTP (libcurl)
and persists state in SQLite databases:

- `~/.wintermolt/history.db` — Conversation history (messages, conversations)
- `~/.wintermolt/sessions.db` — Chat session lifecycle
- `~/.wintermolt/scheduler.db` — Cron job persistence
- `~/.wintermolt/routing.db` — Multi-agent routing bindings
- `~/.wintermolt/.env` — Configuration (API keys, model settings)

## Harness Strategy

The CLI harness wraps the `wintermolt` binary via subprocess, using:
- `-e "prompt"` for single-shot agent execution
- `--mcp-server` for structured JSON-RPC tool invocation
- Direct SQLite reads for history/session/scheduler queries (read-only)
- Environment variable manipulation for configuration

## Command Groups

| Group | Maps to | Method |
|-------|---------|--------|
| `agent` | Agentic loop (prompt → tools → observe → repeat) | subprocess `-e` |
| `model` | Backend switching (claude, ollama, openai, etc.) | env vars + subprocess |
| `config` | Configuration management | `.env` file + env vars |
| `history` | Conversation history | SQLite read |
| `session` | Session lifecycle | SQLite read |
| `schedule` | Cron job management | subprocess REPL commands |
| `tool` | Direct tool invocation | subprocess or MCP |
| `export` | History export | subprocess `/export` |
| `mcp` | MCP server/client status | subprocess |
| `extension` | Extension management | subprocess `--extension` |

## Key Constraints

1. Wintermolt binary must be in PATH or specified via `WINTERMOLT_BIN` env var
2. API keys must be set in environment or `~/.wintermolt/.env`
3. SQLite databases are WAL-mode — safe for concurrent reads
4. Single-shot mode (`-e`) returns agent output to stdout, logs to stderr
5. Chat/web/menubar modes are long-running — harness uses `agent run` for one-shot only
