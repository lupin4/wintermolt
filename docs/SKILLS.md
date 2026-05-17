# Skills

A skill is a manifest that defines a specialized agent role: a preferred
backend, a preferred model, and a system prompt. Wintermolt ships 79
built-in skills under `skills/` and discovers user-installed ones at
runtime from `~/.wintermolt/skills/`.

## Manifest format

Each skill is a directory containing one `skill.json`:

```json
{
  "name": "code-reviewer",
  "description": "Reviews diffs for correctness, security, and clarity.",
  "backend": "claude",
  "model": "claude-sonnet-4-20250514",
  "role_prompt": "You are a senior reviewer. Flag bugs, security issues, and unclear naming. Cite line numbers. Suggest minimal patches.",
  "tools": ["file_read", "grep", "glob", "bash"]
}
```

| Field         | Required | Notes                                                          |
| :------------ | :------- | :------------------------------------------------------------- |
| `name`        | yes      | Unique identifier (kebab-case).                                |
| `description` | yes      | One-line summary surfaced to the orchestrator agent.           |
| `backend`     | yes      | One of `ollama`, `claude`, `openai`, `deepseek`, `qwen`, `gemini`, `forai`. |
| `model`       | yes      | Model tag for the chosen backend.                              |
| `role_prompt` | yes      | System prompt injected when the skill is dispatched.           |
| `tools`       | no       | Subset of [built-in tools](TOOLS.md) the skill may invoke. If omitted, all tools are available. |

## Built-in skills

Live in `skills/<name>/skill.json`. Examples:

```
skills/
├── code-reviewer/
├── 3d-animator/
├── audio-spatialize/
├── blender-rigger/
├── cli-anything-harness/
└── ... (79 total)
```

List from the REPL:

```
> /skills
> /skills code-reviewer
```

Or via the `skills` tool — the orchestrator agent can dispatch a skill
when the user's request matches a skill's description.

## Adding a custom skill

1. Create `~/.wintermolt/skills/my-skill/skill.json`.
2. Restart Wintermolt (or invoke `/skills reload`).
3. Reference it: `> use my-skill to <task>`.

Custom skills override built-ins of the same name.

## Switching backends per skill

Every skill picks its own backend. The orchestrator may run on Ollama
while a `claude-grader` skill runs on Claude — Wintermolt swaps
backends transparently before dispatching, then restores the
orchestrator's backend afterward.

If a skill names a backend you haven't configured (no API key,
service down), Wintermolt falls back to the current backend and logs
a warning to stderr.
