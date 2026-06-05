# TOKENIZATION — forNLP integration

Copyright The Fantastic Planet - By David Clabaugh

forNLP is the forKernels tokenization repo: BPE encoder (llama2.c greedy
score-merge), SentencePiece `.model` parser, UTF-8 utilities, chat templates
(Gemma4 / Llama3 / ChatML), plus Fortran sampling kernels (top-p/top-k,
repetition penalty, softcap). This doc maps it onto wintermolt's
committed-prebuilt dependency model.

`sync-prebuilts.sh` already lists forNLP in `ALL_DEPS` (every target).
forNLP delivers canonically at `../forNLP/prebuilt/lib/<short>/libfornlp.a`
(macos delivered 2026-06-04; thor/linX86/winX86 as their branches build).

## Two integration lanes — pick per use case

### Lane A — vendored archive + C ABI (fits the wintermolt model)

`sync-prebuilts.sh` → `prebuilt/<short>/lib/libfornlp.a` → `linkDep(exe_mod, b, short, "fornlp")`.

Symbols (all `callconv(.c)`, declared in `forNLP/src/zig/exports.zig`):

```zig
extern fn fnlp_tokenizer_load(path: [*]const u8, path_len: i32, vocab_size: i32) i32;
extern fn fnlp_tokenizer_encode(text: [*]const u8, text_len: i32, tokens_out: [*]i32, max_tokens: i32, add_bos: i32, add_eos: i32) i32;
extern fn fnlp_tokenizer_decode(token_id: i32, buf: [*]u8, buf_len: i32) i32;
extern fn fnlp_tokenizer_free() void;
// sampling (needs gfortran runtime on the final link, like the other kernels):
extern fn fnlp_sample_top_p(logits: [*]f32, n: i32, p: f32, temp: f32, seed: *i32) i32;
extern fn fnlp_sample_top_k(logits: [*]f32, n: i32, k: i32, temp: f32, seed: *i32) i32;
extern fn fnlp_apply_repetition_penalty(logits: [*]f32, n: i32, token_ids: [*]const i32, num_tokens: i32, penalty: f32) i32;
extern fn fnlp_apply_softcap(logits: [*]f32, n: i32, cap: f32) i32;
```

**Hard limitation:** the C ABI holds ONE global tokenizer instance.
`fnlp_tokenizer_load` frees the previous tokenizer. Fine for a
single-active-model flow (load on model switch); wrong for concurrent
multi-model tokenization. The loader is llama2.c `tokenizer.bin` format
only, with fixed BOS=1/EOS=2.

### Lane B — Zig modules (instance-based, multi-model)

If concurrent per-model tokenizers are needed (Gemma + Qwen + Nemo at once),
the C ABI does not cut it — the instance-based `fornlp.Tokenizer` struct does.
That requires forNLP *source* as Zig modules, which conflicts with the
no-dep-source rule, so it needs an explicit decision. Two sub-options:

- `build.zig.zon` path dep on `../forNLP` (works since forNLP ships
  `build.zig.zon` + a `b.addModule("fornlp", ...)` facade, 2026-06-04) —
  build-time only, no source committed here; requires sibling checkout,
  same as sync-prebuilts already does.
- Stay Lane A and serialize model switches through the single instance.

**Reference implementation** for Lane B: `Wintermute/src/nlp/tokenizers.zig`
(multi-model `Registry` with per-family BOS/EOS/template conventions,
`specialId()` for multimodal token splicing) and
`Wintermute/docs/features/tokenization.md` (model matrix, formats, gotchas).

## Model files (runtime assets — not shipped by forNLP)

| Model | File | Notes |
|---|---|---|
| Gemma | SentencePiece `tokenizer.model` | Lane B only (SP parser is Zig API, not in the C ABI) |
| Qwen 2/3 | llama2.c-format export | `metalQwen3/scripts/export.py` emits `qwen3-4B.bin.tokenizer` (vocab 151936) |
| Llama 2 | stock `tokenizer.bin` (vocab 32000) | works as-is in both lanes |
| Nemo | llama2.c-format export of the Tekken vocab | no [INST] chat template in forNLP yet |

HF `tokenizer.json` is NOT supported by forNLP. For bit-exact HF/tiktoken
parity, forAI has a full engine (`forAI/src/zig/tokenizer.zig`,
`tiktoken.zig`) — wintermolt already vendors libforai.a; check which side of
that engine is exported before depending on it. Greedy score-merge
approximates rank-based BPE: do not rely on exact token *counts* for context
budgeting without verifying against the model's reference tokenizer.

## Sampling note

The `fnlp_sample_*` kernels operate on a logits buffer in place — on macos
that pairs with forMetal's unified memory (`fc_rt_get_ptr` gives the real
host pointer, so sampling CPU-side after a device forward pass needs no
copy). FC error convention matches: 0 == OK, negative == error.
