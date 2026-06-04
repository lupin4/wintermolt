# TEST.md — Wintermolt CLI-Anything Harness Test Plan

## Unit Tests (test_core.py)

Tests use synthetic data — no external dependencies (no wintermolt binary, no SQLite DBs).

### Config Module
- [x] `test_load_env_file` — Parse .env file format
- [x] `test_load_env_empty` — Handle missing .env
- [x] `test_get_active_backend_claude` — Default backend detection
- [x] `test_backend_map_completeness` — All 6 backends present
- [x] `test_config_keys_documented` — All keys have descriptions

### History Module
- [x] `test_list_conversations_no_db` — Graceful when no DB
- [x] `test_get_stats_no_db` — Stats when no DB
- [x] `test_search_no_db` — Search when no DB

### Session Module
- [x] `test_list_sessions_no_db` — Graceful when no DB
- [x] `test_active_count_no_db` — Count when no DB

### Scheduler Module
- [x] `test_list_jobs_no_db` — Graceful when no DB
- [x] `test_enabled_count_no_db` — Count when no DB

### Export Module
- [x] `test_export_empty` — Export with no history

### Backend Module
- [x] `test_find_binary_env` — WINTERMOLT_BIN override
- [x] `test_find_binary_not_found` — Error when not found
- [x] `test_get_version_not_found` — Graceful version check

### Formatting Utils
- [x] `test_format_json` — JSON output mode
- [x] `test_format_table` — Table formatting
- [x] `test_format_timestamp` — Timestamp conversion

## E2E Tests (test_full_e2e.py)

### CLI Subprocess Tests
- [x] `test_cli_version` — `--version` flag
- [x] `test_cli_help` — `--help` flag
- [x] `test_cli_json_config_show` — `--json config show`
- [x] `test_cli_json_history_stats` — `--json history stats`
- [x] `test_cli_json_model_list` — `--json model list`
- [x] `test_cli_config_backend` — `config backend`
- [x] `test_cli_schedule_list` — `schedule list`
- [x] `test_cli_session_list` — `session list`

## Results

(Appended after test execution)
