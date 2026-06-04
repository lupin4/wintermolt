"""End-to-end tests for the Wintermolt CLI-Anything harness.

Tests the installed CLI via subprocess, verifying --json output,
command routing, and exit codes.
"""

import json
import os
import shutil
import subprocess
import sys

import pytest


class TestCLISubprocess:
    """Test the CLI via subprocess invocation."""

    @staticmethod
    def _resolve_cli(name: str = "cli-anything-wintermolt") -> str:
        """Resolve the CLI binary path.

        If CLI_ANYTHING_FORCE_INSTALLED is set, uses the installed binary.
        Otherwise falls back to `python -m` invocation.
        """
        if os.environ.get("CLI_ANYTHING_FORCE_INSTALLED"):
            which = shutil.which(name)
            if which:
                return which
            pytest.skip(f"{name} not found in PATH")
        # Fallback: run as module
        return None  # signals to use python -m

    def _run(self, *args: str, expect_success: bool = True) -> subprocess.CompletedProcess:
        """Run a CLI command and return the result."""
        cli_path = self._resolve_cli()
        if cli_path:
            cmd = [cli_path, *args]
        else:
            cmd = [
                sys.executable, "-m",
                "cli_anything.wintermolt.wintermolt_cli", *args,
            ]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if expect_success:
            assert result.returncode == 0, (
                f"Command failed: {' '.join(cmd)}\n"
                f"stdout: {result.stdout}\n"
                f"stderr: {result.stderr}"
            )
        return result

    def test_cli_version(self):
        result = self._run("--version")
        assert "0.1.0" in result.stdout

    def test_cli_help(self):
        result = self._run("--help")
        assert "CLI-Anything harness" in result.stdout
        assert "agent" in result.stdout
        assert "config" in result.stdout
        assert "history" in result.stdout

    def test_cli_json_config_show(self):
        result = self._run("--json", "config", "show")
        data = json.loads(result.stdout)
        assert isinstance(data, dict)

    def test_cli_json_history_stats(self):
        result = self._run("--json", "history", "stats")
        data = json.loads(result.stdout)
        assert isinstance(data, dict)

    def test_cli_json_model_list(self):
        result = self._run("--json", "model", "list")
        data = json.loads(result.stdout)
        assert isinstance(data, list)
        names = [b["name"] for b in data]
        assert "claude" in names
        assert "ollama" in names

    def test_cli_config_backend(self):
        result = self._run("config", "backend")
        # Should output something like "claude (model-name)" or "ollama (llama3)"
        assert len(result.stdout.strip()) > 0

    def test_cli_schedule_list(self):
        # May show "No scheduled jobs." if no scheduler DB
        result = self._run("schedule", "list")
        assert result.returncode == 0

    def test_cli_session_list(self):
        # May show "No sessions found." if no sessions DB
        result = self._run("session", "list")
        assert result.returncode == 0

    def test_cli_history_list(self):
        result = self._run("history", "list")
        assert result.returncode == 0

    def test_cli_extension_list(self):
        # This requires the wintermolt binary — skip if not available
        try:
            from cli_anything.wintermolt.core.backend import find_binary
            find_binary()
        except FileNotFoundError:
            pytest.skip("wintermolt binary not found")
        result = self._run("extension", "list")
        assert result.returncode == 0

    def test_cli_agent_subcommands(self):
        result = self._run("agent", "--help")
        assert "run" in result.stdout
        assert "version" in result.stdout
