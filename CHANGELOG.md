# Changelog

All notable changes to Wintermolt are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
