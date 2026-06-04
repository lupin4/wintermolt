# Prebuilt Dependency Kernels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wintermolt links forAgent, forLearn, forMCP, forAI, forNLP as committed prebuilt binaries from its local `prebuilt/<short>/` tree, with a forMetal↔forCUDA GPU switch per OS, and `/model forai` becomes the (stubbed-until-delivered) in-process engine.

**Architecture:** A sync script copies sibling deliveries (`../<dep>/prebuilt/lib/<short>/`) into `prebuilt/<short>/lib/` (committed). `build.zig` links ONLY from the local tree — sibling probing is deleted. `src/api/forai.zig` mirrors `kernel.zig`'s adapter shape with `is_supported = false` until forAI's rebuild delivers its C-ABI.

**Tech Stack:** Zig 0.15.2, bash, static archives. Spec: `docs/superpowers/specs/2026-06-04-prebuilt-deps-design.md`.

**Conventions that MUST hold:** target short names are exactly `macos`, `thor`, `linX86`, `winX86` — never hyphenated triples. Verify behavior with the `running-wintermolt` project skill flow (`zig build` then `./zig-out/bin/wintermolt -e "Reply with exactly: WINTERMOLT OK"`).

**Note:** forLearn was already a linked dep (predates the spec); it joins the all-targets sync matrix.

---

### Task 1: `scripts/sync-prebuilts.sh`

**Files:**
- Create: `scripts/sync-prebuilts.sh`
- Modify: `docs/superpowers/specs/2026-06-04-prebuilt-deps-design.md` (one line: add forLearn to matrix)

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# sync-prebuilts.sh — copy prebuilt kernels from sibling dep repos into ./prebuilt/
#
# Run after a sibling repo re-delivers. The copies are COMMITTED (binary
# redistribution is permitted; dep source stays closed). The build never
# reads sibling paths — only what this script has placed locally.
#
# Targets (org short names, no hyphenated triples): macos | thor | linX86 | winX86
# Matrix:
#   forAgent forLearn forMCP forAI forNLP  → every target
#   forMetal                               → macos ONLY (decision 2026-06-04)
#   forCUDA                                → thor linX86 winX86
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIBLINGS="$(cd "$ROOT/.." && pwd)"
TARGETS=(macos thor linX86 winX86)
ALL_DEPS=(forAgent forLearn forMCP forAI forNLP)

copied=0
skipped=0

copy_one() { # $1=src $2=dst
    local src="$1" dst="$2"
    if [[ -f "$src" ]]; then
        mkdir -p "$(dirname "$dst")"
        cp -f "$src" "$dst"
        echo "[sync] ${dst#"$ROOT"/} ← ${src#"$SIBLINGS"/}"
        copied=$((copied + 1))
    else
        echo "[skip] ${src#"$SIBLINGS"/} not delivered yet"
        skipped=$((skipped + 1))
    fi
}

for dep in "${ALL_DEPS[@]}"; do
    lib="lib$(echo "$dep" | tr '[:upper:]' '[:lower:]').a"
    for t in "${TARGETS[@]}"; do
        copy_one "$SIBLINGS/$dep/prebuilt/lib/$t/$lib" "$ROOT/prebuilt/$t/lib/$lib"
    done
done

# forMetal: macOS only. Archive + runtime .metallib (installed beside the binary).
copy_one "$SIBLINGS/forMetal/prebuilt/lib/macos/libformetal.a" "$ROOT/prebuilt/macos/lib/libformetal.a"
copy_one "$SIBLINGS/forMetal/prebuilt/lib/macos/fm_kernels.metallib" "$ROOT/prebuilt/macos/lib/fm_kernels.metallib"

# forCUDA: GPU kernels for everything that isn't macOS. thor falls back to
# forCUDA's legacy linux-arm64 delivery layout until it adopts short names.
for t in thor linX86 winX86; do
    src="$SIBLINGS/forCUDA/prebuilt/lib/$t/libforcuda.a"
    if [[ "$t" == "thor" && ! -f "$src" ]]; then
        src="$SIBLINGS/forCUDA/prebuilt/linux-arm64/lib/libforcuda.a"
    fi
    copy_one "$src" "$ROOT/prebuilt/$t/lib/libforcuda.a"
done

echo "----"
echo "[sync] done: $copied copied, $skipped skipped (skips are fine — deliveries land per-target over time)"
```

- [ ] **Step 2: Make it executable and run it (this is the test)**

Run: `chmod +x scripts/sync-prebuilts.sh && ./scripts/sync-prebuilts.sh`

Expected (with today's deliveries): copies `libforagent.a`, `libforlearn.a`, `libformcp.a`, `libforai.a`, `libfornlp.a`, `libformetal.a`, `fm_kernels.metallib` into `prebuilt/macos/lib/`; copies `libforcuda.a` into `prebuilt/thor/lib/` (via legacy fallback); `[skip]` lines for thor/linX86/winX86 deps not yet delivered. Exit code 0.

- [ ] **Step 3: Verify idempotence**

Run: `./scripts/sync-prebuilts.sh > /tmp/sync1.txt && ./scripts/sync-prebuilts.sh > /tmp/sync2.txt && diff /tmp/sync1.txt /tmp/sync2.txt && find prebuilt -name '*.a' -o -name '*.metallib' | sort`

Expected: no diff; tree lists the copied files exactly once each.

- [ ] **Step 4: Add forLearn to the spec matrix**

In `docs/superpowers/specs/2026-06-04-prebuilt-deps-design.md`, change the sync-matrix line to:

```
Matrix: forAgent/forLearn/forMCP/forAI/forNLP → all four targets; forMetal → macos only
```

- [ ] **Step 5: Commit**

```bash
git add scripts/sync-prebuilts.sh docs/superpowers/specs/2026-06-04-prebuilt-deps-design.md
git commit -m "feat(deps): sync-prebuilts script — copy sibling kernel deliveries into prebuilt/<short>/"
```

---

### Task 2: gitignore exceptions + commit the synced binaries

**Files:**
- Modify: `.gitignore` (the `prebuilt` exception block at the end)

- [ ] **Step 1: Extend the exception block**

Replace the existing block:

```gitignore
# prebuilt kernel archives ARE checked in (exception to *.a above)
!prebuilt/**/*.a
```

with:

```gitignore
# prebuilt kernel binaries ARE checked in (exceptions to the rules above).
# Binary redistribution is permitted; dep source stays closed in the
# private sibling repos. Synced by scripts/sync-prebuilts.sh.
!prebuilt/**/*.a
!prebuilt/**/*.so
!prebuilt/**/*.dll
!prebuilt/**/*.dylib
!prebuilt/**/*.metallib
```

- [ ] **Step 2: Verify nothing under prebuilt/ is ignored, then commit**

Run: `git add prebuilt .gitignore && git status --short | grep prebuilt`

Expected: `A` lines for every synced archive and the metallib; zero files reported by `git check-ignore prebuilt/macos/lib/fm_kernels.metallib` (command exits 1 = not ignored).

```bash
git commit -m "feat(deps): vendor prebuilt kernels (forAgent/forLearn/forMCP/forAI/forNLP, forMetal, forCUDA-thor)"
```

---

### Task 3: build.zig — local-only resolution + forMetal↔forCUDA switch

**Files:**
- Modify: `build.zig` (replace `addSiblingArchive` call sites ~line 48-56, add GPU switch after the win_deps block ~line 104, delete `addSiblingArchive` and `getTargetName` functions at the bottom)

- [ ] **Step 1: Replace the sibling-archive call sites**

Replace (top of `build()`, after `exe_mod` creation):

```zig
    // --- forAgent + forLearn: built from sibling repos.
    // The 2026-05-16 decree made winX86/linX86/thor/macos the canonical
    // delivery dirs, but older builds still publish at the Zig triple-style
    // {arch-os-abi}. Try canonical first, then fall back. Names are
    // probed in both Unix (libfoo.a) and Zig-native Windows (foo.lib) form.
    const target_name = getTargetName(target.result);
    addSiblingArchive(exe_mod, b, "forAgent", "libforagent.a", target_name);
    addSiblingArchive(exe_mod, b, "forLearn", "libforlearn.a", target_name);
```

with:

```zig
    // --- Dep kernels: linked from the COMMITTED local prebuilt tree only.
    // scripts/sync-prebuilts.sh copies sibling deliveries into
    // prebuilt/<short>/lib/ (short = macos | thor | linX86 | winX86).
    // The build never reads sibling paths. Unreferenced archive members
    // are not pulled in, so linking deps ahead of their wiring is free.
    const short_target = getShortTargetName(target.result);
    for ([_][]const u8{ "foragent", "forlearn", "formcp", "forai", "fornlp" }) |dep| {
        addPrebuiltArchive(exe_mod, b, dep, short_target);
    }
```

- [ ] **Step 2: Add the GPU target switch**

Insert immediately after the Windows `win_deps` block (after its closing `}`), before the kernel-backend block:

```zig
    // --- GPU kernels: forMetal on macOS, forCUDA everywhere else ---
    // forMetal is the macOS-only exception (decision 2026-06-04); its
    // fm_kernels.metallib is a runtime resource shipped beside the binary.
    if (t.os.tag == .macos) {
        addPrebuiltArchive(exe_mod, b, "formetal", short_target);
        if (b.build_root.handle.access("prebuilt/macos/lib/fm_kernels.metallib", .{})) |_| {
            b.installBinFile("prebuilt/macos/lib/fm_kernels.metallib", "fm_kernels.metallib");
        } else |_| {}
    } else {
        addPrebuiltArchive(exe_mod, b, "forcuda", short_target);
    }
```

- [ ] **Step 3: Add the two helpers; delete `addSiblingArchive` and `getTargetName`**

At the bottom of build.zig, replace both old functions with:

```zig
fn getShortTargetName(t: std.Target) []const u8 {
    return switch (t.os.tag) {
        .macos => "macos",
        .linux => switch (t.cpu.arch) {
            .aarch64 => "thor",
            else => "linX86",
        },
        .windows => "winX86",
        else => "unknown",
    };
}

/// Link a committed prebuilt archive from prebuilt/<short>/lib/.
/// Probes Unix (libfoo.a) then Zig-native Windows (foo.lib) naming.
/// Missing archive ⇒ notice + the feature stubs out — public clones and
/// not-yet-delivered targets must never hard-fail.
fn addPrebuiltArchive(mod: *std.Build.Module, b: *std.Build, name: []const u8, short: []const u8) void {
    const candidates = [_][]const u8{
        b.fmt("prebuilt/{s}/lib/lib{s}.a", .{ short, name }),
        b.fmt("prebuilt/{s}/lib/{s}.lib", .{ short, name }),
    };
    for (candidates) |p| {
        if (b.build_root.handle.access(p, .{})) |_| {
            mod.addObjectFile(b.path(p));
            return;
        } else |_| {}
    }
    std.debug.print("[build] {s} not found — run scripts/sync-prebuilts.sh (feature stubs out)\n", .{candidates[0]});
}
```

- [ ] **Step 4: Build natively (the test) — archive warnings must be GONE**

Run: `zig build 2>&1 | head; ./zig-out/bin/wintermolt -e "Reply with exactly: WINTERMOLT OK" 2>/dev/null; ls zig-out/bin/`

Expected: NO "archive not found" warnings for macos deps (all delivered); `WINTERMOLT OK`; `zig-out/bin/` contains `wintermolt` AND `fm_kernels.metallib`.

- [ ] **Step 5: Cross-compile checks (forCUDA path + winX86 naming)**

Run: `zig build -Dtarget=x86_64-linux-gnu 2>&1 | grep forcuda; zig build -Dtarget=aarch64-linux-gnu 2>&1 | grep -c "not found"`

Expected: linX86 prints the `prebuilt/linX86/lib/libforcuda.a not found` notice (delivery pending); thor build finds `prebuilt/thor/lib/libforcuda.a` (synced via legacy fallback) so `libforcuda` is NOT among its not-found notices. Link failures about libcurl/sqlite cross-sysroots are pre-existing and out of scope — only the archive-resolution lines matter here.

- [ ] **Step 6: Commit**

```bash
git add build.zig
git commit -m "feat(build): link dep kernels from local prebuilt/<short>/ only; forMetal<->forCUDA target switch"
```

---

### Task 4: `src/api/forai.zig` — ForAIClient adapter stub

**Files:**
- Create: `src/api/forai.zig`

- [ ] **Step 1: Write the adapter**

Mirrors `src/api/kernel.zig`'s shape (`KernelClient`) so the loop wiring is uniform. forAI is mid-rebuild: `is_supported = false` until its new C-ABI exports are pinned — then this file gains the `@cImport`/extern block and real generate loop (forNLP tokenizer + forMetal/forCUDA dispatch).

```zig
// Copyright The Fantastic Planet - By David Clabaugh
//
// forai.zig — in-process forAI inference engine (adapter stub)
//
// /model forai runs models in-process: forAI (model graph) + forNLP
// (tokenizer / sampling / chat templates) on forMetal (macOS) or forCUDA
// (Linux/Windows). No external model loader.
//
// forAI is being rebuilt (2026-06-04). The extern fn list is pinned when
// its new exports land; until then is_supported = false and /model forai
// reports the engine as not yet delivered instead of crashing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const sse = @import("sse.zig");
const kernel_mod = @import("kernel.zig");

/// Becomes a real comptime capability check (per-target archive presence)
/// once forAI's rebuilt C-ABI is pinned.
pub const is_supported = false;

pub const Error = error{ForAIEngineUnavailable};

pub const ForAIClient = struct {
    alloc: Allocator,
    model_path: []const u8,
    model_alias: []const u8,

    pub fn init(alloc: Allocator, model_path: []const u8, model_alias: []const u8) ForAIClient {
        return .{ .alloc = alloc, .model_path = model_path, .model_alias = model_alias };
    }

    pub fn deinit(self: *ForAIClient) void {
        // Weights handle freed here once the engine lands (GB-scale —
        // switchBackend/deinit drain this before replacement, like kernel).
        _ = self;
    }

    pub fn sendMessage(
        self: *ForAIClient,
        system_prompt: []const u8,
        messages: []const protocol.Message,
        tool_defs: []const protocol.ToolDefinition,
        text_cb: ?sse.TextCallback,
    ) !protocol.Response {
        _ = self;
        _ = system_prompt;
        _ = messages;
        _ = tool_defs;
        _ = text_cb;
        return Error.ForAIEngineUnavailable;
    }
};

// Model files share the kernel backend's resolver (~/.wintermolt/models,
// WINTERMOLT_KERNEL_MODEL_DIR) — unsloth GGUF exports dropped there work
// for both /model kernel and /model forai.
pub const resolveModelPath = kernel_mod.resolveModelPath;
pub const defaultModelDir = kernel_mod.defaultModelDir;
```

- [ ] **Step 2: Verify it parses**

Run: `zig ast-check src/api/forai.zig`

Expected: silent success.

- [ ] **Step 3: Commit**

```bash
git add src/api/forai.zig
git commit -m "feat(forai): ForAIClient adapter stub — in-process engine slot, pinned when forAI rebuild lands"
```

---

### Task 5: Backend wiring — `/model forai` becomes in-process

**Files:**
- Modify: `src/agent/loop.zig` (import block ~line 22, `Backend` union ~line 34, `deinit` ~line 168, `sendToBackend` switches ~lines 398+410, `switchBackend` forai branch ~line 534 + drain switch + unknown-backend help ~line 574, `getBackendInfo` ~line 573)
- Modify: `src/web/bridge.zig:~495` (backend-name switch)
- Modify: `src/main.zig:521` and `src/main.zig:1144` (help text)
- Modify: `docs/BACKENDS.md:16` (forai row)

- [ ] **Step 1: loop.zig — import + union**

After `const kernel_mod = @import("../api/kernel.zig");` add:

```zig
const forai_mod = @import("../api/forai.zig");
```

In `pub const Backend = union(enum)` add:

```zig
    forai: forai_mod.ForAIClient,
```

- [ ] **Step 2: loop.zig — drain forai in BOTH heavy-backend switches**

In `deinit()` and at the top of `switchBackend()`, the existing drain switch gains a case. Both become:

```zig
        switch (self.backend) {
            .kernel => |*k| k.deinit(),
            .forai => |*f| f.deinit(),
            else => {},
        }
```

- [ ] **Step 3: loop.zig — sendToBackend + fallback name**

In the primary-send switch add:

```zig
            .forai => |*f| f.sendMessage(system_prompt, messages, tool_defs, text_cb),
```

In the `backend_name` switch used for the fallback message add:

```zig
                .forai => "forAI",
```

- [ ] **Step 4: loop.zig — replace the forai branch of switchBackend**

Replace the whole `else if (std.mem.eql(u8, backend_name, "forai")) { ... }` HTTP-client branch with:

```zig
        } else if (std.mem.eql(u8, backend_name, "forai")) {
            // In-process forAI engine (forMetal on macOS, forCUDA on
            // Linux/Windows) — no external model loader. The old
            // OpenAI-compatible HTTP mode lives on via /model openai with
            // a custom URL.
            if (!forai_mod.is_supported) {
                stderr.writeAll("[backend] forAI engine not delivered yet (forAI rebuild in flight) — use /model kernel for local inference meanwhile\n") catch {};
                return;
            }
            const default_alias = compat.getenv("WINTERMOLT_FORAI_DEFAULT") orelse "qwen3:0.6b";
            const alias = model_name orelse default_alias;
            const model_dir = forai_mod.defaultModelDir(self.alloc) catch {
                stderr.writeAll("[backend] could not resolve WINTERMOLT_KERNEL_MODEL_DIR or $HOME\n") catch {};
                return;
            };
            const path = forai_mod.resolveModelPath(self.alloc, alias, model_dir) catch |err| {
                stderr.print("[backend] forai: could not resolve {s} ({s})\n", .{ alias, @errorName(err) }) catch {};
                return;
            };
            self.backend = .{ .forai = forai_mod.ForAIClient.init(self.alloc, path, alias) };
            stderr.print("[backend] Switched to forAI in-process ({s})\n", .{alias}) catch {};
```

(`model_name` here is already the duped copy from the cd1b578 fix — do not re-dupe.)

- [ ] **Step 5: loop.zig — getBackendInfo**

Add to its switch:

```zig
            .forai => |f| .{ .name = "forai", .model = f.model_alias },
```

- [ ] **Step 6: web bridge + help text + docs**

`src/web/bridge.zig` backend-name switch: add `.forai => "forai",`.

`src/main.zig:521`: `try w.writeAll("Backends: ollama (default), forai (in-process), kernel, claude, openai, deepseek, qwen, gemini\n");`

`src/main.zig:1144`: `\\  /model [name]  — Switch AI backend (ollama, forai [in-process], kernel, claude, openai, deepseek, qwen, gemini)`

`docs/BACKENDS.md` forai row becomes:

```markdown
| `forai`  | (GGUF in `~/.wintermolt/models`) | None — in-process | In-process inference engine: forAI + forNLP on forMetal (macOS) / forCUDA (Linux, Windows). No external model loader. Engine ships when the forAI rebuild lands; until then `/model forai` reports not-yet-delivered. Previous HTTP mode: use `openai` backend with a custom URL. |
```

- [ ] **Step 7: Build + behavioral test**

Run: `zig build && printf '/model forai\n/stats\n/quit\n' | ./zig-out/bin/wintermolt 2>&1 | grep -E "forAI|Backend"`

Expected: `[backend] forAI engine not delivered yet (forAI rebuild in flight) — use /model kernel for local inference meanwhile`, and `/stats` still shows `Backend: ollama` (switch refused cleanly, no crash).

- [ ] **Step 8: Full smoke (running-wintermolt skill flow)**

Run: `./zig-out/bin/wintermolt -e "Reply with exactly: WINTERMOLT OK" 2>/dev/null`

Expected: `WINTERMOLT OK`.

- [ ] **Step 9: Commit**

```bash
git add src/agent/loop.zig src/web/bridge.zig src/main.zig docs/BACKENDS.md
git commit -m "feat(forai): /model forai is the in-process engine slot (stub until forAI delivers)"
```

---

### Task 6: Docs — unsloth how-to + README

**Files:**
- Modify: `docs/BACKENDS.md` (append section)
- Modify: `README.md` (one capability line wherever local inference is described)

- [ ] **Step 1: Append to docs/BACKENDS.md**

```markdown
## Running Unsloth-trained models

Wintermolt runs models fine-tuned with [Unsloth](https://unsloth.ai) — no
Python needed at inference time:

1. Export from your training run as GGUF:
   `model.save_pretrained_gguf("out", tokenizer, quantization_method="q4_k_m")`
   (adapter-only safetensors exports must be merged at export time — use the
   GGUF path, which merges LoRA into the base weights).
2. Drop the `.gguf` into `~/.wintermolt/models/`.
3. `/model kernel <file-stem>` runs it today (llama.cpp + Metal, macOS).
   `/model forai <file-stem>` runs it in-process on forMetal/forCUDA once the
   forAI engine delivery lands.
```

- [ ] **Step 2: README capability line**

In README's features/local-inference area add:

```markdown
- **No external model loader** — local GGUF inference in-process (`/model kernel` today on Apple Silicon; `/model forai` on forMetal/forCUDA across macOS/Linux/Windows as engine deliveries land). Unsloth-trained GGUF exports run as-is.
```

- [ ] **Step 3: Commit + push the lot**

```bash
git add docs/BACKENDS.md README.md
git commit -m "docs: forai in-process backend + unsloth-model how-to"
git push
```

---

### Task 7: Final verification

- [ ] **Step 1: Clean-tree full pass**

Run: `git status --short; zig build && ./zig-out/bin/wintermolt -e "Reply with exactly: WINTERMOLT OK" 2>/dev/null && printf '/model forai\n/quit\n' | ./zig-out/bin/wintermolt 2>&1 | grep forAI`

Expected: clean tree (or only intended files), `WINTERMOLT OK`, the not-delivered message. No "archive not found" warnings on macos.

- [ ] **Step 2: Sync idempotence after everything**

Run: `./scripts/sync-prebuilts.sh && git status --short prebuilt/`

Expected: no modified files (deliveries unchanged since Task 1).

---

## When forAI's rebuild delivers (follow-up, OUT of this plan)

Pin the extern block in `src/api/forai.zig`, flip `is_supported` to the
per-target archive check, implement the generate loop against forNLP's
tokenizer/sampler and the forMetal/forCUDA dispatch, re-run
`scripts/sync-prebuilts.sh`, and commit the refreshed archives. The
`/model forai` UX, build wiring, and resolver are already in place.
