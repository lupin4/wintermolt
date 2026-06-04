"""Export functionality for Wintermolt conversations.

Exports conversation history to JSONL format, either via the wintermolt
binary or by reading SQLite directly.
"""

import json
from pathlib import Path
from typing import Optional

from cli_anything.wintermolt.core import history


def export_history(
    output_path: str,
    conversation_id: Optional[str] = None,
    limit: int = 100,
) -> dict:
    """Export conversation history to JSONL.

    If conversation_id is given, exports only that conversation.
    Otherwise exports the most recent `limit` conversations.
    """
    output = Path(output_path)
    total = 0

    if conversation_id:
        conversations = [{"id": conversation_id}]
    else:
        conversations = history.list_conversations(limit=limit)

    with output.open("w") as f:
        for convo in conversations:
            messages = history.get_messages(convo["id"])
            for msg in messages:
                record = {
                    "conversation_id": convo["id"],
                    "role": msg.get("role", ""),
                    "content": msg.get("content_json", ""),
                    "sequence": msg.get("sequence_num", 0),
                }
                f.write(json.dumps(record) + "\n")
                total += 1

    return {
        "path": str(output),
        "conversations": len(conversations),
        "messages": total,
    }
