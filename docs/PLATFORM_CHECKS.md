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
3. In `wintermolt --plain`, ask it to run `sh -c 'sh -c "sleep 100"'`. Press
   Ctrl+C while it runs, then `pgrep -fl "sleep 100"`: nothing should be
   left. Expected to fail at 862e5c1, which kills only the shell and its
   direct children (`pkill -P`).
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
