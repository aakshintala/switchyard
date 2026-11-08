#!/usr/bin/env python3
"""Structured-data helpers for bin/canary-daily. Invoked with python3 -I."""

import ast
import hashlib
import json
import math
import os
import re
import subprocess
import sys
from datetime import date, timedelta
from pathlib import Path

MODEL = "gpt-6-luna"
HARNESS_ORDER = {"codex": 0, "fiber": 1, "pi": 2}
TASK_ORDER = {"json-unescape": 0, "float-print": 1, "utf16-transcode": 2}


def fail(message):
    print(f"canary-daily: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_stdout_details(path, harness):
    run_dir = None
    version = None
    binary = None
    prefix = f"== {harness}: "
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("run dir: "):
            run_dir = line[len("run dir: ") :].strip()
        if line.startswith(prefix):
            detail = line[len(prefix) :]
            head, separator, rest = detail.partition(" (")
            if not separator:
                continue
            path_and_tail = rest.rsplit("), cap ", 1)
            if len(path_and_tail) != 2:
                continue
            version = head.strip()
            binary = path_and_tail[0]
    if not run_dir:
        fail("canary-run.sh did not print a run dir")
    if not version or not binary:
        fail(f"canary-run.sh did not print the {harness} version and binary")
    return run_dir, version, binary


def parse_summary(summary):
    for line in summary.splitlines():
        if not line.startswith("main ") or " | wrapup " not in line:
            continue
        main_text, wrapup_text = line[len("main ") :].split(" | wrapup ", 1)
        main_match = re.fullmatch(r"(.+) total ([0-9]+)", main_text)
        wrapup_match = re.fullmatch(r"(.+) total ([0-9]+)", wrapup_text)
        if not main_match or not wrapup_match:
            continue
        try:
            main = ast.literal_eval(main_match.group(1))
            wrapup = ast.literal_eval(wrapup_match.group(1))
        except (SyntaxError, ValueError) as error:
            fail(f"cannot parse canary-sum token dictionaries: {error}")
        return (
            token_record(main, int(main_match.group(2))),
            token_record(wrapup, int(wrapup_match.group(2))),
        )
    fail("canary-sum.py did not print the main/wrapup token summary")


def token_record(value, total):
    if not isinstance(value, dict) or any(key not in value for key in ("inp", "cache", "out")):
        fail("canary-sum.py returned an invalid token dictionary")
    fields = {key: value[key] for key in ("inp", "cache", "out")}
    if any(isinstance(item, bool) or not isinstance(item, int) for item in fields.values()):
        fail("canary-sum.py returned non-integer token counts")
    if total != sum(fields.values()):
        fail("canary-sum.py token total does not match its dictionary")
    return {**fields, "total": total}


def passing_grades(stdout_path, run_dir, task):
    for line in Path(stdout_path).read_text(encoding="utf-8", errors="replace").splitlines():
        match = re.fullmatch(r"== grades during run: ([0-9]+)", line)
        if match:
            return int(match.group(1))
    scores = Path(run_dir) / "tasks" / task / "scores.jsonl"
    if not scores.is_file():
        return 0
    lines = [line for line in scores.read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()]
    # A run's score stream begins with its baseline grade; subtract that line.
    return max(0, len(lines) - 1)


def failed_attempt_count(run_dir):
    # ./grade prints "grade: FAIL (<reason>)" on a failed attempt. Skip the
    # JSON-escaped quote before it, which is the agent reading grade's source.
    # This may overcount when a harness echoes tool output twice.
    pattern = re.compile(r'(?<!\\")grade: FAIL \(')
    count = 0
    for name in ("agent.jsonl", "wrapup.jsonl"):
        path = Path(run_dir) / name
        if path.is_file():
            count += len(pattern.findall(path.read_text(encoding="utf-8", errors="replace")))
    return count


def binary_sha(path):
    try:
        with open(os.path.realpath(path), "rb") as binary_file:
            digest = hashlib.sha256()
            for chunk in iter(lambda: binary_file.read(1024 * 1024), b""):
                digest.update(chunk)
            return digest.hexdigest()
    except OSError:
        return None


def calculated_cost(canary_dir, main, wrapup):
    prices_path = Path(canary_dir) / "prices.json"
    if not prices_path.exists():
        return None
    try:
        prices = json.loads(prices_path.read_text(encoding="utf-8"))[MODEL]
        rates = {key: prices[key] for key in ("input", "cache", "output")}
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        fail(f"cannot read prices.json: {error}")
    if any(isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) for value in rates.values()):
        fail("prices.json rates must be finite numbers")
    tokens = {
        "input": main["inp"] + wrapup["inp"],
        "cache": main["cache"] + wrapup["cache"],
        "output": main["out"] + wrapup["out"],
    }
    return sum(tokens[key] * rates[key] for key in rates) / 1_000_000


def make_row(canary_dir, run_date, host, harness, stdout_path):
    run_dir, version, binary = read_stdout_details(stdout_path, harness)
    run_path = Path(run_dir)
    if not run_path.is_dir():
        fail(f"run dir does not exist: {run_dir}")
    try:
        meta = json.loads((run_path / "meta.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read {run_path}/meta.json: {error}")
    if not isinstance(meta, dict):
        fail(f"{run_path}/meta.json is not an object")
    try:
        summary = subprocess.run(
            ["python3", "-I", os.path.join(canary_dir, "canary-sum.py"), str(run_path)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        fail(f"canary-sum.py failed for {run_dir}: {error}")
    main_tokens, wrapup_tokens = parse_summary(summary)
    final_score = meta.get("final_score")
    if final_score == "fail":
        score = None
    else:
        try:
            score = float(final_score)
        except (TypeError, ValueError):
            fail(f"invalid final_score in {run_path}/meta.json")
    try:
        row = {
            "date": run_date,
            "host": host,
            "harness": harness,
            "harness_version": version,
            "harness_sha": binary_sha(binary),
            "model": MODEL,
            "thinking": "xhigh",
            "task": meta["task"],
            "bench": meta["bench"],
            "cap_min": meta["cap_min"],
            "score": score,
            "rc": meta["rc"],
            "wrapup_rc": meta.get("wrapup_rc"),
            "restored": meta.get("restored"),
            "main_tokens": main_tokens,
            "wrapup_tokens": wrapup_tokens,
            "reviewer_tokens": None,
            "cost": calculated_cost(canary_dir, main_tokens, wrapup_tokens),
            "wall_s": meta["wall_s"],
            "grades": passing_grades(stdout_path, run_dir, meta["task"]),
            "failed_attempts": failed_attempt_count(run_dir),
            "run_dir": str(run_path),
        }
    except KeyError as error:
        fail(f"missing required metadata field {error} in {run_path}/meta.json")
    print(json.dumps(row, separators=(",", ":"), allow_nan=False))


def read_series(path):
    rows = []
    if not path.exists():
        return rows
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            fail(f"invalid JSON on {path}:{number}: {error}")
        if not isinstance(row, dict) or "date" not in row or "task" not in row or "harness" not in row:
            fail(f"invalid series row on {path}:{number}")
        try:
            row["_date"] = date.fromisoformat(row["date"])
        except (TypeError, ValueError):
            fail(f"invalid date on {path}:{number}")
        row["_line"] = number
        rows.append(row)
    return rows


def fmt_score(value):
    return "-" if value is None else f"{value:+.4f}"


def fmt_delta(value, precision=4):
    return "-" if value is None else f"{value:+,.{precision}f}"


def fmt_tokens(value):
    return "-" if value is None else f"{value:,}"


def report(canary_dir, days):
    rows = read_series(Path(canary_dir) / "series.jsonl")
    groups = {}
    for row in rows:
        groups.setdefault((row["task"], row["harness"]), []).append(row)
    latest_by_task_date = {}
    for row in rows:
        key = (row["task"], row["harness"], row["date"])
        previous = latest_by_task_date.get(key)
        if previous is None or row["_line"] > previous["_line"]:
            latest_by_task_date[key] = row

    header = (
        f"{'task':<17} {'harness':<7} {'latest score':>12} {'trend mean':>11} "
        f"{'delta':>10} {'main tokens':>12} {'token mean':>12} {'delta':>12} {'vs codex':>9}"
    )
    lines = [header, "-" * len(header)]
    for (task, harness), points in sorted(
        groups.items(),
        key=lambda item: (TASK_ORDER.get(item[0][0], 99), item[0][0], HARNESS_ORDER.get(item[0][1], 99), item[0][1]),
    ):
        latest = max(points, key=lambda point: (point["_date"], point["_line"]))
        cutoff = latest["_date"] - timedelta(days=days)
        prior = [point for point in points if cutoff < point["_date"] < latest["_date"]]
        score_values = [point["score"] for point in prior if isinstance(point.get("score"), (int, float))]
        token_values = [
            point["main_tokens"]["total"]
            for point in prior
            if isinstance(point.get("main_tokens"), dict)
            and isinstance(point["main_tokens"].get("total"), (int, float))
        ]
        score_mean = sum(score_values) / len(score_values) if score_values else None
        token_mean = sum(token_values) / len(token_values) if token_values else None
        latest_score = latest.get("score")
        latest_tokens = latest.get("main_tokens", {}).get("total")
        score_delta = latest_score - score_mean if score_mean is not None and isinstance(latest_score, (int, float)) else None
        token_delta = latest_tokens - token_mean if token_mean is not None and isinstance(latest_tokens, (int, float)) else None
        codex = latest_by_task_date.get((task, "codex", latest["date"]))
        codex_tokens = codex.get("main_tokens", {}).get("total") if codex else None
        ratio = latest_tokens / codex_tokens if isinstance(latest_tokens, (int, float)) and isinstance(codex_tokens, (int, float)) and codex_tokens else None
        ratio_text = "-" if ratio is None else f"{ratio:.2f}x"
        lines.append(
            f"{task:<17} {harness:<7} {fmt_score(latest_score):>12} {fmt_score(score_mean):>11} "
            f"{fmt_delta(score_delta):>10} {fmt_tokens(latest_tokens):>12} {fmt_tokens(token_mean):>12} "
            f"{fmt_delta(token_delta, 0):>12} {ratio_text:>9}"
        )
    if not groups:
        lines.append("No canary data yet.")
    lines.append("trend only: single-day spread is large")
    return "\n".join(lines) + "\n"


def parse_date(value):
    try:
        parsed = date.fromisoformat(value)
    except ValueError:
        fail("CANARY_TODAY must be a UTC date in YYYY-MM-DD form")
    if parsed.isoformat() != value:
        fail("CANARY_TODAY must be a UTC date in YYYY-MM-DD form")
    return parsed


def main(argv):
    if len(argv) < 2:
        fail("internal helper requires row, report or rotation")
    action = argv[1]
    if action == "row" and len(argv) == 7:
        _, _, canary_dir, run_date, host, harness, stdout_path = argv
        make_row(canary_dir, run_date, host, harness, stdout_path)
    elif action == "report" and len(argv) == 4:
        _, _, canary_dir, raw_days = argv
        try:
            days = int(raw_days)
        except ValueError:
            fail("days must be a positive integer")
        if days < 1:
            fail("days must be a positive integer")
        sys.stdout.write(report(canary_dir, days))
    elif action == "rotation" and len(argv) == 3:
        today = parse_date(argv[2])
        epoch = date(1970, 1, 1)
        print((today - epoch).days % 3)
    else:
        fail("invalid internal helper arguments")


if __name__ == "__main__":
    main(sys.argv)
