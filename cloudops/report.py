"""The rendering layer: table, CSV, JSON, and markdown, for every result.

Every producer in the package returns plain data structures; this file is the
only place that knows about columns, alignments, and escaping. Keeping the two
apart is what lets ``--format`` be an afterthought and lets the tests assert
on the data rather than on the spacing.
"""

from __future__ import annotations

import csv
import io
import json
from datetime import date, datetime
from typing import Any, Mapping, Sequence


def as_table(rows: Sequence[Mapping[str, Any]], columns: Sequence[str],
             *, header: str | None = None, stream=None) -> str | None:
    """Purpose: render rows as a fixed-width text table, for a terminal.

    The widths are computed from the data, capped at 48 characters per column
    with an ellipsis, so a wide inventory stays on one line of an 80-column
    terminal. ``stream`` writes the table out directly (and returns None) for
    the CLI; without it the caller gets the string.

    Returns: the table, or None when writing to ``stream``. Side effects: writes
    to the stream when one is given.
    """
    widths = {c: max(len(c), *(len(_text(r.get(c, ""))) for r in rows)) if rows else len(c)
              for c in columns}
    for c in widths:
        widths[c] = min(widths[c], 48)

    def _fit(text: str, width: int) -> str:
        return text if len(text) <= width else text[:width - 1] + "..."

    lines = []
    if header:
        lines.append(header)
        lines.append("-" * len(header))
    lines.append("  ".join(_fit(c.upper(), widths[c]).ljust(widths[c]) for c in columns))
    lines.append("  ".join("-" * widths[c] for c in columns))
    for row in rows:
        rendered = (_fit(_text(row.get(c, "")), widths[c]).ljust(widths[c])
                     for c in columns)
        lines.append("  ".join(rendered))
    text = "\n".join(lines)
    if stream is not None:
        stream.write(text + "\n")
        return None
    return text


def as_csv(rows: Sequence[Mapping[str, Any]], columns: Sequence[str], *,
           stream=None) -> str | None:
    """Purpose: render rows as RFC 4180 CSV for the spreadsheet of the team.

    The first row is the header of the columns, in the order given. Returns:
    the CSV, or None when writing to ``stream``. Side effects: writes to the
    stream when one is given.
    """
    buffer = io.StringIO(newline="")
    writer = csv.DictWriter(buffer, fieldnames=list(columns), extrasaction="ignore",
                            lineterminator="\n")
    writer.writeheader()
    for row in rows:
        writer.writerow({c: _text(row.get(c, "")) for c in columns})
    text = buffer.getvalue()
    if stream is not None:
        stream.write(text)
        return None
    return text


def as_json(payload: Any, *, stream=None, indent: int = 2) -> str | None:
    """Purpose: render any result as JSON, with dates as iso-8601 strings.

    Returns: the JSON, or None when writing to ``stream``. Side effects: writes
    to the stream when one is given.
    """
    def _default(value: Any) -> str:
        if isinstance(value, (date, datetime)):
            return value.isoformat()
        return str(value)

    text = json.dumps(payload, indent=indent, sort_keys=True, default=_default)
    if stream is not None:
        stream.write(text + "\n")
        return None
    return text


def as_markdown(rows: Sequence[Mapping[str, Any]], columns: Sequence[str], *,
                title: str | None = None) -> str:
    """Purpose: render rows as a GitHub flavoured markdown table for a report.

    Used by the weekly status report (OPERATIONS.md) and by Atlantis comments.
    Returns: the markdown. Side effects: none.
    """
    lines = []
    if title:
        lines += [f"## {title}", ""]
    lines.append("| " + " | ".join(columns) + " |")
    lines.append("|" + "|".join(["---"] * len(columns)) + "|")
    for row in rows:
        cells = [_text(row.get(c, "")).replace("|", "\\|") for c in columns]
        lines.append("| " + " | ".join(cells) + " |")
    return "\n".join(lines) + "\n"


def _text(value: Any) -> str:
    """Purpose: coerce one value to display text; None becomes an empty string."""
    if value is None:
        return ""
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, (list, tuple, set)):
        return ", ".join(_text(v) for v in value)
    return str(value)
