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

`/model` is the REPL's command, and `--web` has its own `/model` endpoint, so a
run that reaches neither — `-e`, `--gateway`, `--chat` — has no way to leave the
Ollama default. `WINTERMOLT_BACKEND` picks the backend the run starts on, in
every mode:

```bash
# one-shot prompt through the OpenAI backend, no REPL to type /model in
WINTERMOLT_BACKEND=openai OPENAI_API_KEY=sk-... ./wintermolt -e "summarise README.md"

# gateway server in front of Claude
WINTERMOLT_BACKEND=claude ANTHROPIC_API_KEY=sk-ant-... ./wintermolt --gateway
```

Every loop the run builds starts on that backend, including the `--chat` agent
pool and the subagents of `spawn_agent`.

The variable chooses only *where* a request goes. A model named by
`WINTERMOLT_MODEL`, or by the cloud override `wintermolt.json` can select, is
used as-is by whichever backend is chosen; without one, the backend's own
variable applies (`WINTERMOLT_OPENAI_MODEL`, `WINTERMOLT_QWEN_MODEL`,
`WINTERMOLT_GEMINI_MODEL`, `WINTERMOLT_OLLAMA_MODEL`,
`WINTERMOLT_KERNEL_DEFAULT`, `WINTERMOLT_FORAI_DEFAULT`), and then the default
in the table above.

Setting the variable is an explicit request, so a backend that cannot be built —
a mistyped name, a cloud backend without its key, `forai` on a build without the
engine — prints the reason and exits 1 before the first request. It never
quietly answers from Ollama. It also wins over the `models.chat.prefer` routing
in `wintermolt.json`.

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

## When a request fails

A failed request is retried on Ollama, then on the `openai` backend if
`OPENAI_API_KEY` is set, skipping whichever of the two just failed (`deepseek`,
`qwen` and `gemini` count as `openai`). `[fallback]` on stderr names each
attempt. If nothing answers, `-e` exits 1.

```bash
WINTERMOLT_NO_FALLBACK=1    # no retry: the backend you chose answers or the run fails
WINTERMOLT_NO_TOOLS=1       # send no tool definitions (models without function calling)
WINTERMOLT_STALL_TIMEOUT=180  # seconds with nothing received before a request is dropped
```

Every backend drops a request only when it goes quiet. A long answer that
keeps streaming, or a local engine still warming up within the stall window,
is never cut off. `0` waits forever.

## Provider errors inside a `200` stream

OpenAI-compatible servers often answer `200` and put the failure in an SSE
frame instead of an HTTP status — a quota refusal, a rate limit, or a model the
server does not serve:

```
data: {"type":"error","error":{"message":"Insufficient credits for request"}}
data: {"error": {"message":"Model not found","type":"invalid_request_error"}}
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
