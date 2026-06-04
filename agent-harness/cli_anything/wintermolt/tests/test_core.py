"""Unit tests for Wintermolt CLI-Anything harness core modules.

All tests use synthetic data — no wintermolt binary, no SQLite databases.
"""

import json
import os
import tempfile
from pathlib import Path
from unittest import mock

import pytest


# ── Config ───────────────────────────────────────────────────────────────────


class TestConfig:
    def test_load_env_file(self, tmp_path):
        env_file = tmp_path / ".env"
        env_file.write_text(
            'ANTHROPIC_API_KEY=sk-ant-test123\n'
            'WINTERMOLT_MODEL=claude-sonnet-4-20250514\n'
            '# comment line\n'
            '\n'
            'OLLAMA_HOST=http://localhost:11434\n'
        )
        with mock.patch(
            "cli_anything.wintermolt.core.config.ENV_FILE", env_file
        ):
            from cli_anything.wintermolt.core.config import load_env_file

            data = load_env_file()
            assert data["ANTHROPIC_API_KEY"] == "sk-ant-test123"
            assert data["WINTERMOLT_MODEL"] == "claude-sonnet-4-20250514"
            assert data["OLLAMA_HOST"] == "http://localhost:11434"
            assert len(data) == 3  # comment and blank skipped

    def test_load_env_empty(self, tmp_path):
        env_file = tmp_path / ".env_nonexistent"
        with mock.patch(
            "cli_anything.wintermolt.core.config.ENV_FILE", env_file
        ):
            from cli_anything.wintermolt.core.config import load_env_file

            data = load_env_file()
            assert data == {}

    def test_get_active_backend_claude(self):
        with mock.patch.dict(os.environ, {"ANTHROPIC_API_KEY": "sk-test"}):
            from cli_anything.wintermolt.core.config import get_active_backend

            result = get_active_backend()
            assert result["name"] == "claude"
            assert result["configured"] is True

    def test_backend_map_completeness(self):
        from cli_anything.wintermolt.core.config import BACKEND_MAP

        expected = {"claude", "ollama", "openai", "deepseek", "qwen", "gemini"}
        assert set(BACKEND_MAP.keys()) == expected

    def test_config_keys_documented(self):
        from cli_anything.wintermolt.core.config import CONFIG_KEYS

        # All keys should have non-empty descriptions
        for key, desc in CONFIG_KEYS.items():
            assert isinstance(desc, str) and len(desc) > 0, f"{key} missing description"

    def test_set_and_remove_config(self, tmp_path):
        env_file = tmp_path / ".env"
        env_dir = tmp_path
        with mock.patch(
            "cli_anything.wintermolt.core.config.ENV_FILE", env_file
        ), mock.patch(
            "cli_anything.wintermolt.core.config.WINTERMOLT_DIR", env_dir
        ):
            from cli_anything.wintermolt.core.config import set_config, remove_config, load_env_file

            set_config("TEST_KEY", "test_value")
            data = load_env_file()
            assert data["TEST_KEY"] == "test_value"

            removed = remove_config("TEST_KEY")
            assert removed is True
            data = load_env_file()
            assert "TEST_KEY" not in data


# ── History ──────────────────────────────────────────────────────────────────


class TestHistory:
    def test_list_conversations_no_db(self, tmp_path):
        with mock.patch(
            "cli_anything.wintermolt.core.history.HISTORY_DB",
            tmp_path / "nonexistent.db",
        ):
            from cli_anything.wintermolt.core.history import list_conversations

            result = list_conversations()
            assert result == []

    def test_get_stats_no_db(self, tmp_path):
        with mock.patch(
            "cli_anything.wintermolt.core.history.HISTORY_DB",
            tmp_path / "nonexistent.db",
        ):
            from cli_anything.wintermolt.core.history import get_stats

            result = get_stats()
            assert "error" in result

    def test_search_no_db(self, tmp_path):
        with mock.patch(
            "cli_anything.wintermolt.core.history.HISTORY_DB",
            tmp_path / "nonexistent.db",
        ):
            from cli_anything.wintermolt.core.history import search_messages

            result = search_messages("test")
            assert result == []


# ── Session ──────────────────────────────────────────────────────────────────


class TestSession:
    def test_list_sessions_no_db(self, tmp_path):
        with mock.patch(
            "cli_anything.wintermolt.core.session.SESSIONS_DB",
            tmp_path / "nonexistent.db",
        ):
            from cli_anything.wintermolt.core.session import list_sessions

            result = list_sessions()
            assert result == []

    def test_active_count_no_db(self, tmp_path):
        with mock.patch(
            "cli_anything.wintermolt.core.session.SESSIONS_DB",
            tmp_path / "nonexistent.db",
        ):
            from cli_anything.wintermolt.core.session import get_active_count

            result = get_active_count()
            assert result == 0


# ── Scheduler ────────────────────────────────────────────────────────────────


class TestScheduler:
    def test_list_jobs_no_db(self, tmp_path):
        with mock.patch(
            "cli_anything.wintermolt.core.scheduler.SCHEDULER_DB",
            tmp_path / "nonexistent.db",
        ):
            from cli_anything.wintermolt.core.scheduler import list_jobs

            result = list_jobs()
            assert result == []

    def test_enabled_count_no_db(self, tmp_path):
        with mock.patch(
            "cli_anything.wintermolt.core.scheduler.SCHEDULER_DB",
            tmp_path / "nonexistent.db",
        ):
            from cli_anything.wintermolt.core.scheduler import get_enabled_count

            result = get_enabled_count()
            assert result == 0


# ── Export ───────────────────────────────────────────────────────────────────


class TestExport:
    def test_export_empty(self, tmp_path):
        output_file = tmp_path / "export.jsonl"
        with mock.patch(
            "cli_anything.wintermolt.core.history.HISTORY_DB",
            tmp_path / "nonexistent.db",
        ):
            from cli_anything.wintermolt.core.export import export_history

            result = export_history(str(output_file))
            assert result["messages"] == 0
            assert result["conversations"] == 0
            assert output_file.exists()


# ── Backend ──────────────────────────────────────────────────────────────────


class TestBackend:
    def test_find_binary_env(self, tmp_path):
        fake_bin = tmp_path / "wintermolt"
        fake_bin.write_text("#!/bin/sh\necho test")
        fake_bin.chmod(0o755)

        with mock.patch.dict(os.environ, {"WINTERMOLT_BIN": str(fake_bin)}):
            from cli_anything.wintermolt.core.backend import find_binary

            result = find_binary()
            assert result == str(fake_bin)

    def test_find_binary_not_found(self):
        with mock.patch.dict(
            os.environ, {"WINTERMOLT_BIN": ""}, clear=False
        ), mock.patch("shutil.which", return_value=None):
            from cli_anything.wintermolt.core.backend import find_binary

            with pytest.raises(FileNotFoundError):
                find_binary()

    def test_get_version_not_found(self):
        with mock.patch(
            "cli_anything.wintermolt.core.backend.find_binary",
            side_effect=FileNotFoundError,
        ):
            from cli_anything.wintermolt.core.backend import get_version

            result = get_version()
            assert result is None


# ── Formatting ───────────────────────────────────────────────────────────────


class TestFormatting:
    def test_format_json(self):
        from cli_anything.wintermolt.utils.formatting import format_output

        data = {"key": "value", "count": 42}
        result = format_output(data, as_json=True)
        parsed = json.loads(result)
        assert parsed["key"] == "value"
        assert parsed["count"] == 42

    def test_format_table(self):
        from cli_anything.wintermolt.utils.formatting import format_output

        data = [
            {"name": "claude", "model": "sonnet"},
            {"name": "ollama", "model": "llama3"},
        ]
        result = format_output(data)
        assert "claude" in result
        assert "ollama" in result
        assert "sonnet" in result

    def test_format_timestamp(self):
        from cli_anything.wintermolt.utils.formatting import format_timestamp

        assert format_timestamp(0) == "never"
        result = format_timestamp(1700000000)
        assert "2023" in result

    def test_format_empty_list(self):
        from cli_anything.wintermolt.utils.formatting import format_output

        result = format_output([])
        assert result == "(empty)"
