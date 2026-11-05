# Platform checks

The Windows machine runs the suite and the live checks for every change.
These parts of wintermolt take their own code path on macOS and Linux, so a
change to them needs a run there too. The session on that machine runs the
checks and records a row under Results.

## Stop and approval

Code: `src/agent/control.zig`, `fsio.killTree`, `installCtrlC` in `src/main.zig`.

1. `zig build`, then `zig build test --summary all`: every step green.
   `src/control_tests.zig` has a `sleep 30` that a stop must kill in under 10 s.
2. `wintermolt -e "write a long essay"` against Ollama; press Ctrl+C partway.
   Expect `[Stopped]` and exit 1 within about a second, and no curl error
   line. Then `wintermolt --plain`, idle at its prompt, Ctrl+C: it quits.
3. In `wintermolt --plain`, ask it to run
   `sh -c 'sh -c "sleep 100; true"; true'; true` (the `; true`s keep each
   shell from exec'ing the next, so the tree is really nested). Stop it, then
   `pgrep -fl "sleep 100"`: nothing should be left. Check both a stop sent to
   the wintermolt pid alone (as Esc, the web page and chat `/stop` do) and a
   terminal Ctrl+C. Failed at 862e5c1, which killed only the shell's direct
   children (`pkill -P`).
4. `WINTERMOLT_BASH_APPROVAL=ask wintermolt --plain`; ask it to run `echo hi`.
   The question appears; `n` refuses the command, `y` runs it.

## Voice and camera (macOS)

5. `/listen` twice, then `kill -9` wintermolt: `pgrep whisper-server` finds
   nothing. The imagesnap and screencapture paths work.

## Results

Add a row, `git fetch`, and push to main. Write what failed in Notes, with
the output; the fix is agreed here before either machine changes that code,
so two machines never patch it at once.

| Commit | Machine | 1 | 2 | 3 | 4 | 5 | Notes |
|---|---|---|---|---|---|---|---|
| 862e5c1 | Windows 11 x64 | pass | pass | pass (job object) | pass | n/a | Linux and x86_64-macos type-check only |
| 9bafffe | macOS 27.2 arm64 | pass | pass | fail | pass | partial | 1: 321/321, test-tui 44/44, test-env 29/29, test-cli green. 2: `[Stopped]`, exit 1 in 0.01 s, no curl line; idle Ctrl+C exits 130. 3: the command as written does not nest here: `/bin/sh` (bash 3.2) execs the last command at each level, so `sleep` is a direct child and passes trivially. Made deep with `sh -c 'sh -c "sleep 100; true"; true'; true`: SIGINT to the wintermolt pid only (what Esc, the web stop and chat `/stop` amount to) leaves `sh -c sleep 100; true` and `sleep 100` running; SIGINT to the process group (a real terminal's Ctrl+C) leaves nothing. 5: whisper-server not installed, `/listen` not run; `imagesnap -l` lists both cameras (no photo taken); `/screenshot` ok. 9bafffe is code-identical to 862e5c1 |
| 9bafffe | Linux aarch64 (Jetson AGX Thor, Ubuntu 24.04) | pass | pass | fail | pass | n/a | 1: 321/321, test-tui 44/44, test-env 29/29, test-cli green. 2: `[Stopped]`, exit 1, no curl line; idle Ctrl+C exits 130. 3: 5-deep tree (`sh -c 'sh -c "sleep 100; true"; true'; true` in a script): SIGINT to the pid leaves `sleep` running; SIGINT to the process group leaves nothing. The orphan is in wintermolt's own group, so `killpg` on that group would kill wintermolt too: a fix needs the child in a new group first (0.16 `std.process.spawn` `.pgid = 0`), then `kill(-pid, SIGKILL)`. That takes the command out of the terminal's foreground group, so one that prompts on the tty (`sudo`, `ssh`, git credentials) stops on SIGTTIN, where Windows' job object keeps the console. Walking the tree (`pgrep -P` recursively, SIGSTOP top-down, then SIGKILL) keeps the tty, but misses a descendant that has already reparented. Run by the Thor session, recorded from macOS |

**Item 3 fix, agreed 2026-11-05** (David's call, relayed by the macOS
session): on POSIX, a cancelable command starts in a new process group
(`.pgid = 0`) and a stop kills the group (`kill(-pid, SIGKILL)`); Windows is
unchanged. Cost accepted: the command leaves the terminal's foreground group,
so a real Ctrl+C reaches it through wintermolt's stop, and a command that
prompts on the tty (`sudo`, `ssh`) stops on SIGTTIN until stopped. The macOS
session writes it.
