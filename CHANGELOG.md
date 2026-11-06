# Changelog

All notable changes to Wintermolt are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **`--chat` admits nobody until you allow them**, with OpenClaw's rules and
  defaults. Before, every message from anyone on any connected platform went
  to an agent that can run `bash`. Now:
  - an unknown sender's direct message gets a one-hour pairing code, and
    nothing they write reaches the agent until
    `wintermolt --pairing approve <platform> <code>`;
  - a group must be listed in `WINTERMOLT_CHAT_GROUPS`, the sender allowed
    there, and the bot mentioned.

  `WINTERMOLT_CHAT_DM_POLICY`, `_ALLOW_FROM`, `_GROUP_POLICY`, `_GROUPS`,
  `_GROUP_ALLOW_FROM` and `_REQUIRE_MENTION` set the rules (see
  docs/DEPLOYMENT.md). A value that is not one of the documented ones stops
  `--chat` at startup instead of falling back to a default.
- **A group no longer shares the owner's conversation.** Every `--chat`
  message, from any DM or group on any platform, went to one conversation,
  so a group member could ask about what was said in a direct message. Each
  group now has its own; direct messages still share one, as in OpenClaw,
  and `WINTERMOLT_CHAT_DM_SCOPE=per-peer` gives each direct sender their
  own.
- **Webhook adapters authenticate what they receive.** LINE checks
  `X-Line-Signature` against the channel secret. Feishu checks the event's
  verification token, which needs the new `FEISHU_VERIFICATION_TOKEN`.
  Teams and Google Chat checked nothing, so anyone who could reach their port
  could post as any user; they no longer start until they verify their
  platform's JWT. They never sent their replies either.
- **iMessage reads the Messages database as JSON.** It split rows on `|`, and
  the text column came before the sender's, so a message containing `|`
  could name any sender. Replies go to `osascript` without a shell.
- **Speech never goes through a shell.** Piper and Edge TTS put the text
  being spoken, which is model output, into a `/bin/sh -c` command line
  unescaped, so a reply containing `$(…)` ran it. The text is now one
  argument (or an environment variable, or a file). OpenAI and ElevenLabs
  requests JSON-escape it, and a `[[speed:…]]` directive is only ever a
  number. A Deepgram or ElevenLabs voice name, which goes into the URL, is
  letters, digits, `-` and `_` only. `DEEPGRAM_API_KEY` is redacted like the
  other keys.

### Added

- **Stop a reply.** Esc in the full-screen view and on the web page (whose
  Send button becomes Stop), Ctrl+C in the plain REPL and `-e`, `/stop` in
  the full-screen view and in chat. The model request is dropped, a running
  shell command is killed with everything it started, and tools not yet run
  are skipped. Before, the only way out was to quit. On macOS and Linux the
  command runs in a process group of its own, which is how a stop reaches
  all of it; so a command that prompts on the terminal (`sudo`, `ssh`, git
  asking for credentials) waits, without prompting, until it is stopped.
- **Approve shell commands before they run:** `WINTERMOLT_BASH_APPROVAL=ask`.
  Each command from `bash`, a `schedule` job being added, or a skill waits
  for a yes: `y` / `a` / `n` in the terminal, buttons on the web page,
  OpenClaw's `/approve <id> allow-once|allow-always|deny` in chat from
  someone in `WINTERMOLT_CHAT_APPROVERS`. "Always" covers that exact
  command until wintermolt exits. No answer in 30 minutes, or nobody to ask
  (`--gateway`, `--mcp-server`, `-e` with no input), is a no. Off by
  default; any value but `off` asks, so a typo does not run everything.
- **`--chat` keeps reading while it answers.** Messages that arrive during a
  reply wait in a queue (20 at most) and are answered in order; before, one
  slow reply held every platform. `/stop`, `/new`, `/reset`, `/status`,
  `/help` and `/approve` are answered by wintermolt rather than sent to the
  model.
- **`--web` works: a chat page served by the binary itself.** It spawned a
  TypeScript sidecar that is not in the repository, so it never started.
  Now wintermolt serves the page and its WebSocket directly (no Node), on
  `127.0.0.1:3000`, and opens it in the browser. Replies stream in with
  their tool calls; panels show past conversations, skills, the workspace
  files (editable) and which keys are set, never their values. The link it
  prints carries a token, and a page or WebSocket without it, or from
  another site, is refused. `WINTERMOLT_WEB_HOST` and `WINTERMOLT_WEB_TOKEN`
  are new (see docs/DEPLOYMENT.md).
- **The web page runs the terminal's commands** (`/stats`, `/session`,
  `/schedule`, `/export` and the rest) and shows what they print. `/keys`
  stays in the terminal, since `/keys list` shows part of each key.
- **Carry on an earlier conversation.** History in the web page opens a
  conversation to read or to continue: what was said goes back to the model
  and new messages are saved under the same conversation. Tool results were
  never saved, so they do not come back.
- **`--gateway` works: an OpenAI-compatible API served by the binary
  itself.** It spawned a TypeScript sidecar that is not in the repository,
  and the Zig side sent only the first `content` string of a request, in a
  new conversation each time, never streamed. Now `POST /v1/chat/completions`
  takes the whole conversation and answers whole or streamed (server-sent
  events), and `GET /v1/models` names the backend. Every request needs the
  API key it prints (`WINTERMOLT_GATEWAY_KEY` sets a fixed one); it listens
  on `127.0.0.1` (`WINTERMOLT_GATEWAY_HOST`). The sidecar's device pairing
  endpoints went with it; they never ran.
- **Workspace files, as in OpenClaw.** `AGENTS.md`, `SOUL.md`, `USER.md`,
  `IDENTITY.md` and `MEMORY.md` in `~/.wintermolt/workspace`
  (`WINTERMOLT_WORKSPACE_DIR`) go into the system prompt every turn, with
  OpenClaw's limits: 20,000 characters a file, 60,000 in all, 4,000 for
  `USER.md`. `MEMORY.md` is left out of `--chat` groups and per-peer DM
  sessions; a `spawn_agent` child gets `AGENTS.md` only.
- **`SKILL.md` skills** (OpenClaw, ClawHub, Anthropic Agent Skills) from
  `./skills`, `./.agents/skills`, the workspace's `skills` and
  `.agents/skills`, `~/.agents/skills` and `~/.wintermolt/skills`. The
  prompt lists their names and descriptions in `<available_skills>`; the
  `skills` tool's `use` returns one's instructions, and `/skill [name]
  [input]` lists them or uses one. OpenClaw's `metadata.openclaw` gates
  (`os`, `always`, `requires.bins`, `anyBins`, `env`) and
  `disable-model-invocation` apply.
- **A reply with nothing in it is asked for again.** A model that ended its
  turn with no text and no tool call (qwen3 can spend the turn thinking)
  printed nothing and `-e` exited 0. It is asked once more, and a second
  empty reply is an error, exit status 1.
- **Voice, end to end: `/listen [seconds | audio file]`.** ffmpeg records
  the microphone (the first DirectShow audio device on Windows, `:0` on
  macOS, PulseAudio's `default` elsewhere; `WINTERMOLT_MIC` names another),
  the recording is transcribed and sent as the prompt, and the reply is
  spoken. Transcription is local whisper.cpp (`whisper-cli`) when a
  `ggml-*.bin` model is in `~/.wintermolt/models` (or
  `WINTERMOLT_WHISPER_MODEL` names one), else Deepgram nova-3 with
  `DEEPGRAM_API_KEY`; `WINTERMOLT_STT_PROVIDER` picks.
- **`/listen` keeps whisper.cpp loaded.** The first `/listen` starts
  `whisper-server` on 127.0.0.1:8178 while you speak; every later one
  reuses it (0.2 s to transcribe instead of 2–10 s for `whisper-cli`, which
  loads the model each time), and it ends with wintermolt, even when
  wintermolt crashes or is killed: on Windows a kill-on-close job holds it,
  on macOS and Linux a `sh` watcher kills it when wintermolt's pipe closes.
  Without `whisper-server`, or if it fails, `whisper-cli` transcribes as
  before.
- **`/listen` says what it is waiting on.** "Opening the microphone...",
  then "speak now" only once ffmpeg is capturing (opening a DirectShow
  device took 3–6 s here, and words said before it were lost), and
  "Loading the speech model" on the first `/listen`. The full-screen view's
  spinner shows the same (`recording`, `loading speech`). The microphone a
  session finds is kept, skipping the device listing after the first time.
- **`/listen` loads the Ollama model while you speak, and keeps it.** A
  reply waited for the model to load (50 s cold here) before reading the
  prompt; now `/listen` asks Ollama to load it as recording starts, with the
  context size the reply will use, so it is loaded once. From the first
  `/listen` on, the model stays loaded 30 minutes after each reply instead
  of Ollama's 5, so pauses between questions don't unload it.
  `WINTERMOLT_OLLAMA_KEEP_ALIVE`, when set, still decides.
- **Deepgram Aura-2 text-to-speech** (`deepgram`, voice `thalia` by default;
  any `aura-2-<name>-en`), and **the computer's own voice** (`system`:
  Windows' built-in speech, macOS `say`, `espeak-ng`), which needs no key.
  With `WINTERMOLT_TTS_PROVIDER` unset, the first provider whose key is set
  speaks (Deepgram, OpenAI, ElevenLabs), else the system voice. Before, an
  unset provider meant OpenAI, and without its key, no speech at all.
  `wintermolt --keys` (step 5, Voice) and `/keys deepgram` take your own
  `DEEPGRAM_API_KEY`; a key Deepgram refuses, `/listen` says so.
- **`/image <file> [prompt]` attaches an image** (png, jpeg, gif, webp) to
  the next turn, in the plain prompt and the full-screen view. Drag a file in
  for its path: the quoted form Windows Terminal pastes and the `\ ` form
  macOS Terminal pastes both work.
- **`/screenshot` works on Windows**, through PowerShell. It captures the
  primary screen at its real resolution.
- **The agent can look for itself.** `camera_capture` gains `screenshot`
  (the primary screen) and `view` (any png, jpeg, gif or webp file), so an
  agent working on its own can check the screen or open an image it found.
- **The camera works on Windows**, through ffmpeg's DirectShow input. With
  no device named it uses the first camera that opens. A black frame fails
  the capture with `CameraFrameIsBlackIsItCovered`, rather than moving on to
  a virtual camera (NVIDIA Broadcast's shows its own picture).
  `list_devices` lists them.
- **`WINTERMOLT_MAX_ITERATIONS` sets how many model requests one turn may
  make** before it stops with "Hit max iterations" (default 25; 0, or a
  value that is not a positive whole number, keeps 25). A long multi-step
  task stopped at 25 with no way to raise it. By Philipp Baumann (#8).

### Fixed

- **A model Ollama does not have says so.** On a fresh install the default,
  `qwen3:8b`, is often not pulled yet, and the error was
  `[ollama HTTP 404] Request failed`. It now prints Ollama's own message:
  `[ollama HTTP 404] model 'qwen3:8b' not found`.
- **When Ollama rejects a request that declares tools, its reason is shown.**
  wintermolt retries without the tools, as before, but it used to tell you to
  run curl to find out why. Now Ollama's message prints first, e.g.
  `[ollama HTTP 400] Value looks like object, but can't find closing '}' symbol`.
- **`--keys` no longer erases settings you added to `.env` by hand.** It
  rewrote `~/.wintermolt/.env` with only the keys it asks about, so a line
  such as `WINTERMOLT_STT_PROVIDER=deepgram`, the `/theme` choice, or a
  comment was lost on every re-run. Now only the wizard's own keys change.
  Each is replaced where it was, or removed when you clear it, and every
  other line is kept exactly.
- **`/keys` changes only the key you set or clear.** It rebuilt the whole
  file, dropping comments, reordering lines and quoting every value. It
  also said "Saved" before writing, and said nothing when the write failed.
- **Keys already in `.env` stay intact when `--keys` or `/keys` saves.**
  The values read from the file pointed at memory that was reused
  straight away. `--keys` could offer a kept key as blanks and save that,
  and `/keys` could write the other keys back damaged. Files over 8 KB are
  also read in full now.
- **`WINTERMOLT_OLLAMA_CTX` is documented as 8192**, the default the code
  has used since the small-model fix; the README, docs/BACKENDS.md and
  config.zig still said 4096.
- **Saved conversations have titles.** Nothing ever set one, so every
  conversation was untitled. A conversation is now named by the first line
  of its first message, at most 80 bytes.
- **Spoken audio plays on Windows and Linux.** `/tts` played only on macOS,
  through `afplay`; the tool used `aplay`, which cannot play the mp3 the
  cloud voices return. Both now use `afplay` on macOS and ffmpeg's `ffplay`
  elsewhere. Audio goes to `%TEMP%` on Windows, not `/tmp`.
- **A voice service's error is not saved as audio.** A rejected key or a
  too-long text came back as JSON with a 4xx status, written to an `.mp3`
  and reported as success; now it is `ApiKeyRejected`, `HttpError` or
  `TextTooLong`. Edge TTS was asked for OpenAI's voice `alloy`, which it
  does not have; each provider now has its own default voice.
- **`/look` and `/screenshot` send the image.** They captured it, discarded
  it, and sent the model only the words "[Screenshot attached]".
- **OpenAI-compatible backends receive images.** Their requests replaced
  every image with the text `[image]`; it now goes as an `image_url` part.
- **An image a tool returns reaches OpenAI-compatible and Ollama models.**
  Only Claude saw what `camera_capture` captured; the others got the text
  "Image captured". The image now follows the tool's reply as a user message,
  since neither API takes an image inside a tool message.
- **Captures land in %TEMP% on Windows**, which has no `/tmp`.
- **`WINTERMOLT_VISION_MODEL` routes images.** It was documented as the model
  for `/look` and image tools but read by nothing, so a text-only main model
  (the default qwen3:8b) got images it could not see. A request carrying an
  image now goes to it, on `WINTERMOLT_VISION_BACKEND` (`ollama` or
  `openai`); if it fails, the main model answers.
- **A turn with an attached image does not offer `camera_capture`.** Offered
  it, gemma4 called `view` on a made-up path (`image.png`) instead of looking
  at the image it had; without it, it describes the image.

- **The browser tool no longer runs page data as shell.** Without websocat it
  spliced the CDP message (URLs, text to type, JS) into a `node -e "..."`
  script, where every `"` in the JSON toggled the shell's quoting: a `;` in a
  URL the model was steered to ran as a command. The message and URL are now
  arguments to a fixed script.
- **Claude's in-stream errors fail the request.** An `event: error`
  (`overloaded_error` and the like) inside a `200` was printed and the partial
  answer returned as a success, so no fallback ran. It is now
  `[claude] stream error: <message>` and the request fails, as the OpenAI
  path already did.
- **`~/.wintermolt/mcp.json` reads `"mcpServers"`**, the key docs/MCP.md and
  Claude's own configs use. Only `"servers"` was read, so the documented
  config loaded nothing; both work now.
- **A provider's HTTP error says why.** A non-2xx answer printed only
  `[openai HTTP 404] Request failed`; it now prints the body's error message,
  which for a local engine names the models it does serve. Found by Philipp
  Baumann (#4).
- **A stream written `data:{...}` without the space is read.** The SSE spec
  makes the space optional; both parsers required it, so such a stream came
  back as an empty answer (#7).
- **`--chat` processes messages.** It had not since 0.4, for three reasons:
  - the loop stopped at the sidecar's first status event, which every
    adapter sends when it connects;
  - a reader made per line dropped whatever arrived in the same read as the
    line before it;
  - the reply was never captured, so the agent's answer was empty and
    nothing was sent.
- **Replies go to the conversation.** A reply was sent to the sender's ID, so
  a group's answer went to a member's DM, or nowhere on Discord, Mattermost,
  Matrix and Rocket.Chat.
- **The gateway and `spawn_agent` return the model's answer.** Both read
  the same never-filled capture buffer, and returned `(no response)` and
  `(Subagent produced no output)`.
- **Each adapter reports a direct message from a group message, and whether
  the bot was mentioned.** Along the way:
  - a WhatsApp group message names its author rather than the group;
  - a Signal group message is answered in the group;
  - IRC no longer hands each line to the agent twice, once as a DM, or
    answers NOTICEs;
  - Zulip no longer answers its own replies.
- **A sidecar line is parsed as JSON.** The key search it replaced unescaped
  every field into one shared buffer, so a Discord message with an
  attachment had its text replaced by the attachment list. Lines may now be
  up to 4 MiB (was 8 KiB, past which `--chat` stopped).

- **The Linux arm64 prebuilt drops to glibc 2.34+** (was 2.36+), so it starts
  on Ubuntu 22.04 / JetPack 6, Debian 12 and RHEL 9 — the same floor the
  x86_64 prebuilt already had (#2). The 2.36 import was `arc4random_buf`,
  which `std.Io` binds only when the TARGET glibc is 2.36 or newer
  (`std/c.zig`); a native build on a Thor running Ubuntu 24.04 (glibc 2.39)
  passed that check, so the symbol was an artifact of the build machine, not
  of any code. The arm64 release is now built in an Ubuntu 22.04 container,
  as the x86_64 one already was, and `std.Io` falls through to `getrandom`.
  Verified: the dep archives were NOT the cause — rebuilding
  forMCP/forNet/forNLP against a 2.34 target produced a byte-identical
  binary, because the members that reference `arc4random_buf` are never
  linked in.
- **The macOS prebuilt links the system libcurl** (`/usr/lib/libcurl.4.dylib`),
  so it starts on a Mac without Homebrew's curl. `build.zig` skips pkg-config
  for curl on macOS: with Homebrew's curl installed, pkg-config had pointed the
  link at `/opt/homebrew/opt/curl`, and the 0.5.0 binary carried that path. It
  still requires macOS 27.2+, the version of the machine that built it. A
  floor of 26 waits on six dep archives that were compiled for 26.4–27.0 (#5).

### Changed

- **The Linux arm64 prebuilt ships stripped**: 11.1 MB → 1.6 MB (#2). Crash
  backtraces lose file and line numbers, as `-Dstrip=true` documents.
- **The macOS prebuilt ships stripped**: 6.5 MB → 6.1 MB, with the same
  backtrace trade-off.
- **The Linux x86_64 prebuilt ships stripped**: 11.0 MB → 1.8 MB, with the
  same trade-off. It is now built by `.github/workflows/linX86-release.yml`, in
  the Ubuntu 22.04 container that the Release Builds section prescribes.

## [0.6.0] — 2026-10-21

### Added

- **Any OpenAI-compatible server.** `WINTERMOLT_OPENAI_URL` is the full Chat
  Completions URL the `openai` backend calls (default
  `https://api.openai.com/v1/chat/completions`), so LiteLLM, vLLM, a
  llama.cpp server, OpenRouter or a hosted gateway can stand in, with its
  token in `OPENAI_API_KEY` (#1).
- **`WINTERMOLT_NO_FALLBACK=1`**: a failed request fails, instead of being
  answered by Ollama or OpenAI. `-e` then exits 1, so a harness that asked
  for one provider sees that provider fail.
- **`WINTERMOLT_NO_TOOLS=1`**: no tool definitions are sent, so a model
  without function calling can run. Before, any request declaring tools was
  refused by such a model's server.
- **`WINTERMOLT_STALL_TIMEOUT`**: seconds a model request may receive
  nothing before it is dropped (default 180, `0` = never). See Changed.
- **A Straylight startup banner.** WINTERMOLT in slant lettering in front of
  an ASCII Villa Straylight and its planet, colored from the terminal's own
  16 colors in the plain REPL and from the active theme in the full-screen
  view. The largest of three sizes that fits is shown; piped output and
  `NO_COLOR` get the lettering, uncolored. The generator and its source image
  are in `docs/ANSI_art/wintermolt`.
- **A `terminal` theme, now the default.** The full-screen view uses the
  terminal's own palette and background, so it matches whatever scheme the
  terminal has. zortui's nine themes are still a `/theme` away.
- **`-Dstrip=true`** builds a binary without debug info.
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
- **Themes for the full-screen view and the canvas.** Pick one of zortui's
  nine (`dark`, `dracula`, `nord`, `tokyo-night`, `gruvbox`, `matrix`,
  `monochrome`, `high-contrast`, `light`) with `--theme <name>`,
  `WINTERMOLT_THEME`, or `/theme <name>`, which switches the running view at
  once and saves `WINTERMOLT_THEME=<name>` in `~/.wintermolt/.env`. Precedence
  is flag, environment, saved, then `terminal`; an unknown name lists the valid
  ones and the next source is used. `/theme` alone lists them. Canvas surfaces
  follow the same theme (`canvas/tui.zig` gains `renderSurfaceThemed`).
- **Linux x86_64 binary.** `prebuilt/wintermolt-linux-x86_64` ships for the
  first time: dynamic libcurl and sqlite3, glibc 2.34+, x86-64-v3 CPU floor.

### Changed

- **A model request is dropped only when it stalls.** Each client capped the
  whole request (90 s for the OpenAI-compatible ones, 120 s for Claude, 180 s
  for Ollama), so a long answer that was still streaming, or a local engine
  still warming up, ended in "Timeout was reached". Now nothing caps the
  total; a request is dropped after `WINTERMOLT_STALL_TIMEOUT` seconds with
  nothing received. Connect timeouts are unchanged.
- **The `forai` backend is in-process only.** Its old HTTP mode is the
  `openai` backend with `WINTERMOLT_OPENAI_URL`; `WINTERMOLT_FORAI_URL` and
  `WINTERMOLT_FORAI_MODEL` are no longer read.
- **Zig 0.16 everywhere it is named**: the README badge, and the linX86 CI
  pin, which was still 0.15.2. The first Zig 0.17 blocker (the `**`
  array-repeat operator) is gone; 0.17 does not build yet.
- **Linux binaries state their glibc floor**, and the README has a musl
  (Alpine) build route (#2).
- **Skills take effect.** The `skills` tool gains `operation='use'`, which
  hands a skill's `role_prompt` to the model as instructions for the current
  task, on whatever backend is running; calling a prompt skill by name does
  the same. Before, the 79 shipped skills were listed by name and
  description and nothing more: their role prompts were read and never
  used. The nine generic personas (`code_reviewer`, `debugger`,
  `python_engineer`, `refactorer`, `test_writer`, `typescript_engineer`,
  `project_planner`, `research_assistant`, `technical_writer`) are removed;
  the 70 that carry forKernels / Zortran house rules stay. A manifest's
  `backend` and `model` are still not used.
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

- **`-e` exited 0 when no backend answered**, so a script could not tell a
  failure from an answer. It now exits 1.
- **The full-screen view drew palette colors as near-black.** At truecolor
  depth zortui sent a palette index as 24-bit RGB; it now sends `38;5;n`
  (vendored zortui 8f6df19).
- **Runtime skills never loaded.** `AgentLoop` created the skill registry
  and never filled it, so no skill from `./skills`, `~/.wintermolt/skills` or
  a plugin reached the model in any mode, bash and MCP skills included.
  Startup now loads them (`[skills] Loaded N runtime skill(s)`), and
  `--mcp-server` loads them too.
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
- **`~/.wintermolt/.env` did nothing on Windows.** Its keys were read, and
  "[config] Loaded N vars" printed, but the `setenv` wintermolt exports for
  Windows (mingw's CRT has none) was a no-op, so no key reached the
  environment: `WINTERMOLT_CONFIG_VERSION=1` never hid the setup notice, API
  keys kept only in `.env` were missing, and the bash tool's children saw
  `%KEY%` unexpanded. It now calls `SetEnvironmentVariableW`. A variable
  already in the environment still wins over `.env` (overwrite=0), and every
  child spawned afterwards inherits the values, because fsio spawns with the
  live process environment. `zig build test-env` checks both ends (getenv and a
  child shell). fsio's two `/bin/sh` spawn tests now skip on Windows, where
  one could not compile, so `zig build test` runs there too.
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
- **Text selection in the full-screen view.** It captured the mouse, so the
  terminal could not select or copy text; on Windows it also turned off Quick
  Edit, the console's own selection. The view now leaves the mouse to the
  terminal by default: no mouse-tracking sequence, and Quick Edit stays on
  (vendored zortui c47945c). Scrolling stays on the keyboard (PgUp/PgDn, ↑ ↓,
  and now Ctrl+↑ Ctrl+↓), and Windows Terminal still scrolls with the wheel.
  `WINTERMOLT_TUI_MOUSE=1` gives the view the mouse back.
- **Crash, or missing `.env` keys, starting an MCP server on Linux and
  macOS.** fsio's long-lived Io kept a view of libc's `environ` array taken on
  its first use. `setenv`, which `config.loadDotEnv` calls for every `.env`
  key, moves that array when it adds a name and frees it on the next move. A
  child started through `spawnPiped` (MCP servers, sidecars) then got the old
  environment without the `.env` keys, or the spawn's PATH lookup read the
  freed array and the process died with SIGSEGV. The Io now owns a copy of the
  environment, and `spawnPiped` hands each child the live one. Windows was not
  affected. `zig build test-env` covers it: it sets eight new names after the
  Io exists, then checks that a `spawnPiped` child sees the last one.

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
