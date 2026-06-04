# cli-anything-wintermolt

CLI-Anything harness for the [Wintermolt](https://github.com/lupin4/wintermolt) AI agent CLI.

## Installation

```bash
cd agent-harness
pip install -e .
```

## Usage

### One-shot agent execution
```bash
cli-anything-wintermolt agent run "Fix the bug in main.py"
cli-anything-wintermolt --json agent run "Explain this code"
```

### Configuration
```bash
cli-anything-wintermolt config show
cli-anything-wintermolt config get ANTHROPIC_API_KEY
cli-anything-wintermolt config set WINTERMOLT_MODEL claude-sonnet-4-20250514
cli-anything-wintermolt config backend
```

### Model switching
```bash
cli-anything-wintermolt model list
cli-anything-wintermolt model switch ollama llama3
cli-anything-wintermolt model switch claude
```

### History
```bash
cli-anything-wintermolt history list
cli-anything-wintermolt history show <conversation-id>
cli-anything-wintermolt history search "authentication bug"
cli-anything-wintermolt history stats
```

### Sessions
```bash
cli-anything-wintermolt session list
cli-anything-wintermolt session show <session-id>
```

### Scheduler
```bash
cli-anything-wintermolt schedule list
cli-anything-wintermolt schedule show <job-id>
```

### Export
```bash
cli-anything-wintermolt export /tmp/history.jsonl
cli-anything-wintermolt --json export --conversation <id>
```

### Extensions
```bash
cli-anything-wintermolt extension list
cli-anything-wintermolt extension available
cli-anything-wintermolt extension install <name>
cli-anything-wintermolt extension remove <name>
```

### Interactive REPL
```bash
cli-anything-wintermolt repl
```

### JSON mode
All commands support `--json` for structured output:
```bash
cli-anything-wintermolt --json history stats
cli-anything-wintermolt --json config show
cli-anything-wintermolt --json schedule list
```

## Requirements

- Python >= 3.9
- `click` >= 8.0
- Wintermolt binary in PATH or `WINTERMOLT_BIN` set
