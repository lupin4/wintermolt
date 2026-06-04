"""Output formatting utilities for the Wintermolt CLI harness."""

import json
import sys
from datetime import datetime, timezone
from typing import Any


def format_output(data: Any, as_json: bool = False) -> str:
    """Format data for output. JSON mode returns structured data."""
    if as_json:
        return json.dumps(data, indent=2, default=str)

    if isinstance(data, dict):
        return _format_dict(data)
    if isinstance(data, list):
        return _format_list(data)
    return str(data)


def _format_dict(d: dict, indent: int = 0) -> str:
    lines = []
    prefix = "  " * indent
    for key, value in d.items():
        if isinstance(value, dict):
            lines.append(f"{prefix}{key}:")
            lines.append(_format_dict(value, indent + 1))
        elif isinstance(value, list):
            lines.append(f"{prefix}{key}: [{len(value)} items]")
        else:
            lines.append(f"{prefix}{key}: {value}")
    return "\n".join(lines)


def _format_list(items: list) -> str:
    if not items:
        return "(empty)"
    if isinstance(items[0], dict):
        return _format_table(items)
    return "\n".join(f"  - {item}" for item in items)


def _format_table(rows: list[dict]) -> str:
    """Format a list of dicts as a simple table."""
    if not rows:
        return "(empty)"

    keys = list(rows[0].keys())
    widths = {k: len(k) for k in keys}
    for row in rows:
        for k in keys:
            widths[k] = max(widths[k], len(str(row.get(k, ""))))

    # Limit column width
    for k in widths:
        widths[k] = min(widths[k], 40)

    header = "  ".join(k.ljust(widths[k]) for k in keys)
    sep = "  ".join("-" * widths[k] for k in keys)
    lines = [header, sep]
    for row in rows:
        line = "  ".join(str(row.get(k, "")).ljust(widths[k])[:widths[k]] for k in keys)
        lines.append(line)
    return "\n".join(lines)


def format_timestamp(ts: int) -> str:
    """Format a Unix timestamp to human-readable string."""
    if ts == 0:
        return "never"
    try:
        dt = datetime.fromtimestamp(ts, tz=timezone.utc)
        return dt.strftime("%Y-%m-%d %H:%M:%S UTC")
    except (ValueError, OSError):
        return str(ts)


def output(data: Any, as_json: bool = False) -> None:
    """Print formatted output to stdout."""
    print(format_output(data, as_json=as_json))
