"""Read-only access to Wintermolt's scheduler database.

Queries ~/.wintermolt/scheduler.db for job information.
"""

import sqlite3
from pathlib import Path
from typing import Optional


SCHEDULER_DB = Path.home() / ".wintermolt" / "scheduler.db"


def _connect() -> sqlite3.Connection:
    if not SCHEDULER_DB.exists():
        raise FileNotFoundError(f"Scheduler database not found: {SCHEDULER_DB}")
    conn = sqlite3.connect(f"file:{SCHEDULER_DB}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def list_jobs() -> list[dict]:
    """List all scheduled jobs."""
    try:
        conn = _connect()
    except FileNotFoundError:
        return []

    try:
        rows = conn.execute(
            """
            SELECT id, name, schedule_type, schedule_value, command,
                   enabled, last_run, next_run, run_count, created_at
            FROM jobs
            ORDER BY created_at DESC
            """
        ).fetchall()
        return [dict(r) for r in rows]
    except sqlite3.OperationalError:
        return []
    finally:
        conn.close()


def get_job(job_id: str) -> Optional[dict]:
    """Get a single job by ID."""
    try:
        conn = _connect()
    except FileNotFoundError:
        return None

    try:
        row = conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
        return dict(row) if row else None
    except sqlite3.OperationalError:
        return None
    finally:
        conn.close()


def get_enabled_count() -> int:
    """Count enabled jobs."""
    try:
        conn = _connect()
    except FileNotFoundError:
        return 0

    try:
        row = conn.execute(
            "SELECT COUNT(*) as cnt FROM jobs WHERE enabled = 1"
        ).fetchone()
        return row["cnt"] if row else 0
    except sqlite3.OperationalError:
        return 0
    finally:
        conn.close()
