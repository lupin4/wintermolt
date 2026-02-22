<p align="center">
  <pre align="center">
  ╻ ╻╻┏┓╻╺┳╸┏━╸┏━┓┏┳┓┏━┓╻  ╺┳╸
  ┃╻┃┃┃┗┫ ┃ ┣╸ ┣┳┛┃┃┃┃ ┃┃   ┃
  ┗┻┛╹╹ ╹ ╹ ┗━╸╹┗╸╹ ╹┗━┛┗━╸ ╹
  </pre>
  <strong>One binary. 3 MB. Zero runtime. Every AI backend.</strong><br>
  An autonomous AI agent CLI written entirely in Zig.<br><br>
  <a href="#quick-start">Quick Start</a> &bull;
  <a href="#features">Features</a> &bull;
  <a href="#why-wintermolt">Why Wintermolt?</a> &bull;
  <a href="#architecture">Architecture</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/lang-Zig_0.15-f7a41d?style=flat-square&logo=zig&logoColor=white" alt="Zig">
  <img src="https://img.shields.io/badge/license-AGPL--3.0-blue?style=flat-square" alt="License">
  <img src="https://img.shields.io/badge/binary-3_MB-brightgreen?style=flat-square" alt="Size">
  <img src="https://img.shields.io/badge/deps-2_(libcurl%2C_sqlite3)-orange?style=flat-square" alt="Dependencies">
  <img src="https://img.shields.io/badge/backends-6_(Claude%2C_Ollama%2C_GPT%2C_DeepSeek%2C_Qwen%2C_Gemini)-purple?style=flat-square" alt="Backends">
</p>

---

```
$ wintermolt
Wintermolt v0.1.0 — AI Agent CLI
Backend: claude (claude-sonnet-4-5)

> Refactor all error handling in src/ to use proper Zig error unions
[grep] Searching for catch unreachable patterns...
[file_edit] src/api/client.zig: replaced 4 catch unreachable with proper error returns
[file_edit] src/tools/http.zig: wrapped 2 unsafe casts in error handling
[bash] zig build — compiled successfully, 0 errors
Done. Fixed 11 error handling issues across 6 files. All tests pass.

> /schedule add deploy-check every 30m bash deploy_status.sh
[scheduler] Job "deploy-check" added — runs every 30 minutes

> /look What's on my whiteboard?
[camera] Capturing from default camera...
I can see a system architecture diagram with three boxes labeled "API",
"Worker", and "DB". There are arrows showing request flow...

> /tailscale
Tailscale peers:
  dev-macbook     100.64.0.1    macOS     online
  prod-server     100.64.0.2    Linux     online   (last seen: 2m ago)
  jetson-robot    100.64.0.3    Linux     online   (last seen: 30s ago)
```

## Why Wintermolt?

Most AI coding tools ship hundreds of megabytes of Electron or Node.js runtime just to send API calls and edit files. Wintermolt compiles to a **single 3 MB native binary** that cross-compiles to any platform Zig supports — including ARM boards like Jetson and Raspberry Pi.

| | Wintermolt | Claude Code | Cursor | Aider |
|---|:---:|:---:|:---:|:---:|
| **Binary size** | **3 MB** | ~200 MB | ~500 MB | ~50 MB |
| **Runtime** | **None** | Node.js 18+ | Electron | Python 3.8+ |
| **Cross-compile** | **One command** | N/A | N/A | N/A |
| **Runs on Jetson/Pi** | **Yes** | Barely | No | Slow |
| **AI backends** | **6** | 1 | Multiple | Multiple |
| **Camera + vision** | **Built-in** | No | No | No |
| **Browser automation** | **Built-in** | No | No | No |
| **MCP client + server** | **Both** | Client only | Client only | No |
| **Chat bridges** | **4 platforms** | No | No | No |
| **Cron scheduler** | **Built-in** | No | No | No |
| **Mesh networking** | **Tailscale** | No | No | No |
| **Menu bar app** | **macOS native** | No | No | No |
| **License** | **AGPL-3.0** | Proprietary | Proprietary | Apache-2.0 |

---

## Quick Start

### Prerequisites

- **[Zig 0.15.2+](https://ziglang.org/download/)** (single binary, no installer needed)
- **libcurl** + **sqlite3** (pre-installed on macOS and most Linux distros)
- An API key: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, or just run [Ollama](https://ollama.com) locally

### Build & Run

```bash
git clone https://github.com/lupin4/wintermolt.git
cd wintermolt
zig build
./zig-out/bin/wintermolt --setup   # interactive wizard — sets up API keys
```

Three lines. No `npm install`. No `pip install`. No Docker. Just Zig.

### Cross-Compile (one command)

```bash
# ARM Linux — Jetson Orin, Raspberry Pi 5
zig build -Dtarget=aarch64-linux-gnu

# x86_64 Linux — servers, CI, cloud VMs
zig build -Dtarget=x86_64-linux-gnu

# Same 3MB binary. Same features. Zero config.
```

---

## Features

### Agentic Loop

Wintermolt doesn't just answer questions — it **plans and executes multi-step tasks autonomously**, calling tools in sequence until the job is done. Up to 25 tool iterations per turn.

```
> Find all security vulnerabilities in this Express app and fix them

[grep] Searching for SQL injection patterns...
[file_read] Reading src/routes/users.js...
[file_edit] Parameterizing raw SQL query on line 47...
[file_edit] Adding input sanitization to /api/upload...
[grep] Checking for XSS in template files...
[file_edit] Escaping user input in 3 Handlebars templates...
[bash] npm test — 47 passed, 0 failed
Fixed 5 vulnerabilities: 2 SQL injection, 2 XSS, 1 path traversal. All tests pass.
```

### 6 AI Backends — Switch Instantly

```
> /model claude    — Anthropic Claude (Haiku, Sonnet, Opus)
> /model ollama    — Local models (Llama, Qwen, Mistral, Phi — no API key)
> /model openai    — OpenAI GPT-4o, GPT-4.1
> /model deepseek  — DeepSeek V3/R1
> /model qwen      — Qwen 2.5+ Cloud
> /model gemini    — Google Gemini
```

All backends support **streaming**. Ollama runs 100% local, air-gapped, no API key.

### 15 Built-in Tools

The AI invokes these autonomously. No plugins needed.

| Tool | What it does |
|------|-------------|
| `bash` | Execute shell commands with safety guardrails |
| `file_read` | Read any file (text, images via multimodal) |
| `file_write` | Create or overwrite files |
| `file_edit` | Surgical find-and-replace editing |
| `glob` | Recursive file search by pattern |
| `grep` | Content search with regex |
| `http_request` | HTTP GET/POST/PUT/DELETE to any URL |
| `web_search` | DuckDuckGo search (no API key needed) |
| `camera_capture` | Camera snapshots + screenshots + OAK-D depth |
| `image_process` | Format conversion (BMP, PNG via sips/ffmpeg) |
| `browser_control` | Full Chrome automation via DevTools Protocol |
| `memory_search` | Semantic search over conversation history |
| `schedule` | Cron jobs — schedule recurring commands |
| `tailscale` | Mesh VPN — query peers, devices, connectivity |
| `canvas_update` | A2UI — render rich UI surfaces in terminal or web |

### Cron Scheduler

Schedule commands to run automatically. Jobs persist across restarts via SQLite.

```
> /schedule add health-check every 5m bash curl -s https://myapp.com/health
[scheduler] Job "health-check" created — runs every 5 minutes

> /schedule add backup at 03:00 bash ./scripts/backup.sh
[scheduler] Job "backup" created — runs daily at 03:00

> /schedule add report cron 0 9 * * 1 bash ./generate_weekly_report.sh
[scheduler] Job "report" created — runs every Monday at 9:00 AM

> /schedule list
ID          Name           Schedule       Next Run         Status
─────────────────────────────────────────────────────────────────
a7f3b2c1    health-check   every 5m       2 min from now   enabled
d4e8a9f0    backup         daily 03:00    in 6 hours       enabled
b1c2d3e4    report         0 9 * * 1      Monday 09:00     enabled

> /schedule remove a7f3b2c1
[scheduler] Removed "health-check"
```

### Tailscale Mesh Networking

Query your Tailscale network directly from the agent. See all devices, check connectivity, coordinate across machines.

```
> /tailscale
Tailscale Network Status:
  dev-laptop      100.64.0.1    macOS 15.3     online
  build-server    100.64.0.2    Ubuntu 24.04   online    (3s ago)
  jetson-orin     100.64.0.3    Linux 6.1      online    (12s ago)
  raspberry-pi    100.64.0.4    Linux 6.6      offline   (2h ago)

> Ask the AI: "Deploy the latest build to jetson-orin via Tailscale"
[tailscale] Checking connectivity to 100.64.0.3...
[bash] scp -o StrictHostKeyChecking=no ./build/app jetson@100.64.0.3:~/deploy/
[bash] ssh jetson@100.64.0.3 'systemctl restart wintermolt-agent'
Deployed and restarted on jetson-orin. Service is healthy.
```

### macOS Menu Bar App

A native Swift sidecar that lives in your menu bar. Send prompts, see streaming responses, get notifications — without switching windows.

```bash
wintermolt --menubar
```

```
┌─────────────────────────────────────┐
│  W⚡ Wintermolt                      │
├─────────────────────────────────────┤
│  Wintermolt — claude/sonnet (1.2k)  │
│  ─────────────────────────────────  │
│  Quick Prompt...              ⌘P    │
│  New Chat                     ⌘N    │
│  ─────────────────────────────────  │
│  Last: "Deployed to prod, all..."   │
│  ─────────────────────────────────  │
│  Quit                         ⌘Q    │
└─────────────────────────────────────┘
```

Built with AppKit `NSStatusBar` — no Electron, no web views. Communicates with the Zig backend via JSON lines over stdin/stdout, same battle-tested IPC pattern used by the chat and web bridges.

### Canvas / A2UI

The AI can render rich UI surfaces — tables, layouts, code blocks — directly in your terminal using box-drawing characters, or in the browser via the web bridge.

```
> Show me a dashboard of my project health

┌─ Project Health ─────────────────────────────────────┐
│                                                       │
│  ┌─ Build ────────┐  ┌─ Tests ────────┐              │
│  │ Status: passing │  │ 147 passed     │              │
│  │ Time: 2.3s      │  │   0 failed     │              │
│  │ Binary: 3.1 MB  │  │   3 skipped    │              │
│  └─────────────────┘  └────────────────┘              │
│                                                       │
│  ┌─ Dependencies ──────────────────────┐              │
│  │ libcurl  4.5.0   system   OK       │              │
│  │ sqlite3  3.45    system   OK       │              │
│  └─────────────────────────────────────┘              │
└───────────────────────────────────────────────────────┘
```

Uses Google's [A2UI protocol](https://github.com/anthropics/anthropic-cookbook) (Agent-to-UI) — the agent describes *what* to render, the client decides *how*. Terminal gets ANSI box-drawing. Web UI gets native HTML components.

### Persistent Memory

**SQLite history** — Every conversation persists in `~/.wintermolt/history.db`. Resume any session.

**Pinecone RAG** — Optional semantic memory via vector search. The AI automatically indexes conversations and recalls relevant context from past sessions.

```
> /memory search "how did we fix the auth bug last week?"
[rag] Found 3 relevant passages from Feb 14-15 sessions...
```

### MCP (Model Context Protocol)

Full bidirectional MCP support — connect to external tools AND expose yours.

**As client:** Add any MCP server. Configure in `~/.wintermolt/mcp.json`:

```json
{
  "servers": {
    "filesystem": {
      "command": "npx",
      "args": ["@modelcontextprotocol/server-filesystem", "/Users/me"]
    },
    "github": {
      "command": "npx",
      "args": ["@modelcontextprotocol/server-github"]
    }
  }
}
```

**As server:** Expose all 15 tools to any MCP-compatible client:

```bash
wintermolt --mcp-server   # JSON-RPC 2.0 over stdio
```

### Chat Bridges

Deploy Wintermolt as a bot on any messaging platform:

```bash
wintermolt --chat    # Connects to all configured platforms simultaneously
```

| Platform | Env Variable | Features |
|----------|-------------|----------|
| Discord | `DISCORD_BOT_TOKEN` | Channels, DMs, threads |
| Telegram | `TELEGRAM_BOT_TOKEN` | Private + group chats |
| Slack | `SLACK_BOT_TOKEN` + `SLACK_APP_TOKEN` | Socket Mode, channels |
| WhatsApp | `WINTERMOLT_WHATSAPP=1` | Via whatsapp-web.js |

All platforms get the same agentic capabilities — tool use, streaming, file handling.

### Web UI

```bash
wintermolt --web     # Serves http://localhost:3000
```

Real-time streaming via WebSocket. The AI's responses render token-by-token in the browser with tool execution previews.

### Skills System

Extensible skill catalog with built-in skills + runtime plugin discovery from `~/.wintermolt/plugins/`.

---

## All Modes

| Mode | Command | Description |
|:-----|:--------|:------------|
| REPL | `wintermolt` | Interactive terminal session |
| Single-shot | `wintermolt -e "prompt"` | Run one prompt, print result, exit |
| Setup | `wintermolt --setup` | Interactive API key + model wizard |
| Chat | `wintermolt --chat` | Multi-platform messaging bot |
| Web | `wintermolt --web` | Browser UI at localhost:3000 |
| Menu Bar | `wintermolt --menubar` | macOS native status bar app |
| MCP Server | `wintermolt --mcp-server` | Expose tools via JSON-RPC 2.0 |

## All REPL Commands

| Command | Description |
|:--------|:------------|
| `/help` | Show all commands |
| `/quit` `/exit` | Exit the REPL |
| `/clear` `/new` | Archive conversation and start fresh |
| `/model [name]` | Show or switch AI backend |
| `/look [prompt]` | Camera capture + AI vision |
| `/screenshot [prompt]` | Screen capture + AI vision |
| `/schedule` | Manage cron jobs (list, add, remove, enable, disable) |
| `/tailscale` | Show Tailscale network peers and status |
| `/mcp` | Show MCP client/server status |
| `/download <url>` | Download a file |
| `/history` | List recent conversations |
| `/resume [id]` | Resume a past conversation |
| `/search <text>` | Search message history |
| `/memory search <q>` | Search Pinecone RAG memory |
| `/stats` | Database and session statistics |
| `/compact` | Optimize the SQLite database |
| `/export [path]` | Export conversation as JSONL |

---

## Architecture

```
wintermolt (3 MB arm64 binary)
│
├── src/main.zig                 Entry point — REPL, CLI, mode dispatch
├── src/setup.zig                OOBE setup wizard
│
├── src/agent/                   Core AI agent
│   ├── loop.zig                 Agentic loop (prompt → tools → observe → repeat)
│   ├── tools.zig                Tool registry + name-based dispatch
│   ├── config.zig               Env vars, .env files, multi-backend config
│   ├── history.zig              Context window management
│   ├── storage.zig              SQLite persistence (WAL mode)
│   ├── scheduler.zig            Cron/interval/daily job scheduler
│   ├── rag.zig                  Pinecone vector search client
│   ├── skills.zig               Built-in skill catalog
│   ├── skill_loader.zig         Runtime plugin discovery
│   └── export.zig               History export
│
├── src/api/                     Multi-backend AI clients
│   ├── client.zig               Claude API + SSE streaming (libcurl)
│   ├── ollama.zig               Ollama local models (NDJSON streaming)
│   ├── deepseek.zig             OpenAI-compatible (DeepSeek, Qwen, GPT, Gemini)
│   ├── protocol.zig             Anthropic wire types
│   ├── sse.zig                  Server-Sent Events parser
│   ├── openai_sse.zig           OpenAI SSE parser
│   └── ndjson.zig               Newline-delimited JSON parser
│
├── src/tools/                   Tool implementations
│   ├── bash.zig                 Shell execution (safety checks)
│   ├── file.zig                 Read / write / edit
│   ├── glob.zig                 Recursive file search
│   ├── grep.zig                 Content search (regex)
│   ├── http.zig                 HTTP client (libcurl)
│   ├── search.zig               DuckDuckGo web search
│   ├── camera.zig               Camera + OAK-D + screenshots
│   ├── image_io.zig             BMP I/O + format bridge
│   ├── browser.zig              Chrome DevTools Protocol
│   ├── tailscale.zig            Tailscale mesh VPN queries
│   └── canvas.zig               A2UI canvas tool
│
├── src/canvas/
│   └── tui.zig                  Terminal A2UI renderer (ANSI box-drawing)
│
├── src/menubar/
│   └── bridge.zig               macOS menu bar sidecar IPC bridge
│
├── src/mcp/                     Model Context Protocol
│   ├── client.zig               MCP client manager
│   ├── server.zig               MCP server (JSON-RPC 2.0)
│   ├── protocol.zig             MCP types
│   └── json_rpc.zig             JSON-RPC 2.0 protocol
│
├── src/chat/bridge.zig          Chat platform bridge (JSON lines IPC)
├── src/web/bridge.zig           Web UI bridge (WebSocket + JSON lines)
│
└── menubar/                     macOS menu bar Swift sidecar
    ├── Package.swift            Swift package manifest
    └── Sources/main.swift       NSStatusBar app (~270 lines)
```

**External dependencies:** `libcurl` (HTTPS) + `sqlite3` (persistence). That's it. Both are pre-installed on macOS and most Linux.

**IPC pattern:** All sidecars (chat, web, menu bar) communicate via **JSON lines over stdin/stdout pipes**. The Zig binary spawns the sidecar as a child process. No sockets, no HTTP servers, no shared memory. Clean process boundaries.

---

## Environment Variables

### AI Backends

| Variable | Description |
|:---------|:------------|
| `ANTHROPIC_API_KEY` | Claude API key (Haiku, Sonnet, Opus) |
| `OPENAI_API_KEY` | OpenAI API key (GPT-4o, GPT-4.1) |
| `DEEPSEEK_API_KEY` | DeepSeek API key (V3, R1) |
| `QWEN_API_KEY` | Qwen API key (Qwen 2.5+) |
| `GEMINI_API_KEY` | Google Gemini API key |
| `OLLAMA_HOST` | Ollama URL (default: `http://localhost:11434`) |

### Configuration

| Variable | Description |
|:---------|:------------|
| `WINTERMOLT_MODEL` | Default model name |
| `WINTERMOLT_SYSTEM_PROMPT` | Custom system prompt |
| `WINTERMOLT_NO_HISTORY` | Set `1` to disable SQLite persistence |
| `TAILSCALE_API_KEY` | Tailscale REST API key (optional, for device listing) |
| `PINECONE_API_KEY` | Pinecone API key (enables RAG memory) |
| `PINECONE_HOST` | Pinecone index host URL |

Config file: `~/.wintermolt/.env` (created by `wintermolt --setup`)

---

## What Wintermolt Is (and Isn't)

Wintermolt is the **open-source lite edition**. It ships everything above.

**[Wintermute](https://github.com/forKernels/Wintermute)** is the proprietary premium edition. It adds:

| Premium Feature | Description |
|:---------------|:------------|
| forKernels | Fortran HPC computational engine (FFT, CV, DSP, AI, Nav, 3D) |
| Cortex ABC-AGC | Brain-inspired kernel with attention, gating, consolidation |
| Hippocampus | Episodic memory with sleep-cycle consolidation |
| Multi-model council | Debate + synthesis across multiple AI models |
| Reinforcement learning | Q-learning, policy gradients, reward shaping |
| TPU/XLA acceleration | StableHLO/PJRT dispatch for batch compute |
| Fleet management | Multi-device discovery, remote commands, coordination |
| Voice synthesis | Piper TTS, OpenAI TTS, formant engine, R2D2 sounds |
| OAK-D depth camera | Stereo depth, RGB-D, spatial AI |
| Blender automation | 3D scene control via Python bridge |
| Google integrations | Gmail, Calendar, Drive |

---

<p align="center">
  <strong>Built with Zig. No garbage collector. No runtime. No excuses.</strong><br><br>
  Copyright The Fantastic Planet — By David Clabaugh<br>
  AGPL-3.0 License
</p>
