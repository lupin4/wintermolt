# Wintermolt — Lite AI Agent CLI

Copyright The Fantastic Planet - By David Clabaugh

## Overview

Wintermolt is the **AGPL-3.0 lite version** of Wintermute — an AI agent CLI written entirely in Zig.
It provides core agentic capabilities without the proprietary forKernels ecosystem.

**Open-core model**: Wintermolt (free) provides the foundation. Wintermute (paid) adds premium features.

## Architecture

```
src/
├── main.zig              # Entry point: REPL, --chat, --web, --mcp-server, -e, --setup
├── setup.zig             # OOBE wizard (API key, model selection)
├── api/                  # Multi-backend AI clients
│   ├── client.zig        # Claude API + SSE streaming (libcurl)
│   ├── protocol.zig      # Anthropic wire types
│   ├── sse.zig           # SSE line parser
│   ├── ollama.zig        # Ollama local model client
│   ├── deepseek.zig      # OpenAI-compatible client (DeepSeek/Qwen/GPT)
│   ├── openai_sse.zig    # OpenAI SSE parser
│   └── ndjson.zig        # NDJSON parser (Ollama streaming)
├── agent/                # Core agent loop
│   ├── loop.zig          # Agentic loop (send → tools → repeat)
│   ├── tools.zig         # Tool registry + dispatch
│   ├── config.zig        # Configuration (env vars)
│   ├── history.zig       # Conversation history + context management
│   ├── storage.zig       # SQLite persistence
│   ├── skills.zig        # Built-in skill catalog
│   ├── skill_loader.zig  # Runtime skill discovery (~/.wintermolt/skills/)
│   └── export.zig        # Training data export
├── tools/                # Tool implementations
│   ├── bash.zig          # Shell execution
│   ├── file.zig          # file_read, file_write, file_edit
│   ├── glob.zig          # Recursive glob search
│   ├── grep.zig          # Content search
│   ├── http.zig          # HTTP client
│   ├── search.zig        # Web search (DuckDuckGo)
│   ├── image_io.zig      # BMP reader/writer + sips/ffmpeg bridge
│   ├── camera.zig        # Camera capture + screenshots
│   └── browser.zig       # Chrome DevTools Protocol automation
├── chat/                 # Chat platform bridge
│   └── bridge.zig        # Discord/WhatsApp/Telegram/Slack (JSON lines IPC)
├── web/                  # Web UI bridge
│   └── bridge.zig        # WebSocket + JSON lines
└── mcp/                  # Model Context Protocol
    ├── client.zig         # MCP client manager
    ├── server.zig         # MCP server (JSON-RPC 2.0)
    ├── protocol.zig       # MCP types
    └── json_rpc.zig       # JSON-RPC 2.0 protocol
```

## Build

```bash
zig build                              # native (Mac M4)
zig build -Dtarget=aarch64-linux-gnu   # Jetson / Raspberry Pi
zig build run                          # build + run
```

## Dependencies

| Library | Purpose | Linking |
|---------|---------|---------|
| libcurl | HTTPS (Claude API, Ollama, web search) | System dynamic |
| sqlite3 | Persistent chat history | System dynamic |

**NO Fortran archives. NO forKernels. Pure Zig + system libs.**

## What is NOT in Wintermolt (Premium features → Wintermute)

- forKernels computational engine (Fortran + Zig FFI)
- Cortex ABC-AGC brain kernel
- Hippocampus episodic memory + consolidation
- Multi-model council/debate orchestration
- Reinforcement learning (Q-learning, policy gradients)
- TPU/XLA acceleration
- Fleet management (device discovery, remote commands)
- Pinecone RAG + core memory
- Prompt bandit optimization
- Tool predictor (Gaussian Naive Bayes)
- Context compression (executive brief pattern)
- Multi-model routing (GPT triage, cross-route)
- OAK-D depth camera integration
- Google API integration (Gmail, Calendar, Drive)
- Blender automation
- WAV I/O + voice synthesis

## Key Patterns

- **Backend union**: `client.Client | ollama.OllamaClient | deepseek.DeepSeekClient`
- **Tool dispatch**: Name-based lookup in `tools.zig`, falls through to MCP
- **Streaming**: SSE for Claude, NDJSON for Ollama, SSE for OpenAI-compat
- **Config**: `.env` file at `~/.wintermolt/.env`, overrideable by env vars

## Environment Variables

| Variable | Purpose |
|----------|---------|
| `ANTHROPIC_API_KEY` | Claude API key (required for Claude backend) |
| `WINTERMOLT_MODEL` | Default model (default: claude-sonnet-4-20250514) |
| `WINTERMOLT_SYSTEM_PROMPT` | Custom system prompt |
| `OLLAMA_HOST` | Ollama URL (default: http://localhost:11434) |
| `OPENAI_API_KEY` | OpenAI API key (for GPT models) |
| `DEEPSEEK_API_KEY` | DeepSeek API key |
| `QWEN_API_KEY` | Qwen API key |
