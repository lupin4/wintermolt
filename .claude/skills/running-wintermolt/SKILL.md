---
name: running-wintermolt
description: Use when building, running, launching, smoke-testing, or verifying the wintermolt binary — covers zig build, single-shot -e mode, driving the REPL, backend requirements (Ollama), and crash diagnosis.
---

# Running Wintermolt

Wintermolt is a single Zig binary: an agentic AI CLI (the MIT/open-source lite
version of Wintermute, an OpenClaw-like assistant). Multi-backend (Ollama,
Claude, OpenAI-compat, local Metal "kernel"), with tools, MCP, and skills.

## Build

```bash
zig build                # → zig-out/bin/wintermolt (silent on success)
```

Needs system libcurl + sqlite3 (preinstalled on macOS). Zig 0.15.x
(via zigup at ~/.local/share/zigup/). Cross-compile:
`zig build -Dtarget=aarch64-linux-gnu` (Jetson/Pi) or `x86_64-linux-gnu`.

## Run + verify (the smoke test)

**Single-shot** — exercises the full agent loop, exits when done:

```bash
./zig-out/bin/wintermolt -e "Reply with exactly: WINTERMOLT OK"
```

Expected: `WINTERMOLT OK` on stdout. Two benign stderr lines always appear
(`[config] Run 'wintermolt --setup'...` and `[mcp-client] No config...`) —
not errors.

**REPL** — drive it by piping commands (it reads stdin line-by-line):

```bash
printf '/stats\n/schedule list\n/quit\n' | ./zig-out/bin/wintermolt
```

Expected: ASCII banner, stats block (backend/model), jobs list, `Goodbye.`

## Backend requirement

Prompts need an AI backend. Default is **Ollama at localhost:11434**
(check: `curl -s http://localhost:11434/api/tags`). No Ollama → set
`ANTHROPIC_API_KEY` and use `/model claude`, or expect a backend error.
Slash commands (`/stats`, `/help`...) work without any backend.

## Other modes

`--help` (full list), `--web` (web UI), `--gateway` (OpenAI-compat server,
port `WINTERMOLT_GATEWAY_PORT` default 8080), `--mcp-server`, `--chat`,
`--keys` (configure API keys). Kernel backend (`/model kernel`) is
darwin-arm64 only, loads GGUF weights via llama.cpp/Metal.

## Gotchas

- **Segfault in `tools.getRelevantDefinitions` / near-null fault address**:
  dangling module-global pointer. `AgentLoop.init` returns by value, so
  pointers into its frame die. Globals in `src/agent/tools.zig` must be
  re-bound from `self` via `AgentLoop.bindTools()` (called in main.zig after
  init and at the top of `processInput`). If you add a new `tools.setX()`
  global, bind it there — never from a local inside `init`.
- Build is silent on success; `zig build 2>&1 | tail` shows errors only.
- The REPL prompt contains ANSI color codes — match on content, not `> `.
