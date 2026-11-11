#!/usr/bin/env python3
"""Validate and atomically publish a model-deprecations delegate report."""

import os
import re
import sys
import tempfile
from datetime import date
from pathlib import Path

VENDORS = {"anthropic", "openai", "gemini", "openrouter", "databricks", "muse"}
TABLE_HEADER = ["model", "kind", "field", "vendor", "models.dev"]
KINDS = {"deprecated", "retired", "new"}


def fail(reason):
    print(f"model-deprecations: {reason}", file=sys.stderr)
    raise SystemExit(1)


def cells(line):
    if not line.startswith("|") or not line.endswith("|"):
        return None
    return [part.strip() for part in line[1:-1].split("|")]


def validate_date(value):
    try:
        date.fromisoformat(value)
    except ValueError:
        fail("invalid report date")


def validate_report(text, today, source):
    validate_date(today)
    lines = text.splitlines()
    if not lines or lines[0] != f"# Model deprecations {today}":
        fail("invalid report heading")
    if len(lines) < 2 or lines[1] != f"source: model-deprecations {source}":
        fail("invalid report source line")

    sections = [index for index, line in enumerate(lines) if line.startswith("## ")]
    skipped_sections = [index for index in sections if lines[index] == "## skipped"]
    if len(skipped_sections) != 1 or skipped_sections[0] != sections[-1]:
        fail("missing or misplaced skipped section")
    skipped_at = skipped_sections[0]
    row_count = 0
    seen_vendors = set()
    current_vendor = None
    header_seen = False
    separator_seen = False

    for line in lines[2:skipped_at]:
        if line.startswith("## "):
            current_vendor = line[3:].strip()
            if current_vendor not in VENDORS or current_vendor in seen_vendors:
                fail("invalid vendor section")
            seen_vendors.add(current_vendor)
            header_seen = False
            separator_seen = False
            continue
        if not line.startswith("|"):
            continue
        if current_vendor is None:
            fail("table appears outside a vendor section")
        values = cells(line)
        if values is None or len(values) != 5:
            fail("invalid report table")
        if values == TABLE_HEADER:
            if header_seen:
                fail("duplicate report table header")
            header_seen = True
            continue
        if not header_seen:
            fail("report table header missing")
        if not separator_seen and all(re.fullmatch(r"-+", value) for value in values):
            separator_seen = True
            continue
        if not separator_seen:
            fail("report table separator missing")
        if values[1] not in KINDS or not values[0]:
            fail("invalid lifecycle row")
        if not re.search(r"https?://\S+", line):
            fail("lifecycle row has no source URL")
        if values[1] == "deprecated":
            retirement = re.search(r"\b\d{4}-\d{2}-\d{2}\b", line)
            if not retirement:
                fail("deprecated row has no retirement date")
            validate_date(retirement.group(0))
        row_count += 1
    for vendor in seen_vendors:
        section_at = next(index for index in sections if lines[index] == f"## {vendor}")
        section_end = next((index for index in sections if index > section_at), skipped_at)
        section_lines = lines[section_at + 1 : section_end]
        if "| model | kind | field | vendor | models.dev |" not in section_lines:
            fail("vendor section has no shared table header")
        if not any(re.fullmatch(r"\|\s*-+\s*\|\s*-+\s*\|\s*-+\s*\|\s*-+\s*\|\s*-+\s*\|", item) for item in section_lines):
            fail("vendor section has no table separator")

    skipped_lines = lines[skipped_at + 1 :]
    skip_count = 0
    for line in skipped_lines:
        if not line.strip():
            continue
        match = re.fullmatch(r"- ([a-z]+): .+", line)
        if not match or match.group(1) not in VENDORS | {"all"}:
            fail("invalid skipped entry")
        skip_count += 1
    return row_count, skip_count


def write_report(text, inbox, today):
    inbox = Path(inbox).expanduser()
    try:
        inbox.mkdir(parents=True, exist_ok=True)
        target = inbox / f"model-deprecations-{today}.md"
        descriptor, temporary = tempfile.mkstemp(prefix=".model-deprecations-", suffix=".tmp", dir=inbox)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as output:
                output.write(text if text.endswith("\n") else text + "\n")
            os.replace(temporary, target)
        except BaseException:
            try:
                os.unlink(temporary)
            except OSError:
                pass
            raise
    except OSError:
        fail("cannot publish report")
    print(f"model-deprecations: wrote {target.name}")
    return 0


def publish(scratch, inbox, today, source):
    scratch = Path(scratch)
    try:
        if not scratch.is_file():
            fail("scratch report is missing")
        text = scratch.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        fail("cannot read scratch report")
    if not text.strip():
        fail("scratch report is empty")
    rows, skipped = validate_report(text, today, source)
    if rows == 0 and skipped == 0:
        return 0
    return write_report(text, inbox, today)


def publish_failure(inbox, today, source, status=""):
    reason = "model produced no report"
    if status:
        if not re.fullmatch(r"[A-Z][A-Z_]*", status):
            fail("invalid delegate job status")
        reason += f" (delegate status: {status})"
    text = "\n".join((
        f"# Model deprecations {today}",
        f"source: model-deprecations {source}",
        "",
        "## skipped",
        f"- all: {reason}",
        "",
    ))
    validate_report(text, today, source)
    return write_report(text, inbox, today)


def main(argv):
    if len(argv) == 6 and argv[1] == "publish":
        return publish(argv[2], argv[3], argv[4], argv[5])
    if len(argv) in (5, 6) and argv[1] == "failure":
        return publish_failure(argv[2], argv[3], argv[4], argv[5] if len(argv) == 6 else "")
    fail("usage: model-deprecations.py publish SCRATCH INBOX YYYY-MM-DD SOURCE")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
