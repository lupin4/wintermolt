# Wintermolt

**An AI agent CLI written entirely in Zig.** One 3MB binary. Zero Node.js. Zero Python. Just `zig build` and go.

Wintermolt gives you a local AI assistant with tool execution, web search, file editing, camera input, browser automation, MCP support, and multi-backend AI — all from a single statically-linked executable.

```
$ wintermolt
Wintermolt v0.1.0 — AI Agent CLI (lite)
Backend: claude (claude-sonnet-4-5-20250514)

> Find all TODO comments in my project and create a summary
[bash] grep -rn "TODO" src/ --include="*.zig" | head -30
Found 12 TODO comments across 8 files...

> /look What's on my desk?
[camera] Capturing from default camera...
I can see a laptop, a coffee mug, two monitors...
```

## Why Wintermolt?

| Feature | Wintermolt | Claude Code | Cursor |
|---------|-----------|-------------|--------|
| Binary size | 3 MB | ~200 MB (Node) | ~500 MB (Electron) |
| Dependencies | libcurl, sqlite3 | Node.js 18+ | Chrome runtime |
| Cross-compile | `zig build -Dtarget=aarch64-linux-gnu` | N/A | N/A |
| Runs on Jetson/Pi | Yes | Technically | No |
| AI backends | Claude, Ollama, OpenAI, DeepSeek, Qwen, Gemini | Claude only | Multiple |
| Camera/screenshot | Built-in | No | No |
| Browser automation | Built-in (CDP) | No | No |
| MCP client + server | Both | Client only | Client only |
| Chat bridges | Discord, WhatsApp, Telegram, Slack | No | No |
| License | AGPL-3.0 | Proprietary | Proprietary |

## Quick Start

### Prerequisites

- [Zig 0.15.2+](https://ziglang.org/download/)
- libcurl (system — installed on macOS and most Linux)
- sqlite3 (system — installed on macOS and most Linux)
- An API key: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, or local Ollama

### Build

```bash
git clone https://github.com/thefantasticplanet/wintermolt.git
cd wintermolt
zig build
```

That's it. Binary is at `zig-out/bin/wintermolt`.

### Cross-compile for ARM Linux (Jetson, Raspberry Pi)

```bash
zig build -Dtarget=aarch64-linux-gnu
```

### Cross-compile for x86_64 Linux (servers, CI)

```bash
zig build -Dtarget=x86_64-linux-gnu
```

### First Run

```bash
# Option 1: Set your API key and go
export ANTHROPIC_API_KEY=sk-ant-...
./zig-out/bin/wintermolt

# Option 2: Interactive setup wizard
./zig-out/bin/wintermolt --setup
```

## Features

### Multi-Backend AI

Switch between AI providers on the fly:

```
> /model claude          # Anthropic Claude (default)
> /model ollama          # Local models via Ollama
> /model openai          # OpenAI GPT
> /model deepseek        # DeepSeek
> /model qwen            # Qwen
> /model gemini          # Google Gemini
```

All backends support streaming. Ollama runs 100% local with no API key needed.

### Built-in Tools

Wintermolt ships with 12 tools that the AI can invoke autonomously:

| Tool | Description |
|------|-------------|
| `bash` | Execute shell commands |
| `file_read` | Read file contents |
| `file_write` | Create or overwrite files |
| `file_edit` | Search-and-replace editing |
| `glob` | Find files by pattern |
| `grep` | Search file contents with regex |
| `http_request` | HTTP GET/POST/PUT/DELETE |
| `web_search` | DuckDuckGo search (no API key) |
| `camera_capture` | Camera/OAK-D depth camera capture |
| `image_process` | Image format conversion |
| `browser_control` | Chrome DevTools Protocol automation |
| `memory_search` | Search conversation history + Pinecone RAG |

### Agentic Loop

The AI plans and executes multi-step tasks autonomously, calling tools in sequence until the task is complete. Up to 25 tool-use iterations per turn.

```
> Refactor all the functions in src/utils.zig to use snake_case

[file_read] Reading src/utils.zig...
[file_edit] Renaming getFieldValue -> get_field_value...
[file_edit] Renaming parseJson -> parse_json...
[grep] Searching for call sites...
[file_edit] Updating 3 call sites in main.zig...
Done. Renamed 5 functions and updated 8 call sites.
```

### Persistent Memory

- **SQLite history** — All conversations persist across sessions in `~/.wintermolt/history.db`
- **Pinecone RAG** — Optional semantic memory via Pinecone vector search. The AI indexes conversations automatically and can recall past context.

### MCP (Model Context Protocol)

**As client:** Connect to external MCP servers. Configure in `~/.wintermolt/mcp.json`:

```json
{
  "servers": {
    "filesystem": {
      "command": "npx",
      "args": ["@modelcontextprotocol/server-filesystem", "/Users/me"]
    }
  }
}
```

**As server:** Expose Wintermolt's tools to other MCP clients:

```bash
wintermolt --mcp-server
```

### Chat Bridges

Connect Wintermolt to messaging platforms via TypeScript sidecar processes:

```bash
wintermolt --chat    # Discord, WhatsApp, Telegram, Slack
wintermolt --web     # Browser UI with streaming
```

### Skills System

Extensible skill catalog with both built-in skills and runtime plugins from `~/.wintermolt/plugins/`.

## Modes

| Mode | Command | Description |
|------|---------|-------------|
| Interactive REPL | `wintermolt` | Full interactive session |
| Single-shot | `wintermolt -e "prompt"` | Execute one prompt and exit |
| Setup wizard | `wintermolt --setup` | Configure API keys and preferences |
| Chat bridge | `wintermolt --chat` | Connect to messaging platforms |
| Web UI | `wintermolt --web` | Browser interface with streaming |
| MCP server | `wintermolt --mcp-server` | JSON-RPC 2.0 over stdio |

## REPL Commands

```
/help          — Show help
/quit, /exit   — Exit
/clear, /new   — Start fresh conversation
/model [name]  — Switch AI backend
/look [prompt] — Camera capture + AI description
/screenshot    — Screen capture + AI description
/stats         — Session statistics
/compact       — Compress conversation history
/export [path] — Export history as JSONL
/download URL  — Download a file
```

## Architecture

```
wintermolt (3 MB Zig binary)
├── src/main.zig           — Entry point (REPL, modes, CLI parsing)
├── src/setup.zig          — OOBE setup wizard
├── src/agent/
│   ├── loop.zig           — Agentic loop (plan → execute → observe → repeat)
│   ├── tools.zig          — Tool registry and dispatch
│   ├── history.zig        — Conversation history (context window management)
│   ├── config.zig         — Configuration (env vars, .env files)
│   ├── storage.zig        — SQLite persistence
│   ├── rag.zig            — Pinecone RAG client
│   ├── skills.zig         — Built-in skill catalog
│   ├── skill_loader.zig   — Runtime plugin discovery
│   └── export.zig         — History export
├── src/api/
│   ├── client.zig         — Claude API + SSE streaming (libcurl)
│   ├── ollama.zig         — Ollama local model client
│   ├── deepseek.zig       — OpenAI-compatible client
│   ├── protocol.zig       — Anthropic wire types
│   ├── sse.zig            — SSE line parser
│   ├── openai_sse.zig     — OpenAI SSE parser
│   └── ndjson.zig         — NDJSON parser (Ollama)
├── src/tools/
│   ├── bash.zig           — Shell execution (with safety checks)
│   ├── file.zig           — File read/write/edit
│   ├── glob.zig           — Recursive file search
│   ├── grep.zig           — Content search
│   ├── http.zig           — HTTP client (libcurl)
│   ├── search.zig         — Web search (DuckDuckGo)
│   ├── camera.zig         — Camera + OAK-D + screenshots
│   ├── image_io.zig       — BMP I/O + format conversion
│   └── browser.zig        — Chrome DevTools Protocol
├── src/mcp/
│   ├── client.zig         — MCP client manager
│   ├── server.zig         — MCP server (JSON-RPC 2.0)
│   ├── protocol.zig       — MCP types
│   └── json_rpc.zig       — JSON-RPC 2.0 protocol
├── src/chat/bridge.zig    — Chat platform bridge (IPC)
└── src/web/bridge.zig     — Web UI bridge (WebSocket IPC)
```

**External dependencies:** libcurl (HTTPS) + sqlite3 (persistence). That's it.

## Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `ANTHROPIC_API_KEY` | Claude API key | For Claude backend |
| `OPENAI_API_KEY` | OpenAI API key | For OpenAI/GPT backend |
| `DEEPSEEK_API_KEY` | DeepSeek API key | For DeepSeek backend |
| `QWEN_API_KEY` | Qwen API key | For Qwen backend |
| `GEMINI_API_KEY` | Google Gemini API key | For Gemini backend |
| `OLLAMA_HOST` | Ollama URL | Default: `http://localhost:11434` |
| `WINTERMOLT_MODEL` | Default model name | Optional |
| `WINTERMOLT_SYSTEM_PROMPT` | Custom system prompt | Optional |
| `WINTERMOLT_HISTORY` | Enable/disable history | Default: true |
| `PINECONE_API_KEY` | Pinecone API key | For RAG memory |
| `PINECONE_HOST` | Pinecone host URL | For RAG memory |

## Configuration

Wintermolt reads from `~/.wintermolt/.env` (created by `--setup`):

```bash
ANTHROPIC_API_KEY=sk-ant-...
WINTERMOLT_MODEL=claude-sonnet-4-5-20250514
OLLAMA_HOST=http://localhost:11434
PINECONE_API_KEY=...
PINECONE_HOST=...
```

## License

AGPL-3.0 -- Copyright The Fantastic Planet - By David Clabaugh

Wintermolt is the open-source lite version of Wintermute (proprietary). It includes the full agentic loop, multi-backend AI, tool dispatch, MCP, skills, and chat/web bridges. It does not include forKernels (Fortran HPC), cortex brain, episodic memory, reinforcement learning, fleet management, TPU dispatch, or multi-model council/debate.
