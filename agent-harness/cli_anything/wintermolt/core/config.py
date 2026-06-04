"""Configuration management for Wintermolt.

Reads and writes ~/.wintermolt/.env and manages environment variables
for backend selection, API keys, and runtime options.
"""

import os
from pathlib import Path
from typing import Optional


WINTERMOLT_DIR = Path.home() / ".wintermolt"
ENV_FILE = WINTERMOLT_DIR / ".env"

# All known configuration keys with their descriptions
CONFIG_KEYS = {
    # AI Backends
    "ANTHROPIC_API_KEY": "Claude API key",
    "OPENAI_API_KEY": "OpenAI API key",
    "DEEPSEEK_API_KEY": "DeepSeek API key",
    "QWEN_API_KEY": "Qwen API key",
    "GOOGLE_GEMINI_API_KEY": "Google Gemini API key",
    "OLLAMA_HOST": "Ollama URL (default: http://localhost:11434)",
    # Model settings
    "WINTERMOLT_MODEL": "Default model name",
    "WINTERMOLT_TOKENS": "Max response tokens (default: 8192)",
    "WINTERMOLT_OLLAMA_MODEL": "Ollama model (default: llama3)",
    "WINTERMOLT_OPENAI_MODEL": "OpenAI model (default: gpt-4o-mini)",
    "WINTERMOLT_GEMINI_MODEL": "Gemini model (default: gemini-2.0-flash)",
    "WINTERMOLT_QWEN_MODEL": "Qwen model (default: qwen-plus)",
    # Runtime
    "WINTERMOLT_NO_HISTORY": "Set 1 to disable SQLite persistence",
    "WINTERMOLT_SYSTEM_PROMPT": "Custom system prompt",
    "WINTERMOLT_SANDBOX": "Sandbox mode: docker or 1",
    "WINTERMOLT_TOOL_ALLOWLIST": "Comma-separated allowed tools",
    "WINTERMOLT_TOOL_BLOCKLIST": "Comma-separated blocked tools",
    # RAG
    "PINECONE_API_KEY": "Pinecone API key",
    "PINECONE_HOST": "Pinecone index host URL",
    # Network
    "TAILSCALE_API_KEY": "Tailscale REST API key",
    # TTS
    "WINTERMOLT_TTS_PROVIDER": "TTS provider: openai, elevenlabs, edge",
    "WINTERMOLT_TTS_VOICE": "Voice name (default: alloy)",
}

BACKEND_MAP = {
    "claude": {"key_var": "ANTHROPIC_API_KEY", "model_var": "WINTERMOLT_MODEL"},
    "ollama": {"key_var": None, "model_var": "WINTERMOLT_OLLAMA_MODEL"},
    "openai": {"key_var": "OPENAI_API_KEY", "model_var": "WINTERMOLT_OPENAI_MODEL"},
    "deepseek": {"key_var": "DEEPSEEK_API_KEY", "model_var": "WINTERMOLT_MODEL"},
    "qwen": {"key_var": "QWEN_API_KEY", "model_var": "WINTERMOLT_QWEN_MODEL"},
    "gemini": {"key_var": "GOOGLE_GEMINI_API_KEY", "model_var": "WINTERMOLT_GEMINI_MODEL"},
}


def load_env_file() -> dict:
    """Parse ~/.wintermolt/.env into a dict."""
    result = {}
    if not ENV_FILE.exists():
        return result
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            result[key] = value
    return result


def get_config(key: str) -> Optional[str]:
    """Get a config value. Environment takes precedence over .env file."""
    env_val = os.environ.get(key)
    if env_val is not None:
        return env_val
    env_file = load_env_file()
    return env_file.get(key)


def set_config(key: str, value: str) -> None:
    """Set a config value in ~/.wintermolt/.env."""
    WINTERMOLT_DIR.mkdir(parents=True, exist_ok=True)
    env_data = load_env_file()
    env_data[key] = value
    _write_env_file(env_data)


def remove_config(key: str) -> bool:
    """Remove a config key from ~/.wintermolt/.env. Returns True if found."""
    env_data = load_env_file()
    if key not in env_data:
        return False
    del env_data[key]
    _write_env_file(env_data)
    return True


def list_config() -> dict:
    """Return all config from .env file merged with active env vars."""
    result = load_env_file()
    for key in CONFIG_KEYS:
        env_val = os.environ.get(key)
        if env_val is not None:
            result[key] = env_val
    return result


def get_active_backend() -> dict:
    """Determine which backend is currently active based on config."""
    model = get_config("WINTERMOLT_MODEL") or "claude-sonnet-4-20250514"

    for name, info in BACKEND_MAP.items():
        if info["key_var"] and get_config(info["key_var"]):
            if name == "claude" and "claude" in model:
                return {"name": name, "model": model, "configured": True}

    # Default to claude if ANTHROPIC_API_KEY is set
    if get_config("ANTHROPIC_API_KEY"):
        return {"name": "claude", "model": model, "configured": True}

    # Check ollama (no API key needed)
    ollama_host = get_config("OLLAMA_HOST") or "http://localhost:11434"
    ollama_model = get_config("WINTERMOLT_OLLAMA_MODEL") or "llama3"
    return {"name": "ollama", "model": ollama_model, "configured": True}


def _write_env_file(data: dict) -> None:
    """Write config dict back to .env file."""
    lines = []
    for key, value in sorted(data.items()):
        if " " in value or '"' in value:
            lines.append(f'{key}="{value}"')
        else:
            lines.append(f"{key}={value}")
    ENV_FILE.write_text("\n".join(lines) + "\n")
