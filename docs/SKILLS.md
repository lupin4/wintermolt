# Skills

A skill is a directory holding one `skill.json` manifest. Wintermolt loads
manifests at startup from three places, later ones replacing earlier ones
of the same `name`:

1. `~/.wintermolt/skills/` (user-global)
2. `./skills/` — relative to the working directory, so the 70 skills in this
   repo load when Wintermolt runs from the repo root
3. `~/.wintermolt/plugins/*/skills/` (installed plugins)

A workspace skill therefore overrides a user-global skill of the same name,
and a plugin skill overrides both. Startup prints
`[skills] Loaded N runtime skill(s)`.

Separately, the `skills` tool carries a fixed catalog of the built-in tools
(`bash`, `file_read`, `grep`, …), compiled into the binary.

## Manifest format

```json
{
  "name": "word_count",
  "description": "Count words in a file.",
  "category": "text",
  "handler_type": "bash",
  "command": "wc -w",
  "keywords": ["count", "words"],
  "user_invokable": true,
  "timeout_ms": 60000
}
```

| Field            | Required | Notes                                                              |
| :--------------- | :------- | :----------------------------------------------------------------- |
| `name`           | yes      | Unique identifier. The manifest is skipped without it.             |
| `description`    | no       | One-line summary, shown in the `skills` tool's list.               |
| `category`       | no       | Defaults to `custom`.                                              |
| `handler_type`   | no       | `bash` (default), `script`, `mcp` or `prompt`. `type` is accepted too. |
| `command`        | for bash, script, mcp | Shell command, script path in the skill directory, or MCP server command. |
| `args`           | no       | MCP server arguments, or the script's interpreter.                 |
| `tool_schema`    | no       | JSON Schema for the tool input. Defaults to one string field, `input`. |
| `keywords`       | no       | Array of strings.                                                  |
| `user_invokable` | no       | Defaults to `true`.                                                |
| `timeout_ms`     | no       | Timeout for bash and script handlers.                              |
| `role_prompt`    | for prompt | The instructions `skills use` hands to the model.          |
| `backend`, `model` | no     | Recorded, not used: a skill applies on the running backend. |

Manifests over 64 KB are skipped.

## Handler types

- **bash** — becomes a tool the model can call. The call runs
  `cd <skill dir> && <command> <input>`.
- **script** — becomes a tool that runs a script from the skill directory.
- **mcp** — Wintermolt starts the command as an MCP server, and its tools
  appear with the prefix `<name>__` (see [MCP.md](MCP.md)).
- **prompt** — instructions, not a tool. `skills use` returns the skill's
  `role_prompt`, framed as "Skill '<name>' is now in effect", into the
  conversation, and the model follows it on whatever backend is running.

All 70 skills shipped in `skills/` are `prompt` skills. They carry the
house rules of the forKernels / Zortran stack (Zig, Fortran, Zortran
bindings, forsec, forsim, syndata, Blender/USD, forDSP, Wintermute), so
the model can load them before working in that area. `zig build test`
checks that every one of them loads with a role prompt.

## Listing and using skills

There is no `/skills` command; the model works through the `skills` tool:

- `operation='list'` — the built-in catalog, then a `--- Runtime Plugins ---`
  section with every loaded manifest.
- `operation='use', name='<skill>'` — load a prompt skill's instructions.
  An unknown name, or a skill without a role prompt, returns an error
  message instead.

`--mcp-server` loads the same skills, so an MCP client can call
`skills use` too.

## Adding a custom skill

1. Create `~/.wintermolt/skills/my-skill/skill.json`.
2. Restart Wintermolt. Manifests are read only at startup.
