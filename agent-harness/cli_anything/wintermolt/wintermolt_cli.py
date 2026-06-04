"""CLI-Anything harness for Wintermolt — main Click CLI entry point.

Provides structured, JSON-capable CLI access to the Wintermolt AI agent.
Supports both one-shot commands and an interactive REPL mode.

Usage:
    cli-anything-wintermolt --json agent run "Fix the bug in main.py"
    cli-anything-wintermolt config show
    cli-anything-wintermolt history list
    cli-anything-wintermolt repl
"""

import json
import sys

import click

from cli_anything.wintermolt.core import backend, config, export, history, scheduler, session
from cli_anything.wintermolt.utils.formatting import format_output, output


class JsonContext:
    """Shared context for --json flag."""

    def __init__(self, json_mode: bool = False):
        self.json = json_mode


pass_ctx = click.make_pass_decorator(JsonContext, ensure=True)


@click.group()
@click.option("--json", "json_mode", is_flag=True, help="Output as JSON")
@click.version_option(package_name="cli-anything-wintermolt")
@click.pass_context
def cli(ctx, json_mode):
    """CLI-Anything harness for Wintermolt AI agent."""
    ctx.ensure_object(JsonContext)
    ctx.obj = JsonContext(json_mode=json_mode)


# ── agent ────────────────────────────────────────────────────────────────────


@cli.group()
def agent():
    """Run the Wintermolt agentic loop."""


@agent.command()
@click.argument("prompt")
@click.option("--timeout", default=120, help="Timeout in seconds")
@click.option("--model", default=None, help="Override AI model")
@click.option("--cwd", default=None, help="Working directory")
@pass_ctx
def run(ctx, prompt, timeout, model, cwd):
    """Execute a single-shot prompt through the agent."""
    env_overrides = {}
    if model:
        env_overrides["WINTERMOLT_MODEL"] = model
    result = backend.run_single_shot(
        prompt, env_overrides=env_overrides, timeout=timeout, cwd=cwd
    )
    if ctx.json:
        output(result, as_json=True)
    else:
        if result["success"]:
            click.echo(result["stdout"])
        else:
            click.echo(result["stderr"], err=True)
            sys.exit(1)


@agent.command()
@pass_ctx
def version(ctx):
    """Show wintermolt binary version."""
    ver = backend.get_version()
    if ctx.json:
        output({"version": ver}, as_json=True)
    else:
        click.echo(ver or "wintermolt binary not found")


# ── config ───────────────────────────────────────────────────────────────────


@cli.group()
def config_cmd():
    """Manage Wintermolt configuration."""


# Rename to avoid shadowing the config module
config_cmd.name = "config"


@config_cmd.command("show")
@pass_ctx
def config_show(ctx):
    """Show current configuration."""
    data = config.list_config()
    # Mask API keys for display
    masked = {}
    for k, v in data.items():
        if "KEY" in k or "TOKEN" in k or "SECRET" in k:
            masked[k] = v[:8] + "..." if len(v) > 8 else "***"
        else:
            masked[k] = v
    if ctx.json:
        output(masked, as_json=True)
    else:
        output(masked)


@config_cmd.command("get")
@click.argument("key")
@pass_ctx
def config_get(ctx, key):
    """Get a specific config value."""
    value = config.get_config(key)
    if ctx.json:
        output({"key": key, "value": value}, as_json=True)
    else:
        if value is not None:
            click.echo(value)
        else:
            click.echo(f"{key}: not set", err=True)
            sys.exit(1)


@config_cmd.command("set")
@click.argument("key")
@click.argument("value")
@pass_ctx
def config_set(ctx, key, value):
    """Set a config value in ~/.wintermolt/.env."""
    config.set_config(key, value)
    if ctx.json:
        output({"key": key, "value": value, "saved": True}, as_json=True)
    else:
        click.echo(f"Set {key}")


@config_cmd.command("remove")
@click.argument("key")
@pass_ctx
def config_remove(ctx, key):
    """Remove a config key from ~/.wintermolt/.env."""
    removed = config.remove_config(key)
    if ctx.json:
        output({"key": key, "removed": removed}, as_json=True)
    else:
        click.echo(f"{'Removed' if removed else 'Not found'}: {key}")


@config_cmd.command("backend")
@pass_ctx
def config_backend(ctx):
    """Show the active AI backend."""
    data = config.get_active_backend()
    if ctx.json:
        output(data, as_json=True)
    else:
        click.echo(f"{data['name']} ({data['model']})")


# ── model ────────────────────────────────────────────────────────────────────


@cli.group()
def model():
    """Switch AI backend and model."""


@model.command("list")
@pass_ctx
def model_list(ctx):
    """List available backends."""
    backends = []
    for name, info in config.BACKEND_MAP.items():
        configured = True
        if info["key_var"]:
            configured = config.get_config(info["key_var"]) is not None
        current_model = config.get_config(info["model_var"]) or "(default)"
        backends.append({
            "name": name,
            "configured": configured,
            "model": current_model,
        })
    if ctx.json:
        output(backends, as_json=True)
    else:
        output(backends)


@model.command("switch")
@click.argument("backend_name")
@click.argument("model_name", required=False)
@pass_ctx
def model_switch(ctx, backend_name, model_name):
    """Switch to a different AI backend."""
    if backend_name not in config.BACKEND_MAP:
        click.echo(
            f"Unknown backend: {backend_name}. "
            f"Available: {', '.join(config.BACKEND_MAP.keys())}",
            err=True,
        )
        sys.exit(1)

    info = config.BACKEND_MAP[backend_name]
    if model_name and info["model_var"]:
        config.set_config(info["model_var"], model_name)

    result = {"backend": backend_name, "model": model_name or "(default)"}
    if ctx.json:
        output(result, as_json=True)
    else:
        click.echo(f"Switched to {backend_name}" + (f" ({model_name})" if model_name else ""))


# ── history ──────────────────────────────────────────────────────────────────


@cli.group()
def history_cmd():
    """Query conversation history."""


history_cmd.name = "history"


@history_cmd.command("list")
@click.option("--limit", default=20, help="Max conversations to show")
@pass_ctx
def history_list(ctx, limit):
    """List recent conversations."""
    convos = history.list_conversations(limit=limit)
    if ctx.json:
        output(convos, as_json=True)
    else:
        if not convos:
            click.echo("No conversations found.")
        else:
            output(convos)


@history_cmd.command("show")
@click.argument("conversation_id")
@pass_ctx
def history_show(ctx, conversation_id):
    """Show messages from a conversation."""
    messages = history.get_messages(conversation_id)
    if ctx.json:
        output(messages, as_json=True)
    else:
        if not messages:
            click.echo("No messages found.")
        else:
            for msg in messages:
                role = msg.get("role", "?")
                content = msg.get("content_json", "")
                click.echo(f"[{role}] {content[:200]}")


@history_cmd.command("search")
@click.argument("query")
@click.option("--limit", default=20, help="Max results")
@pass_ctx
def history_search(ctx, query, limit):
    """Search conversation history."""
    results = history.search_messages(query, limit=limit)
    if ctx.json:
        output(results, as_json=True)
    else:
        if not results:
            click.echo("No matches found.")
        else:
            output(results)


@history_cmd.command("stats")
@pass_ctx
def history_stats(ctx):
    """Show history database statistics."""
    stats = history.get_stats()
    if ctx.json:
        output(stats, as_json=True)
    else:
        output(stats)


# ── session ──────────────────────────────────────────────────────────────────


@cli.group()
def session_cmd():
    """Query chat sessions."""


session_cmd.name = "session"


@session_cmd.command("list")
@click.option("--limit", default=20, help="Max sessions to show")
@pass_ctx
def session_list(ctx, limit):
    """List recent sessions."""
    sessions = session.list_sessions(limit=limit)
    if ctx.json:
        output(sessions, as_json=True)
    else:
        if not sessions:
            click.echo("No sessions found.")
        else:
            output(sessions)


@session_cmd.command("show")
@click.argument("session_id")
@pass_ctx
def session_show(ctx, session_id):
    """Show details for a session."""
    data = session.get_session(session_id)
    if ctx.json:
        output(data, as_json=True)
    else:
        if data:
            output(data)
        else:
            click.echo("Session not found.", err=True)
            sys.exit(1)


# ── schedule ─────────────────────────────────────────────────────────────────


@cli.group()
def schedule():
    """Manage scheduled jobs."""


@schedule.command("list")
@pass_ctx
def schedule_list(ctx):
    """List all scheduled jobs."""
    jobs = scheduler.list_jobs()
    if ctx.json:
        output(jobs, as_json=True)
    else:
        if not jobs:
            click.echo("No scheduled jobs.")
        else:
            output(jobs)


@schedule.command("show")
@click.argument("job_id")
@pass_ctx
def schedule_show(ctx, job_id):
    """Show details for a scheduled job."""
    data = scheduler.get_job(job_id)
    if ctx.json:
        output(data, as_json=True)
    else:
        if data:
            output(data)
        else:
            click.echo("Job not found.", err=True)
            sys.exit(1)


# ── export ───────────────────────────────────────────────────────────────────


@cli.command("export")
@click.argument("output_path", default="/tmp/wintermolt_export.jsonl")
@click.option("--conversation", default=None, help="Export only this conversation ID")
@click.option("--limit", default=100, help="Max conversations to export")
@pass_ctx
def export_cmd(ctx, output_path, conversation, limit):
    """Export conversation history to JSONL."""
    result = export.export_history(output_path, conversation_id=conversation, limit=limit)
    if ctx.json:
        output(result, as_json=True)
    else:
        click.echo(
            f"Exported {result['messages']} messages "
            f"from {result['conversations']} conversations to {result['path']}"
        )


# ── extension ────────────────────────────────────────────────────────────────


@cli.group()
def extension():
    """Manage Wintermolt extensions."""


@extension.command("list")
@pass_ctx
def extension_list(ctx):
    """List installed extensions."""
    result = backend.run_extension_command("list")
    if ctx.json:
        output(result, as_json=True)
    else:
        click.echo(result["stdout"] or "No extensions installed.")


@extension.command("available")
@pass_ctx
def extension_available(ctx):
    """List available extensions."""
    result = backend.run_extension_command("available")
    if ctx.json:
        output(result, as_json=True)
    else:
        click.echo(result["stdout"])


@extension.command("install")
@click.argument("name")
@pass_ctx
def extension_install(ctx, name):
    """Install an extension."""
    result = backend.run_extension_command("install", name)
    if ctx.json:
        output(result, as_json=True)
    else:
        click.echo(result["stdout"] or result["stderr"])


@extension.command("remove")
@click.argument("name")
@pass_ctx
def extension_remove(ctx, name):
    """Remove an extension."""
    result = backend.run_extension_command("remove", name)
    if ctx.json:
        output(result, as_json=True)
    else:
        click.echo(result["stdout"] or result["stderr"])


# ── repl ─────────────────────────────────────────────────────────────────────


@cli.command()
def repl():
    """Start an interactive REPL session.

    Wraps the wintermolt binary's interactive mode.
    """
    import subprocess

    binary = backend.find_binary()
    try:
        subprocess.run([binary], check=False)
    except FileNotFoundError:
        click.echo("wintermolt binary not found.", err=True)
        sys.exit(1)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    cli()
