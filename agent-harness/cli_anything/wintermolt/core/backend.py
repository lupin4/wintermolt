"""Backend adapter for Wintermolt binary interaction.

Handles subprocess execution of the wintermolt binary, environment
configuration, and output parsing.
"""

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Optional


def find_binary() -> str:
    """Locate the wintermolt binary.

    Search order:
    1. WINTERMOLT_BIN environment variable
    2. PATH lookup via shutil.which
    3. Common build output paths
    """
    env_bin = os.environ.get("WINTERMOLT_BIN")
    if env_bin and Path(env_bin).is_file():
        return env_bin

    which = shutil.which("wintermolt")
    if which:
        return which

    # Check common Zig build output locations
    for candidate in [
        Path.cwd() / "zig-out" / "bin" / "wintermolt",
        Path.home() / "_git" / "wintermolt" / "zig-out" / "bin" / "wintermolt",
    ]:
        if candidate.is_file():
            return str(candidate)

    raise FileNotFoundError(
        "wintermolt binary not found. Set WINTERMOLT_BIN or add to PATH."
    )


def run_single_shot(
    prompt: str,
    *,
    env_overrides: Optional[dict] = None,
    timeout: int = 120,
    cwd: Optional[str] = None,
) -> dict:
    """Execute a single-shot prompt via `wintermolt -e`.

    Returns dict with keys: stdout, stderr, returncode, success.
    """
    binary = find_binary()
    env = {**os.environ, **(env_overrides or {})}

    try:
        result = subprocess.run(
            [binary, "-e", prompt],
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
            cwd=cwd,
        )
        return {
            "stdout": result.stdout,
            "stderr": result.stderr,
            "returncode": result.returncode,
            "success": result.returncode == 0,
        }
    except subprocess.TimeoutExpired:
        return {
            "stdout": "",
            "stderr": f"Timeout after {timeout}s",
            "returncode": -1,
            "success": False,
        }
    except FileNotFoundError:
        return {
            "stdout": "",
            "stderr": "wintermolt binary not found",
            "returncode": -1,
            "success": False,
        }


def run_extension_command(subcommand: str, arg: Optional[str] = None) -> dict:
    """Execute `wintermolt --extension <subcommand> [arg]`."""
    binary = find_binary()
    cmd = [binary, "--extension", subcommand]
    if arg:
        cmd.append(arg)

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return {
            "stdout": result.stdout,
            "stderr": result.stderr,
            "returncode": result.returncode,
            "success": result.returncode == 0,
        }
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        return {
            "stdout": "",
            "stderr": str(e),
            "returncode": -1,
            "success": False,
        }


def get_version() -> Optional[str]:
    """Get wintermolt version string."""
    binary = find_binary()
    try:
        result = subprocess.run(
            [binary, "--version"], capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return None
