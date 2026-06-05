# Prebuilt Dependency Kernels: forAgent, forMCP, forAI (+ forMetal/forCUDA)

**Date:** 2026-06-04
**Status:** Approved (design), pending implementation plan
**Applies to:** wintermolt (this repo). A parallel handoff doc for Wintermute
lives at `wintermute/docs/developer/PREBUILT-DEPS-HANDOFF.md`.

## Goal

Wintermolt links forAgent, forMCP, forAI, and forNLP as **prebuilt binary kernels**
(`.a`/`.so`/`.dll`/`.metallib` — no source). The binaries are copied out of
the sibling dep repos into wintermolt's local `prebuilt/` tree, **committed to
this public repo** (binary redistribution is permitted; source stays closed in
the private siblings), and linked from the local copies only. forAI gives
wintermolt in-process model inference — **no external model loader**.

## Decisions (made 2026-06-04)

1. **Vendoring:** commit the binaries, like `prebuilt/macos/lib/libllama.a`
   already is. Extend the gitignore exception beyond `*.a` to `.so`, `.dll`,
   `.dylib`, `.metallib` under `prebuilt/`.
2. **Sync, not auto-copy:** an explicit `scripts/sync-prebuilts.sh` copies
   sibling deliveries → local tree. The build never mutates the repo and never
   reads sibling paths. (forAI is mid-rebuild; auto-copy would silently pick
   up half-baked deliveries.)
3. **GPU target switch:** macOS → **forMetal** (`libformetal.a` +
   `fm_kernels.metallib`); Linux + Windows (and thor/Jetson) → **forCUDA**.
   forMetal is the macOS-only exception. forCUDA's Windows delivery (PTX port)
   and `linX86` delivery land later — sync warns-and-skips absent deliveries
   so they start working the day they appear.
4. **`/model forai` becomes in-process:** the linked forAI engine replaces the
   old "forai" OpenAI-compatible HTTP backend. The HTTP path remains reachable
   via the generic `openai` backend with a custom URL.
5. **Unsloth support = run unsloth-trained models.** No new training code.
   Unsloth GGUF exports run today via `/model kernel` (llama.cpp) and via
   `/model forai` once forAI's loader lands. Adapter-only exports are merged
   to GGUF at export time (`save_pretrained_gguf`). Document this in
   `docs/BACKENDS.md`.

## Source-of-truth layouts (as of 2026-06-04)

Sibling deliveries (org convention, 2026-05-30):

```
../forAgent/prebuilt/lib/macos/libforagent.a
../forMCP/prebuilt/lib/macos/libformcp.a
../forAI/prebuilt/lib/macos/libforai.a            # MID-REBUILD: delivery currently only has libforai.dylib; the vendored libforai.a in prebuilt/macos/lib/ is the PRE-rebuild archive (harmless — no symbols referenced while is_supported=false). Re-run sync-prebuilts.sh when the forAI session delivers the new .a.
../forNLP/prebuilt/lib/macos/libfornlp.a          # NEW dep: BPE/SentencePiece tokenizer, top-p/top-k sampling, chat templates (Gemma4/Llama3/ChatML) — companion to the forai engine
../forMetal/prebuilt/lib/macos/{libformetal.a, fm_kernels.metallib, *.air}
../forMetal/prebuilt/lib/linX86/libformetal.a     # present but UNUSED — forMetal is macOS-only by decision
../forCUDA/prebuilt/linux-arm64/lib/libforcuda.a  # older layout; winX86/linX86 deliveries pending
```

Wintermolt local tree (committed):

```
prebuilt/<short>/lib/      # short = macos | thor | linX86 | winX86
prebuilt/macos/include_kernel/   # existing llama.cpp headers (unchanged)
```

## Components

### 1. `scripts/sync-prebuilts.sh`

For each (dep, target) pair, copy delivery → `prebuilt/<short>/lib/`.
Matrix: forAgent/forLearn/forMCP/forAI/forNLP → all four targets; forMetal → macos only
(including `fm_kernels.metallib`); forCUDA → thor, linX86, winX86.
Missing source delivery ⇒ `[skip] <dep>/<target> not delivered yet` (warning,
not error). Print a summary table. Idempotent.

### 2. `build.zig`

- Replace `addSiblingArchive()` sibling probing with local-only resolution:
  `prebuilt/<short>/lib/<archive>` (probe `libX.a` then `X.lib`/`X.dll` per
  platform naming).
- GPU switch:
  ```zig
  if (t.os.tag == .macos) { link formetal; install fm_kernels.metallib next to binary }
  else { link forcuda; }  // linux, windows
  ```
- Missing archive ⇒ build proceeds with a clear `std.debug.print` notice and
  the feature stubs out (same pattern as libllama.a today). No hard failure.
- `fm_kernels.metallib` is a **runtime resource**: `b.installBinFile` it so it
  ships beside the binary; forMetal client resolves it relative to the
  executable path.

### 3. `src/api/forai.zig` — `ForAIClient`

Same shape as `src/api/kernel.zig` (`KernelClient`): `init(alloc, model_path,
alias)`, `sendMessage(system, messages, tool_defs, text_cb)`, `deinit()`.
Backed by forAI's C-ABI. **forAI is being rebuilt** — wintermolt codes against
this thin adapter; the extern fn list is pinned when forAI's rebuilt exports
land. Until then `is_supported = false` ⇒ `/model forai` reports
"forAI engine not delivered yet" instead of crashing.

- `Backend` union: replace `openai`-flavored `forai` wiring with
  `.forai: ForAIClient`.
- `switchBackend("forai", model)`: resolve model path from
  `~/.wintermolt/models/` (same resolver as kernel backend), dupe model name
  (cd1b578 lesson), deinit prior heavy backend before replacing (kernel
  pattern), re-binding rules of bindTools() unchanged.

### 4. Docs

- `docs/BACKENDS.md`: forai = in-process engine (forMetal on macOS, forCUDA on
  Linux/Windows); unsloth-model how-to (GGUF export → models dir → /model).
- `README.md`: note "no external model loader needed" capability.

## Error handling

- Sync: absent sibling repo or delivery → warn + skip, exit 0.
- Build: absent archive → notice + stub (never break public clones).
- Runtime: `/model forai` with missing engine/model → stderr message, backend
  unchanged (mirrors kernel backend's resolveModelPath error path).
- `deinit`/`switchBackend`: drain forAI engine before replacement (GB-scale
  weights), same as kernel backend.

## Testing

- `scripts/sync-prebuilts.sh` run twice ⇒ identical tree (idempotence).
- `zig build` on macos with all archives present ⇒ links formetal, installs
  metallib; with archives removed ⇒ builds with stubs.
- Cross-compile `-Dtarget=x86_64-linux-gnu` ⇒ selects forcuda path (link skip
  acceptable until linX86 delivery exists).
- REPL: `/model forai` before engine delivery ⇒ clean message, no crash.
- Smoke: existing `running-wintermolt` skill flow stays green.

## Out of scope

- forAI's own rebuild (separate repo, in flight).
- Native fine-tuning via forai_lora (future feature; explicitly deferred).
- forMetal on non-macOS despite its linX86 delivery (decision: macOS-only).
- Real Unsloth orchestration (Python).
