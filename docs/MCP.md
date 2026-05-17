# Model Context Protocol (MCP)

Wintermolt is both an **MCP client** (connects to external MCP servers
to use their tools) and an **MCP server** (exposes its own tools to any
MCP-compatible client like Claude Desktop, Zed, or Cursor).

Implementation: `src/mcp/` — `client.zig`, `server.zig`, `protocol.zig`,
`json_rpc.zig`. Wire format is JSON-RPC 2.0 over stdio.

## As a client

Wintermolt reads MCP server configs from `~/.wintermolt/mcp.json`:

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/projects"]
    },
    "github": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-github"],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_..."
      }
    }
  }
}
```

On startup, Wintermolt spawns each server as a subprocess, performs
the JSON-RPC handshake, and merges the server's tool catalog into the
agent's available tools. Tools from MCP servers are namespaced
`<server>__<tool>` (e.g. `github__create_issue`).

If the file is missing, you'll see `[mcp-client] No config at ...` on
startup — that's informational, not an error.

## As a server

Expose Wintermolt's [built-in tools](TOOLS.md) to an MCP client:

```bash
./wintermolt --mcp-server
```

This puts Wintermolt into stdio JSON-RPC mode. Hook it into a client:

**Claude Desktop** (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "wintermolt": {
      "command": "/usr/local/bin/wintermolt",
      "args": ["--mcp-server"]
    }
  }
}
```

**Zed** (`~/.config/zed/settings.json`):

```json
{
  "context_servers": {
    "wintermolt": {
      "command": "wintermolt",
      "args": ["--mcp-server"]
    }
  }
}
```

## Protocol version

Wintermolt implements MCP protocol revision `2024-11-05`. See
`src/mcp/protocol.zig:PROTOCOL_VERSION` for the exact constant.

## Debugging

Set `WINTERMOLT_MCP_DEBUG=1` to log every JSON-RPC frame to stderr.
Useful when a client connects but doesn't see tools.
