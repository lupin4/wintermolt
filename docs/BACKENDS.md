# Backends

Wintermolt routes prompts through a single `Backend` enum. Eight backends
are supported. The default is Ollama (local, no API key).

## Backend matrix

| Backend  | Default model              | Auth                    | Notes                                          |
| :------- | :------------------------- | :---------------------- | :--------------------------------------------- |
| `ollama` | `qwen3:8b`                 | None — local            | Requires `ollama serve` on `WINTERMOLT_OLLAMA_URL` (default `http://localhost:11434`). |
| `claude` | `claude-sonnet-4-20250514` | `ANTHROPIC_API_KEY`     | Anthropic Messages API.                        |
| `openai` | `gpt-4o-mini`              | `OPENAI_API_KEY`        | Chat Completions API at `WINTERMOLT_OPENAI_URL` (default `https://api.openai.com/v1/chat/completions`) — any OpenAI-compatible server works. |
| `deepseek` | `deepseek-chat`          | `DEEPSEEK_API_KEY`      | OpenAI-compatible endpoint.                    |
| `qwen`   | `qwen-plus`                | `QWEN_API_KEY`          | Alibaba DashScope OpenAI-compatible endpoint.  |
| `gemini` | `gemini-2.0-flash`         | `GOOGLE_GEMINI_API_KEY` | Google Gemini REST API.                        |
| `kernel` | `qwen3:0.6b` (GGUF in `~/.wintermolt/models`) | None — in-process | llama.cpp on Metal, in-process. macOS Apple Silicon only; other builds report "darwin-arm64 only". `WINTERMOLT_KERNEL_DEFAULT` sets the default alias, `WINTERMOLT_KERNEL_MODEL_DIR` the model directory. |
| `forai`  | (GGUF in `~/.wintermolt/models`) | None — in-process | In-process inference engine: forAI + forNLP on forMetal (macOS) / forCUDA (Linux, Windows). No external model loader. Engine ships when the forAI rebuild lands; until then `/model forai` reports not-yet-delivered. Previous HTTP mode: use the `openai` backend with `WINTERMOLT_OPENAI_URL`. |

## Switching at runtime

Inside the REPL:

```
> /model claude
> /model claude claude-opus-4-20250514
> /model ollama qwen3:14b
```

Or set the default for the session via env:

```bash
WINTERMOLT_MODEL=qwen3:14b ./wintermolt
```

## Selecting the startup backend

`/model` only exists in the REPL, so a non-interactive run (`-e`, `--web`,
`--gateway`, `--chat`) has no command with which to leave the Ollama default.
`WINTERMOLT_BACKEND` picks the backend the run starts on:

```bash
# one-shot prompt through the OpenAI backend, no REPL to type /model in
WINTERMOLT_BACKEND=openai OPENAI_API_KEY=sk-... ./wintermolt -e "summarise README.md"

# gateway server in front of Claude
WINTERMOLT_BACKEND=claude ANTHROPIC_API_KEY=sk-ant-... ./wintermolt --gateway
```

The model is still named by that backend's own variable (`WINTERMOLT_MODEL`,
`WINTERMOLT_OPENAI_MODEL`, `WINTERMOLT_QWEN_MODEL`, ...). An unknown name, or a
backend whose key is missing, is reported on stderr and leaves Ollama in place;
it never fails the run. `WINTERMOLT_BACKEND` also wins over the
`models.chat.prefer` routing in `wintermolt.json`, because it is set explicitly.

## Per-backend env vars

```bash
# Startup backend for every mode, not only the REPL
WINTERMOLT_BACKEND=ollama                      # ollama (default), claude, openai, ...

# Ollama (default)
WINTERMOLT_OLLAMA_URL=http://localhost:11434   # base URL
WINTERMOLT_OLLAMA_CTX=4096                     # context window cap
WINTERMOLT_OLLAMA_KEEP_ALIVE=5m                # unload timer (0 = unload immediately)
WINTERMOLT_MODEL=qwen3:8b                      # model tag

# OpenAI
OPENAI_API_KEY=sk-...
WINTERMOLT_OPENAI_MODEL=gpt-4o-mini
WINTERMOLT_OPENAI_URL=https://api.openai.com/v1/chat/completions   # full URL, not a base URL

# Anthropic Claude
ANTHROPIC_API_KEY=sk-ant-...

# DeepSeek (cloud)
DEEPSEEK_API_KEY=sk-...

# Qwen (Alibaba DashScope)
QWEN_API_KEY=sk-...
WINTERMOLT_QWEN_MODEL=qwen-plus

# Google Gemini
GOOGLE_GEMINI_API_KEY=...
WINTERMOLT_GEMINI_MODEL=gemini-2.0-flash

# Vision routing (used by /look and image tools)
WINTERMOLT_VISION_BACKEND=ollama   # or "openai"
WINTERMOLT_VISION_MODEL=qwen2.5vl
```

## Provider errors inside a `200` stream

OpenAI-compatible servers often answer `200` and put the failure in an SSE
frame instead of an HTTP status — a quota refusal, a rate limit, or a model the
server does not serve:

```
data: {"type":"error","error":{"message":"Insufficient credits for request"}}
data: {"error":{"message":"Model not found","type":"invalid_request_error"}}
```

Wintermolt treats either shape as a failed request: it prints
`[deepseek] stream error: <provider text>` on stderr and falls back, rather than
reporting a blank answer. A model that merely prints that text is not affected,
because a quote inside a JSON string arrives escaped.

## Interactive setup

Instead of exporting env vars, run:

```bash
./wintermolt --keys
```

This walks through each backend, prompts for keys, and writes them to
`~/.wintermolt/.env`. The file is loaded on every startup.

To inspect what's configured:

```bash
./wintermolt --keys list
```

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
