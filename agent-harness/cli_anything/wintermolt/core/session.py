"""Read-only access to Wintermolt's session database.

Queries ~/.wintermolt/sessions.db for active session information.
"""

import sqlite3
from pathlib import Path
from typing import Optional


SESSIONS_DB = Path.home() / ".wintermolt" / "sessions.db"


def _connect() -> sqlite3.Connection:
    if not SESSIONS_DB.exists():
        raise FileNotFoundError(f"Sessions database not found: {SESSIONS_DB}")
    conn = sqlite3.connect(f"file:{SESSIONS_DB}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def list_sessions(limit: int = 20) -> list[dict]:
    """List recent sessions."""
    try:
        conn = _connect()
    except FileNotFoundError:
        return []

    try:
        rows = conn.execute(
            """
            SELECT id, agent_id, platform, channel, user_id, state,
                   message_count, created_at, last_active
            FROM sessions
            ORDER BY last_active DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()
        return [dict(r) for r in rows]
    except sqlite3.OperationalError:
        return []
    finally:
        conn.close()


def get_session(session_id: str) -> Optional[dict]:
    """Get a single session by ID."""
    try:
        conn = _connect()
    except FileNotFoundError:
        return None

    try:
        row = conn.execute(
            "SELECT * FROM sessions WHERE id = ?", (session_id,)
        ).fetchone()
        return dict(row) if row else None
    except sqlite3.OperationalError:
        return None
    finally:
        conn.close()


def get_active_count() -> int:
    """Count currently active sessions."""
    try:
        conn = _connect()
    except FileNotFoundError:
        return 0

    try:
        row = conn.execute(
            "SELECT COUNT(*) as cnt FROM sessions WHERE state = 'active'"
        ).fetchone()
        return row["cnt"] if row else 0
    except sqlite3.OperationalError:
        return 0
    finally:
        conn.close()
