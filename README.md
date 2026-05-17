<p align="center">
  <pre align="center">
   ╦ ╦┬┌┐┌┌┬┐┌─┐┬─┐┌┬┐┌─┐┬ ┌┬┐
  ║║║││││ │ ├┤ ├┬┘││││ ││  │
  ╚╩╝┴┘└┘ ┴ └─┘┴└─┴ ┴└─┘┴─┘┴
  </pre>
  <strong>One binary. Zero runtime. Every AI backend.</strong><br>
  An autonomous AI agent CLI written entirely in Zig.<br><br>
  <a href="#quick-start">Quick Start</a> &bull;
  <a href="#features">Features</a> &bull;
  <a href="#why-wintermolt">Why Wintermolt?</a> &bull;
  <a href="#architecture">Architecture</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/lang-Zig_0.15-f7a41d?style=flat-square&logo=zig&logoColor=white" alt="Zig">
  <img src="https://img.shields.io/badge/license-Apache_2.0-blue?style=flat-square" alt="License">
  <img src="https://img.shields.io/badge/binary-1%E2%80%9312_MB-brightgreen?style=flat-square" alt="Size">
  <img src="https://img.shields.io/badge/platforms-macOS_%7C_Linux_%7C_Windows-success?style=flat-square" alt="Platforms">
  <img src="https://img.shields.io/badge/deps-2_(libcurl%2C_sqlite3)-orange?style=flat-square" alt="Dependencies">
  <img src="https://img.shields.io/badge/backends-7_(Ollama%2C_Claude%2C_GPT%2C_DeepSeek%2C_Qwen%2C_Gemini%2C_forAI)-purple?style=flat-square" alt="Backends">
</p>

---

```
$ wintermolt
Wintermolt v0.4.0 — AI Agent CLI
Backend: ollama (qwen3:0.6b)

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

Most AI coding tools ship hundreds of megabytes of Electron or Node.js runtime just to send API calls and edit files. Wintermolt compiles to a **single native binary** — 1 MB on macOS Apple Silicon, 7 MB on Linux ARM, 12 MB on Windows (statically-linked HTTP/3 stack) — and cross-compiles to any platform Zig supports, including ARM boards like Jetson and Raspberry Pi.

| | Wintermolt | Claude Code | Cursor | Aider |
|---|:---:|:---:|:---:|:---:|
| **Binary size** | **1–12 MB** | ~200 MB | ~500 MB | ~50 MB |
| **Runtime** | **None** | Node.js 18+ | Electron | Python 3.8+ |
| **Cross-compile** | **One command** | N/A | N/A | N/A |
| **Runs on Jetson/Pi** | **Yes** | Barely | No | Slow |
| **Runs on Windows** | **Yes (v0.4+)** | Via WSL | Yes | Yes |
| **AI backends** | **7** | 1 | Multiple | Multiple |
| **Camera + vision** | **Built-in** | No | No | No |
| **Browser automation** | **Built-in** | No | No | No |
| **MCP client + server** | **Both** | Client only | Client only | No |
| **Chat bridges** | **4 platforms** | No | No | No |
| **Cron scheduler** | **Built-in** | No | No | No |
| **Mesh networking** | **Tailscale** | No | No | No |
| **Menu bar app** | **macOS native** | No | No | No |
| **License** | **Apache-2.0** | Proprietary | Proprietary | Apache-2.0 |

---

## Quick Start

> **Two-step setup.** Download the binary, install Ollama, run. No
> compiler, no `npm install`, no Docker. Total time: ~2 minutes.

### Step 1 — Grab the binary for your platform

Pick the line that matches you and paste it into a terminal. The binary
lands as `./wintermolt` (or `wintermolt.exe` on Windows) in your current
directory.

**macOS (Apple Silicon — M1/M2/M3/M4):**

```bash
curl -L -o wintermolt https://github.com/lupin4/wintermolt/raw/main/prebuilt/wintermolt-darwin-arm64 \
  && chmod +x wintermolt
```

**Linux (ARM64 — Jetson, Raspberry Pi 5, AWS Graviton, etc.):**

```bash
curl -L -o wintermolt https://github.com/lupin4/wintermolt/raw/main/prebuilt/wintermolt-linux-arm64 \
  && chmod +x wintermolt
```

**Windows (x86_64) — PowerShell:**

```powershell
Invoke-WebRequest `
  -Uri https://github.com/lupin4/wintermolt/raw/main/prebuilt/wintermolt-windows-x86_64.exe `
  -OutFile wintermolt.exe
```

**Linux (x86_64 — servers, cloud VMs):** prebuilt binary not yet
shipped — [build from source](#build-from-source) (one Zig command).

### Step 2 — Install Ollama (optional but recommended)

Wintermolt's default backend is [Ollama](https://ollama.com), which
runs models locally. No API key needed.

```bash
# macOS / Linux
curl -fsSL https://ollama.com/install.sh | sh

# Windows: download installer from https://ollama.com/download/windows

# Then pull the default model (~500 MB)
ollama pull qwen3:0.6b
```

Prefer cloud models? Skip Ollama and run `./wintermolt --keys` to set
an API key for Claude, GPT, DeepSeek, Qwen, Gemini, or forAI.

### Step 3 — Run

```bash
./wintermolt                          # interactive REPL
./wintermolt -e "list files in pwd"   # one-shot prompt
./wintermolt --keys                   # configure cloud API keys
./wintermolt --help                   # all commands
```

That's it. You're running.

### Platform notes

| Platform | Binary | Size | Notes |
|:---|:---|---:|:---|
| macOS arm64 | [`wintermolt-darwin-arm64`](prebuilt/wintermolt-darwin-arm64) | 1.1 MB | Mach-O, dynamic libcurl + sqlite3 |
| Linux arm64 | [`wintermolt-linux-arm64`](prebuilt/wintermolt-linux-arm64) | 7 MB | ELF aarch64, dynamic |
| Windows x86_64 | [`wintermolt-windows-x86_64.exe`](prebuilt/wintermolt-windows-x86_64.exe) | 12 MB | PE32+, static HTTP/3 + crypto. **Runtime needs MSYS2 UCRT64 DLLs on `PATH`** — install via [MSYS2](https://www.msys2.org/) once, then `pacman -S mingw-w64-ucrt-x86_64-curl mingw-w64-ucrt-x86_64-sqlite3`. |
| Linux x86_64 | _build from source_ | — | `zig build -Dtarget=x86_64-linux-gnu` |

---

## Build from source

If you want to compile yourself (also required for Linux x86_64 today).

### Prerequisites

- **[Zig 0.15.2+](https://ziglang.org/download/)** (one binary, no installer)
- **libcurl** + **sqlite3** dev headers:
  - **macOS**: `brew install curl sqlite3` (usually preinstalled)
  - **Linux (Debian/Ubuntu)**: `sudo apt-get install libcurl4-openssl-dev libsqlite3-dev`
  - **Linux (Fedora/RHEL)**: `sudo dnf install libcurl-devel sqlite-devel`
  - **Windows**: install [MSYS2 UCRT64](https://www.msys2.org/), then `pacman -S mingw-w64-ucrt-x86_64-curl mingw-w64-ucrt-x86_64-sqlite3`

### Build & Run

```bash
git clone https://github.com/lupin4/wintermolt.git
cd wintermolt
zig build -Doptimize=ReleaseSmall
./zig-out/bin/wintermolt
```

### Cross-Compile (one command)

```bash
zig build -Dtarget=aarch64-linux-gnu   # Linux ARM — Jetson, Pi 5
zig build -Dtarget=x86_64-linux-gnu    # Linux x86_64 — servers, VMs
zig build -Dtarget=aarch64-macos-none  # macOS Apple Silicon
zig build -Dtarget=x86_64-windows-gnu  # Windows (needs MSYS2 UCRT64 on the build host)
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
> /model ollama    — Local models (Llama, Qwen, Mistral, Phi — no API key, DEFAULT)
> /model claude    — Anthropic Claude (API key required)
> /model openai    — OpenAI GPT-4o, GPT-4.1
> /model deepseek  — DeepSeek V3/R1
> /model qwen      — Qwen 2.5+ Cloud
> /model gemini    — Google Gemini
```

All backends support **streaming**. Ollama runs 100% local, air-gapped, no API key. Cloud backends are optional — bring your own key via `/keys`.

> **Note on Claude:** Claude was previously removed when Anthropic restricted non-API usage. It has been re-added as an optional backend for users who want Claude via the API. The default remains local (Ollama) — no API key is required to use Wintermolt. Use `/keys` or `--keys` to configure your `ANTHROPIC_API_KEY` if you want Claude.

### 79 Model-Agnostic Skills

Wintermolt ships with 79 skill definitions across 11 domains. Each skill defines a specialized agent role with a preferred model — but any skill can run on any backend.

| Domain | Skills | Default Model |
|--------|:------:|---------------|
| Zortran Core | 6 | qwen3:30b |
| Fortran Kernels | 6 | qwen3:30b |
| Zig Systems | 6 | qwen3:30b |
| Physics / Simulation | 6 | qwen3:30b |
| AI / ML Kernels | 6 | qwen3:30b |
| Cybersecurity | 6 | qwen3:30b |
| Synthetic Data | 6 | qwen3:8b |
| Agent Architecture | 6 | qwen3:8b |
| Audio / Music | 8 | qwen3:8b |
| 3D / VFX | 9 | qwen3:8b |
| Engineering (general) | 14 | qwen3:8b |

Skills live in `skills/` as `skill.json` manifests. Each specifies `backend`, `model`, and `role_prompt` — swap to Claude, GPT, or any Ollama model by editing one field. Subagents automatically switch to the skill's preferred backend when spawned.

### 16 Built-in Tools

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
| `harness_create` | Generate CLI-Anything harness for any software |

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
│  Wintermolt — ollama/qwen3 (1.2k)   │
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

### CLI-Anything — Make Any Software Agent-Native

Wintermolt integrates [CLI-Anything](https://github.com/forKernels/CLI-Anything), a framework that turns any software into an AI-controllable tool by generating structured CLI wrappers.

```
> Create a harness for OBS Studio using its WebSocket API

[harness_create] Generating CLI-Anything harness for "obs"...
  obs/agent-harness/
    setup.py
    cli_anything/obs/obs_cli.py          (Click CLI with --json)
    cli_anything/obs/core/backend.py     (WebSocket backend)
    cli_anything/obs/skills/SKILL.md     (AI-discoverable metadata)

[bash] pip install -e obs/agent-harness/
Done. OBS is now agent-native. Try: cli-anything-obs --json scene list
```

The generated harness follows CLI-Anything conventions: `--json` flag for structured output, Click command groups for tool dispatch, and a SKILL.md that lets any AI agent auto-discover the tool's capabilities. Wintermolt discovers installed harnesses automatically via the MCP bridge.

Existing CLI-Anything harnesses include Blender, Audacity, ComfyUI, CloudCompare, and [many more](https://github.com/forKernels/CLI-Anything).

### Skills System

Extensible skill catalog with built-in skills + runtime plugin discovery from `~/.wintermolt/plugins/`.

### forAgent — Persistent Agent Sessions

Wintermolt ships with [forAgent](https://github.com/forKernels/forAgent), a framework for persistent, stateful agent-to-software connections. forAgent provides session management, transport adapters (TCP, Unix socket, HTTP, subprocess), state tracking, tool registry, and MCP protocol handling.

When Wintermolt connects to external software (Blender, OBS, Docker, etc.), forAgent manages the persistent session — keeping state, tracking changes, and providing a clean tool interface that the AI can use autonomously.

### forLearn — Online Learning + Harness Generation

Wintermolt ships with [forLearn](https://github.com/forKernels/forLearn), which provides two capabilities:

**Online learning kernels** — unsupervised and reinforcement learning algorithms that run on-device with fixed memory budgets. All kernels are pure Zig (no Fortran dependency in Wintermolt):

| Kernel | Algorithm |
|--------|-----------|
| Memory buffer | Circular ring buffer for streaming samples |
| Hebbian network | Associative weight learning (no backprop) |
| Online K-Means | Streaming clustering with EMA centroid update |
| Self-Organizing Map | Topology-preserving 2D Kohonen network |
| Anomaly detector | Welford's online mean/variance + pseudo-Mahalanobis |
| Online predictor | Per-feature autoregressive model |
| Q-Learning | Tabular RL with epsilon-greedy |
| Curiosity | Intrinsic motivation via forward-model prediction error |

**Harness generation** — scaffolds [CLI-Anything](https://github.com/forKernels/CLI-Anything) projects for connecting to new software. The `harness_create` tool generates a complete pip-installable Python CLI with `--json` support, backend adapter, and SKILL.md — making any application agent-native in one command.

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

## Documentation

| Page | Covers |
| :--- | :--- |
| [docs/BACKENDS.md](docs/BACKENDS.md) | All 7 backends, default models, env vars, `--keys` flow. |
| [docs/TOOLS.md](docs/TOOLS.md) | The 20 built-in tools (9 core + 11 extended), triggers, safety. |
| [docs/SKILLS.md](docs/SKILLS.md) | Skill manifest format, built-in catalog, custom skills. |
| [docs/MCP.md](docs/MCP.md) | MCP client + server, `~/.wintermolt/mcp.json`, Claude Desktop / Zed wiring. |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | Run modes (`--chat`, `--web`, `--menubar`, `--gateway`), 18 chat platforms, scheduler, Tailscale, persistent storage. |

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
│   ├── client.zig               (legacy, unused)
│   ├── ollama.zig               Ollama local models (NDJSON streaming)
│   ├── deepseek.zig             OpenAI-compatible (DeepSeek, Qwen, GPT, Gemini)
│   ├── protocol.zig             Message wire types
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
├── prebuilt/                    Prebuilt executables (committed to repo)
│   ├── wintermolt-darwin-arm64        macOS Apple Silicon
│   ├── wintermolt-linux-arm64         Linux ARM64 (Jetson, Pi 5)
│   └── wintermolt-windows-x86_64.exe  Windows x86_64
│
└── menubar/                     macOS menu bar Swift sidecar
    ├── Package.swift            Swift package manifest
    └── Sources/main.swift       NSStatusBar app (~270 lines)
```

**External dependencies:** `libcurl` (HTTPS) + `sqlite3` (persistence). That's it. Pre-installed on macOS and most Linux. On Windows, install via MSYS2 UCRT64 (see [Prerequisites](#prerequisites)).

**Prebuilt libraries:** `libforagent.a` and `libforlearn.a` are pure Zig static archives — no Fortran runtime, no gfortran needed. For kernel-accelerated inference and Fortran-backed compute, see [Wintermute](https://github.com/lupin4/Wintermute) (proprietary).

**IPC pattern:** All sidecars (chat, web, menu bar) communicate via **JSON lines over stdin/stdout pipes**. The Zig binary spawns the sidecar as a child process. No sockets, no HTTP servers, no shared memory. Clean process boundaries.

---

## Environment Variables

### AI Backends

| Variable | Default | Description |
|:---------|:--------|:------------|
| `WINTERMOLT_OLLAMA_URL` | `http://localhost:11434` | Ollama base URL |
| `WINTERMOLT_OLLAMA_CTX` | `4096` | Context window cap (prevents OOM on small devices) |
| `WINTERMOLT_OLLAMA_KEEP_ALIVE` | `5m` | Model unload timer (`0` = unload after each response) |
| `WINTERMOLT_MODEL` | `qwen3:0.6b` | Default model |
| `OPENAI_API_KEY` | — | OpenAI API key (GPT-4o, GPT-4.1) |
| `DEEPSEEK_API_KEY` | — | DeepSeek API key (V3, R1) |
| `QWEN_API_KEY` | — | Qwen API key (Qwen 2.5+) |
| `GOOGLE_GEMINI_API_KEY` | — | Google Gemini API key |

### Configuration

| Variable | Default | Description |
|:---------|:--------|:------------|
| `WINTERMOLT_TOKENS` | `8192` | Max output tokens |
| `WINTERMOLT_NO_HISTORY` | — | Set `1` to disable SQLite persistence |
| `TAILSCALE_API_KEY` | — | Tailscale REST API key (optional) |
| `PINECONE_API_KEY` | — | Pinecone API key (enables RAG memory) |
| `PINECONE_HOST` | — | Pinecone index host URL |

Config file: `~/.wintermolt/.env` (created by `wintermolt --setup`)

---

<p align="center">
  <strong>Built with Zig.</strong><br><br>
  Copyright The Fantastic Planet — By David Clabaugh<br>
  Apache License 2.0
</p>
