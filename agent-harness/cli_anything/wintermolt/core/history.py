"""Read-only access to Wintermolt's SQLite conversation history.

Queries ~/.wintermolt/history.db directly for fast, structured access
to conversations and messages without spawning the wintermolt binary.
"""

import json
import sqlite3
from pathlib import Path
from typing import Optional


HISTORY_DB = Path.home() / ".wintermolt" / "history.db"


def _connect() -> sqlite3.Connection:
    """Open a read-only connection to history.db."""
    if not HISTORY_DB.exists():
        raise FileNotFoundError(f"History database not found: {HISTORY_DB}")
    conn = sqlite3.connect(f"file:{HISTORY_DB}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def list_conversations(limit: int = 20) -> list[dict]:
    """List recent conversations, newest first."""
    try:
        conn = _connect()
    except FileNotFoundError:
        return []

    try:
        rows = conn.execute(
            """
            SELECT id, title, mode, platform, created_at, updated_at,
                   (SELECT COUNT(*) FROM messages WHERE conversation_id = c.id) as message_count
            FROM conversations c
            WHERE archived = 0
            ORDER BY updated_at DESC
            LIMIT ?
            """,
            (limit,),
        ).fetchall()
        return [dict(r) for r in rows]
    except sqlite3.OperationalError:
        return []
    finally:
        conn.close()


def get_conversation(conversation_id: str) -> Optional[dict]:
    """Get a single conversation by ID."""
    try:
        conn = _connect()
    except FileNotFoundError:
        return None

    try:
        row = conn.execute(
            "SELECT * FROM conversations WHERE id = ?", (conversation_id,)
        ).fetchone()
        return dict(row) if row else None
    except sqlite3.OperationalError:
        return None
    finally:
        conn.close()


def get_messages(conversation_id: str) -> list[dict]:
    """Get all messages for a conversation."""
    try:
        conn = _connect()
    except FileNotFoundError:
        return []

    try:
        rows = conn.execute(
            """
            SELECT role, sequence_num, content_json, created_at
            FROM messages
            WHERE conversation_id = ?
            ORDER BY sequence_num ASC
            """,
            (conversation_id,),
        ).fetchall()
        return [dict(r) for r in rows]
    except sqlite3.OperationalError:
        return []
    finally:
        conn.close()


def search_messages(query: str, limit: int = 20) -> list[dict]:
    """Full-text search across message content."""
    try:
        conn = _connect()
    except FileNotFoundError:
        return []

    try:
        rows = conn.execute(
            """
            SELECT m.conversation_id, m.role, m.sequence_num, m.content_json, m.created_at,
                   c.title as conversation_title
            FROM messages m
            JOIN conversations c ON c.id = m.conversation_id
            WHERE m.content_json LIKE ?
            ORDER BY m.created_at DESC
            LIMIT ?
            """,
            (f"%{query}%", limit),
        ).fetchall()
        return [dict(r) for r in rows]
    except sqlite3.OperationalError:
        return []
    finally:
        conn.close()


def get_stats() -> dict:
    """Get database statistics."""
    try:
        conn = _connect()
    except FileNotFoundError:
        return {"error": "History database not found"}

    try:
        stats = {}
        row = conn.execute("SELECT COUNT(*) as cnt FROM conversations").fetchone()
        stats["conversation_count"] = row["cnt"] if row else 0

        row = conn.execute(
            "SELECT COUNT(*) as cnt FROM conversations WHERE archived = 1"
        ).fetchone()
        stats["archived_count"] = row["cnt"] if row else 0

        row = conn.execute("SELECT COUNT(*) as cnt FROM messages").fetchone()
        stats["message_count"] = row["cnt"] if row else 0

        stats["file_size_bytes"] = HISTORY_DB.stat().st_size
        return stats
    except sqlite3.OperationalError as e:
        return {"error": str(e)}
    finally:
        conn.close()
