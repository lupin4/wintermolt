# Changelog

All notable changes to Wintermolt are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Full-screen chat is the default interactive mode in a terminal.** When
  stdin and stdout are both a terminal (GetConsoleMode on Windows, isatty
  elsewhere), `wintermolt` opens a TUI built on zortui. It has a scrolling
  transcript (keys and mouse wheel) that colors user, assistant and tool lines
  differently, a line editor, and a status bar with backend, model and a busy
  indicator. Slash commands run exactly as in the REPL, and their output goes
  to the transcript. Requests run on a worker thread, so the screen stays
  responsive while a model streams. Esc, Ctrl+C and `/quit` exit and restore
  the terminal, including after a panic.
- **`--plain` and `WINTERMOLT_PLAIN=1`** keep the plain line-by-line REPL in a
  terminal. Piped or redirected stdio still gets the plain REPL automatically,
  so `printf '/stats\n/quit\n' | wintermolt` behaves as before. `-e`, `--web`,
  `--gateway`, `--chat` and `--mcp-server` are unchanged.
- **zortui vendored** at `vendor/zortui` (lupin4/zortui 9261fe1, MIT, derived
  from hqtui). It is a plain copy imported as a module, with its LICENSE and
  NOTICE kept.
- `zig build test-tui`: headless TUI tests through zortui's testing module,
  driven by a fake agent. They are also part of `zig build test`.

### Changed

- **The TUI reads time through forTime.** zortui timed frames, animation and,
  on Windows, its input-wait deadlines with its own monotonic clock. The
  vendored copy is now lupin4/zortui 9261fe1, which adds an optional
  `App.Options.clock` hook, and wintermolt passes `fsio.monoNs` (forTime's
  `ftim_mono_ns`), so no clock on the TUI path bypasses forTime. Plain REPL,
  `-e` and the other modes are unchanged.

- **stdio output sink.** `stdio.stdout()` and `stdio.stderr()` writes go to an
  installed sink when there is one. Only the TUI installs one; with no sink
  they write to the fd exactly as before. The Ollama `done_reason=length`
  warning now goes through `stdio.stderr()` instead of `std.debug.print`, so
  it cannot draw over the TUI.
- **Slash-command dispatch** moved out of the REPL loop into
  `dispatchCommand`, unchanged, so the REPL and the TUI share one command
  chain.
- **Build requires Zig 0.16.** 0.15.2 already failed (`std.process.Init` does
  not exist there); the README now says so.

- **Relicensed from Apache 2.0 to MIT.** `LICENSE` now carries the MIT text;
  the README badge, comparison table and footer, the startup banner and the
  build.zig header were updated to match.
- **Clocks come from forTime.** `fsio.zig`'s timestamp and monotonic clocks
  call forTime's C ABI (`ftim_now_unix_ns`, `ftim_mono_ns`) from its prebuilt
  archive instead of libc `clock_gettime`, which does not exist on Windows.
  `scripts/sync-prebuilts.sh` now also syncs forTime, forNet and the forIO
  core pack, and takes `SYNC_TARGETS` so each machine copies only its own
  target.
- **Default local model is `qwen3:8b`** (was `qwen3:0.6b`, which narrated
  instead of acting on tool results). `WINTERMOLT_MODEL` /
  `WINTERMOLT_OLLAMA_MODEL` still override.

### Fixed

- **Windows (Zig 0.16).** Builds and runs from a plain PowerShell or cmd
  window with no setup: `HOME` falls back to `USERPROFILE`; the console is
  switched to UTF-8 with ANSI escapes at startup and restored on exit; the
  bash tool runs `cmd.exe /c` and its description names Windows commands;
  console I/O, environment lookup and random bytes go through a small
  `src/win32.zig` because 0.16 removed those kernel32 paths from std.
- **Child processes started with an empty environment** (all targets, Zig
  0.16). `std.Io.Threaded` defaults its `environ` to empty and spawn builds the
  child's environment from it, so every child fsio spawned had no PATH, HOME or
  API keys. On Windows the bash tool could run `ver` (a cmd builtin) but
  answered "'systeminfo' is not recognized" to real commands; on POSIX
  `/bin/sh -l` hid it for the shell tool but not for MCP servers. fsio now
  passes the real process environment (`.global` on Windows, libc `environ`
  elsewhere), and `currentEnvMap` works on Windows.
- **Ollama tool calls.** Follow-up requests carrying a tool call were
  rejected with HTTP 400 because `arguments` was sent as a JSON string;
  Ollama's `/api/chat` takes an object. The 400 handler no longer claims the
  model lacks tool support.
- **HTTPS on Windows.** Every HTTPS request failed with "Problem with the SSL
  CA cert (path? access rights?)": web_search, http_request, `/download`, cloud
  backends and OAuth. The MSYS2 libcurl wintermolt links looks for its CA
  bundle at a path that exists only inside MSYS2. Every curl handle now sets
  `CURLSSLOPT_NATIVE_CA` (`src/curl_tls.zig`), so the Windows certificate
  store is used. Certificate verification stays on, and other platforms are
  unchanged. Plain-HTTP Ollama was never affected.
- **Tool status told the truth only on a crash.** A tool call that failed
  still printed a green `[ok]`, because most tools report failure as a result
  string (`Search error: ...`, `HTTP error: ...`) rather than an error. Those
  now print a red `[error]`, in the REPL and in the full-screen transcript,
  decided from each tool's own failure prefixes (`src/agent/tool_status.zig`).
  What the model receives is unchanged.

## [0.5.0] — 2026-06-04

### Added

- **Kernel backend — local Metal inference** (`/model kernel <alias>`,
  darwin-arm64). In-process GGUF inference through a prebuilt llama.cpp
  static archive with embedded Metal shaders
  (`prebuilt/macos/lib/libllama.a`, built via
  `scripts/build-llama-cpp-macos.sh`). No external model server required.
  Heavy weights are drained on `/model` switch and before exit.
- `running-wintermolt` project skill (`.claude/skills/`) and agent-harness
  SOP docs.
- Design spec for the upcoming prebuilt-deps feature (forAgent / forMCP /
  forAI / forNLP archives with a forMetal↔forCUDA per-OS target switch):
  `docs/superpowers/specs/2026-06-04-prebuilt-deps-design.md`.

### Fixed

- **Segfault on first prompt.** `AgentLoop.init` stored pointers to its own
  stack locals (skill registry, scheduler, storage, RAG) in tools-module
  globals, then returned by value — all four globals dangled into a dead
  stack frame. New `bindTools()` re-binds them from the agent's final
  address (after init and on every `processInput`); also fixes the REPL
  `/schedule` command, which read the same dangling scheduler pointer.
- **`/model` corrupted the model name.** `switchBackend` kept the caller's
  slice of the reused REPL `line_buf`; the next keystroke overwrote it into
  garbage (provider HTTP 400). The model name is now duped on entry.
  (Ported to Wintermute as d70159f.)
- **Ollama context window too small.** Default `num_ctx` raised 4096 → 8192
  — the all-tools prompt alone is ~3.4k tokens, which silently truncated
  small-model replies. `WINTERMOLT_OLLAMA_CTX` still overrides.
  `done_reason=length` is now surfaced. (Ported from Wintermute 21ccc69.)

## [0.4.1] — 2026-05-17

### Changed

- **Relicensed from MIT to Apache 2.0.** Full Apache License 2.0 text in
  `LICENSE`. README badge, comparison table, and footer updated to match
  (the prior footer incorrectly read "AGPL-3.0 License" — now corrected
  along with the relicense).
- LICENSE copyright line now reads "Copyright 2026 The Fantastic Planet
  — By David Clabaugh" to match the project-wide convention used in
  source headers and README footer.
- README footer tagline trimmed.

### Added

- **`docs/` folder** with 5 focused reference pages (~85 lines each,
  423 lines total):
  - `docs/BACKENDS.md` — 7 backends, default models, env vars, `--keys` flow.
  - `docs/TOOLS.md` — 20 built-in tools (9 core + 11 extended) with
    keyword triggers and safety notes.
  - `docs/SKILLS.md` — skill manifest format, built-in catalog, custom
    skill install path.
  - `docs/MCP.md` — MCP client + server configuration, Claude Desktop
    and Zed wiring examples.
  - `docs/DEPLOYMENT.md` — run modes (`--chat`, `--web`, `--menubar`,
    `--gateway`, `--mcp-server`), 18 chat platforms, scheduler,
    Tailscale, persistent storage paths.
- README gains a "Documentation" section linking each page.

## [0.4.0] — 2026-05-16

### Added

- **First Windows release.** `wintermolt-windows-x86_64.exe` shipped under
  `prebuilt/`. Built against the MSYS2 UCRT64 toolchain with HTTP/3-capable
  libcurl, OpenSSL, sqlite3, and the full Win32 socket / crypto stack.
- **POSIX compat shim** (`src/compat.zig`) — cross-platform replacements for
  `std.posix.getenv` (Windows env block is WTF-16, so a UTF-8 cache is kept),
  `std.posix.poll`-style stdin readiness checks (`WaitForSingleObject` on
  Windows), and `drainStdinNonBlocking` (`FlushConsoleInputBuffer` on
  Windows). Existing POSIX behavior is unchanged on macOS / Linux.
- **Windows toolchain support in `build.zig`** — explicit MSYS2 UCRT64
  library paths and the full HTTP/3 + Win32 system-lib dependency chain
  (`nghttp3`, `ngtcp2`, `ssl`, `crypto`, `zstd`, `brotli`, `idn2`, `psl`,
  `ssh2`, `unistring`, `iconv`, `ws2_32`, `wldap32`, `crypt32`, `bcrypt`,
  `secur32`, …) are linked when targeting `x86_64-windows-gnu`.
- **Canonical delivery alignment** — `getTargetName` for Windows now returns
  `winX86` to match the 2026-05-16 forKernels delivery-dir convention.
  `addSiblingArchive` tries both Unix-style (`libfoo.a`) and Zig-native
  Windows-style (`foo.lib`) names across `winX86`, `linX86`, `thor`,
  `macos`, and legacy `windows-x86_64` / `linux-x86_64` directories.

### Changed

- 26 source files migrated from `std.posix.getenv` to `compat.getenv` so the
  binary compiles for `x86_64-windows-gnu` without source forks.
- `setup.zig`'s `drainPastedInput` delegates to `compat.drainStdinNonBlocking`
  rather than calling POSIX-only `fcntl`/`read` directly.
- `VERSION` bumped to `0.4.0`.

### Notes

- The Linux x86_64 prebuilt binary is not yet shipped in this release — it
  must be built on a Linux x86_64 host (or cross-compiled from one with
  matching forAgent/forLearn archives). Source builds via
  `zig build -Dtarget=x86_64-linux-gnu` work today.
- macOS Apple Silicon and Linux ARM64 binaries are unchanged from v0.3.0.

## [0.3.0] — 2026-04-06

### Added

- **Ollama-first release.** No API key required by default.
- Claude / OpenAI / DeepSeek / Qwen / Gemini support is now optional.
- `/keys` command for interactive credential setup.
- 79 model-agnostic skills.

## [0.2.0] — 2026-03-26

- Iteration on agent loop, scheduler, and tool dispatch.

## [0.1.0] — 2026-02-22

- First public release.
