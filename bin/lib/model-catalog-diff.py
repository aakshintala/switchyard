#!/usr/bin/env python3
"""Fetch vendor model catalogs and report gaps against models.dev."""

import errno
import json
import math
import os
import re
import socket
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timezone
from pathlib import Path

INBOX_DEFAULT = "/srv/lanes/fiber-worktrees/surveyor/run/inbox"
ENV_DEFAULT = ".config/model-catalog/env"
AUTH_DEFAULT = ".codex/auth.json"
PAGE_LIMIT = 100
CODEX_CLIENT_VERSION = "0.1.0"
OPENAI_NON_CHAT = re.compile(r"embedding|tts|whisper|dall-e|moderation|transcribe|image|realtime|audio|search", re.I)
VENDORS = (
    {
        "name": "anthropic",
        "base_env": "MODEL_CATALOG_ANTHROPIC_BASE",
        "base": "https://api.anthropic.com",
        "path": "v1/models",
        "credential": "ANTHROPIC_API_KEY",
        "header": "x-api-key",
        "pagination": "after_id",
        "provider": "anthropic",
    },
    {
        "name": "openai",
        "base_env": "MODEL_CATALOG_OPENAI_BASE",
        "base": "https://api.openai.com",
        "path": "v1/models",
        "credential": "OPENAI_API_KEY",
        "header": "Authorization",
        "bearer": True,
        "pagination": "after",
        "provider": "openai",
    },
    {
        "name": "gemini",
        "base_env": "MODEL_CATALOG_GEMINI_BASE",
        "base": "https://generativelanguage.googleapis.com",
        "path": "v1beta/models",
        "credential": "GEMINI_API_KEY",
        "header": "x-goog-api-key",
        "pagination": "pageToken",
        "provider": "google",
    },
    {
        "name": "codex",
        "base_env": "MODEL_CATALOG_CODEX_BASE",
        "base": "https://chatgpt.com",
        "path": "backend-api/codex/models",
        "auth_file": True,
        "header": "Authorization",
        "bearer": True,
        "pagination": "page",
        "provider": "openai",
    },
    {
        "name": "openrouter",
        "base_env": "MODEL_CATALOG_OPENROUTER_BASE",
        "base": "https://openrouter.ai",
        "path": "api/v1/models",
        "credential": "OPENROUTER_API_KEY",
        "header": "Authorization",
        "bearer": True,
        "pagination": "page",
        "provider": "openrouter",
    },
    {
        "name": "databricks",
        "base_env": "MODEL_CATALOG_DATABRICKS_BASE",
        "base": "",
        "path": "api/2.0/serving-endpoints",
        "credential": "DATABRICKS_TOKEN",
        "host_credential": "DATABRICKS_HOST",
        "header": "Authorization",
        "bearer": True,
        "pagination": "page_token",
        "provider": "databricks",
    },
    {
        "name": "muse",
        "base_env": "MODEL_CATALOG_MUSE_BASE",
        "base": "https://api.meta.ai",
        "path": "v1/models",
        "credential": "MUSE_API_KEY",
        "header": "Authorization",
        "bearer": True,
        "pagination": "after",
        "provider": "muse",
    },
)
FIELD_NAMES = ("context", "output", "input_price", "output_price", "deprecated")


class FetchFailure(Exception):
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def fail(message):
    print(f"model-catalog-diff: {message}", file=sys.stderr)
    raise SystemExit(1)


def credential_file():
    override = os.environ.get("MODEL_CATALOG_ENV")
    if override:
        return Path(override).expanduser()
    return Path.home() / ENV_DEFAULT


def read_credentials():
    path = credential_file()
    if not path.exists():
        return {}
    try:
        mode = stat.S_IMODE(path.stat().st_mode)
        if mode & ~0o600:
            fail("credential env file permissions are wider than 0600")
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        fail("cannot read credential env file")
    credentials = {}
    for number, line in enumerate(lines, 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key.strip()):
            fail(f"invalid credential env file line {number}")
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        credentials[key] = value
    return credentials


def read_ignore_pins():
    path = credential_file().parent / "ignore"
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return set()
    except OSError:
        fail("cannot read model catalog ignore file")
    vendors = {spec["name"] for spec in VENDORS}
    pins = set()
    for number, line in enumerate(lines, 1):
        fields = line.split("#", 1)[0].split()
        if not fields:
            continue
        if len(fields) != 3 or fields[0] not in vendors or fields[2] not in FIELD_NAMES:
            fail(f"invalid model catalog ignore file line {number}")
        pins.add(tuple(fields))
    return pins


def read_codex_token():
    path = Path.home() / AUTH_DEFAULT
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError):
        return None
    tokens = payload.get("tokens") if isinstance(payload, dict) else None
    token = tokens.get("access_token") if isinstance(tokens, dict) else None
    return token if isinstance(token, str) and token else None


def clean_url(base, path):
    return urllib.parse.urljoin(base.rstrip("/") + "/", path.lstrip("/"))


class RefuseRedirect(urllib.request.HTTPRedirectHandler):
    # urllib copies credential headers onto a redirect, even across hosts, so refuse every 30x.
    def redirect_request(self, *_args):
        raise FetchFailure("redirect")


OPENER = urllib.request.build_opener(RefuseRedirect)


def request_json(url, headers, timeout):
    request = urllib.request.Request(url, headers=headers)
    try:
        with OPENER.open(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        raise FetchFailure(f"HTTP {error.code}") from None
    except (TimeoutError, socket.timeout):
        raise FetchFailure("timeout") from None
    except urllib.error.URLError as error:
        reason = error.reason
        if isinstance(reason, OSError) and reason.errno == errno.ECONNREFUSED:
            raise FetchFailure("connection refused") from None
        if isinstance(reason, (TimeoutError, socket.timeout)):
            raise FetchFailure("timeout") from None
        raise FetchFailure("connection failed") from None
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise FetchFailure("invalid JSON") from None
    except OSError:
        raise FetchFailure("connection failed") from None


def payload_items(payload, vendor):
    if isinstance(payload, list):
        value = payload
    elif isinstance(payload, dict):
        value = None
        for key in ("data", "models", "endpoints"):
            candidate = payload.get(key)
            if isinstance(candidate, list):
                value = candidate
                break
        if value is None:
            raise FetchFailure("invalid response")
    else:
        raise FetchFailure("invalid response")

    if vendor != "databricks":
        return value
    flattened = []
    for endpoint in value:
        if not isinstance(endpoint, dict):
            continue
        name = endpoint.get("name")
        config = endpoint.get("config")
        served = config.get("served_entities") if isinstance(config, dict) else None
        if isinstance(served, list) and served:
            for entity in served:
                if isinstance(entity, dict):
                    flattened.append({**endpoint, **entity, "task": endpoint.get("task"), "id": entity.get("entity_name") or entity.get("model_name") or name})
        else:
            flattened.append({**endpoint, "id": endpoint.get("entity_name") or name})
    return flattened


def next_page(payload, vendor):
    if not isinstance(payload, dict):
        return None
    for key in ("next_page_token", "nextPageToken", "next_cursor"):
        token = payload.get(key)
        if isinstance(token, str) and token:
            return ("token", token)
    if payload.get("has_more") is True:
        token = payload.get("last_id") or payload.get("last") or payload.get("cursor")
        if isinstance(token, str) and token:
            return ("token", token)
        raise FetchFailure("invalid pagination response")
    next_url = payload.get("next")
    if isinstance(next_url, str) and next_url:
        return ("url", next_url)
    return None


def same_origin(left, right):
    first = urllib.parse.urlsplit(left)
    second = urllib.parse.urlsplit(right)
    return (first.scheme, first.hostname, first.port) == (second.scheme, second.hostname, second.port)


def fetch_vendor(spec, credentials, codex_token, timeout):
    if spec.get("auth_file"):
        secret = codex_token
    else:
        secret = credentials.get(spec["credential"])
    if not secret:
        raise FetchFailure("no credential")
    base = os.environ.get(spec["base_env"])
    if not base:
        base = credentials.get(spec.get("host_credential", ""), "") or spec["base"]
    if not base:
        raise FetchFailure("no credential")
    headers = {"Accept": "application/json", "User-Agent": "model-catalog-diff/1"}
    headers[spec["header"]] = f"Bearer {secret}" if spec.get("bearer") else secret
    if spec["name"] == "anthropic":
        headers["anthropic-version"] = "2023-06-01"
    base_url = clean_url(base, spec["path"])
    base_parts = urllib.parse.urlsplit(base_url)
    base_query = urllib.parse.parse_qsl(base_parts.query, keep_blank_values=True)
    if spec["name"] == "codex":
        client_version = os.environ.get("MODEL_CATALOG_CODEX_CLIENT_VERSION", CODEX_CLIENT_VERSION)
        if not client_version:
            raise FetchFailure("empty Codex client version")
        base_query.append(("client_version", client_version))
    url = urllib.parse.urlunsplit((base_parts.scheme, base_parts.netloc, base_parts.path, urllib.parse.urlencode(base_query), ""))
    first_origin = url
    models = []
    seen_tokens = set()
    for _ in range(PAGE_LIMIT):
        payload = request_json(url, headers, timeout)
        models.extend(payload_items(payload, spec["name"]))
        continuation = next_page(payload, spec["name"])
        if continuation is None:
            return models
        kind, value = continuation
        if kind == "url":
            next_url = urllib.parse.urljoin(url, value)
            if not same_origin(first_origin, next_url):
                raise FetchFailure("unsafe pagination response")
            url = next_url
        else:
            if value in seen_tokens or secret in value:
                raise FetchFailure("invalid pagination response")
            seen_tokens.add(value)
            parts = urllib.parse.urlsplit(clean_url(base, spec["path"]))
            query = list(base_query)
            query.append((spec["pagination"], value))
            url = urllib.parse.urlunsplit((parts.scheme, parts.netloc, parts.path, urllib.parse.urlencode(query), ""))
    raise FetchFailure("too many pages")


def model_id(model, vendor):
    if not isinstance(model, dict):
        return None
    candidates = ("id", "slug", "name", "model", "entity_name", "model_name")
    for key in candidates:
        value = model.get(key)
        if isinstance(value, str) and value:
            if vendor == "gemini" and value.startswith("models/"):
                value = value[len("models/") :]
            return value
    return None


def nested(value, *keys):
    current = value
    for key in keys:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def number(value, scale=1):
    if isinstance(value, bool) or not isinstance(value, (int, float, str)):
        return None
    try:
        result = float(value) * scale
    except (TypeError, ValueError):
        return None
    return result if result == result and abs(result) != float("inf") else None


def vendor_fields(model, vendor):
    fields = {}
    aliases = {
        "context": ("context_window", "context_length", "inputTokenLimit", "input_token_limit"),
        "output": ("max_tokens", "max_output_tokens", "outputTokenLimit", "output_token_limit"),
    }
    for field, keys in aliases.items():
        value = next((model.get(key) for key in keys if model.get(key) is not None), None)
        if value is None:
            value = nested(model, "limits", field)
        value = number(value)
        if value is not None:
            fields[field] = int(value) if value.is_integer() else value
    pricing = model.get("pricing") if isinstance(model.get("pricing"), dict) else {}
    if vendor == "openrouter":
        for field, key in (("input_price", "prompt"), ("output_price", "completion")):
            value = number(pricing.get(key), 1_000_000)
            if value is not None:
                fields[field] = value
    for field, keys in (("input_price", ("input_price",)), ("output_price", ("output_price",))):
        if field not in fields:
            value = next((model.get(key) for key in keys if model.get(key) is not None), None)
            value = number(value)
            if value is not None:
                fields[field] = value
    if "deprecated" in model and isinstance(model["deprecated"], bool):
        fields["deprecated"] = model["deprecated"]
    elif isinstance(model.get("status"), str):
        status = model["status"].lower()
        if status in ("deprecated", "retired", "active", "available"):
            fields["deprecated"] = status in ("deprecated", "retired")
    return fields


def reference_fields(model):
    fields = {}
    for field, path in (
        ("context", ("limit", "context")),
        ("output", ("limit", "output")),
        ("input_price", ("cost", "input")),
        ("output_price", ("cost", "output")),
    ):
        value = number(nested(model, *path))
        if value is not None:
            fields[field] = int(value) if value.is_integer() else value
    if isinstance(model.get("deprecated"), bool):
        fields["deprecated"] = model["deprecated"]
    elif isinstance(model.get("status"), str):
        status = model["status"].lower()
        if status in ("deprecated", "retired", "active", "available"):
            fields["deprecated"] = status in ("deprecated", "retired")
    return fields


def index_models(items, vendor):
    indexed = {}
    for item in items:
        identifier = model_id(item, vendor)
        if identifier:
            indexed[identifier] = item
    return indexed


def reference_models(payload, provider):
    if not isinstance(payload, dict):
        raise FetchFailure("invalid response")
    vendor = payload.get(provider)
    models = vendor.get("models") if isinstance(vendor, dict) else None
    if isinstance(models, dict):
        return models
    if isinstance(models, list):
        return index_models(models, provider)
    return {}


def markdown(value, secrets):
    text = str(value).replace("|", "\\|").replace("\n", " ").replace("\r", " ")
    for secret in secrets:
        if secret:
            text = text.replace(secret, "[redacted]")
    return text


def filtered_vendor_items(items, vendor):
    kept = []
    excluded = set()
    for item in items:
        identifier = model_id(item, vendor)
        if vendor == "gemini":
            methods = item.get("supportedGenerationMethods") if isinstance(item, dict) else None
            if not isinstance(methods, list) or "generateContent" not in methods:
                if identifier:
                    excluded.add(identifier)
                continue
        elif vendor == "openai" and identifier and OPENAI_NON_CHAT.search(identifier):
            excluded.add(identifier)
            continue
        elif vendor == "databricks" and (not isinstance(item, dict) or item.get("task") != "llm/v1/chat"):
            if identifier:
                excluded.add(identifier)
            continue
        kept.append(item)
    return kept, excluded


def compare_vendor(vendor_items, reference, vendor, ignore_pins=()):
    vendor_items, excluded = filtered_vendor_items(vendor_items, vendor)
    vendor_index = index_models(vendor_items, vendor)
    if vendor == "openai":
        reference = {identifier: model for identifier, model in reference.items() if not OPENAI_NON_CHAT.search(identifier)}
    else:
        reference = {identifier: model for identifier, model in reference.items() if identifier not in excluded}
    rows = []
    for identifier in sorted(set(vendor_index) | set(reference)):
        left = vendor_index.get(identifier)
        right = reference.get(identifier)
        if right is None:
            rows.append((identifier, "missing", "-", "listed", "-"))
            continue
        if left is None:
            if vendor != "codex":
                rows.append((identifier, "gone", "-", "-", "listed"))
            continue
        left_fields = vendor_fields(left, vendor)
        right_fields = reference_fields(right)
        for field in FIELD_NAMES:
            if field not in left_fields or field not in right_fields:
                continue
            if (vendor, identifier, field) in ignore_pins:
                continue
            left_value, right_value = left_fields[field], right_fields[field]
            if field in ("input_price", "output_price") and math.isclose(left_value, right_value, rel_tol=1e-6):
                continue
            if left_value != right_value:
                rows.append((identifier, "mismatch", field, left_value, right_value))
    return rows


def short_sha(script_path):
    try:
        root = Path(script_path).resolve().parent.parent
        result = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--short", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        )
        value = result.stdout.strip()
        return value if re.fullmatch(r"[0-9a-f]{4,40}", value) else "unknown"
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def write_report(inbox, today, source, rows_by_vendor, skipped, secrets):
    lines = [f"# Model catalog gaps {today}", f"source: model-catalog-diff {source}", ""]
    for vendor in VENDORS:
        rows = rows_by_vendor.get(vendor["name"], [])
        if not rows:
            continue
        lines.extend((f"## {vendor['name']}", "", "| model | kind | field | vendor | models.dev |", "|---|---|---|---|---|"))
        for identifier, kind, field, left, right in rows:
            values = (identifier, kind, field, left, right)
            lines.append("| " + " | ".join(markdown(value, secrets) for value in values) + " |")
        lines.append("")
    lines.extend(("## skipped", ""))
    for vendor, reason in skipped:
        lines.append(f"- {markdown(vendor, secrets)}: {markdown(reason, secrets)}")
    lines.append("")
    content = "\n".join(lines)
    inbox.mkdir(parents=True, exist_ok=True)
    target = inbox / f"model-catalog-{today}.md"
    fd, temporary = tempfile.mkstemp(prefix=".model-catalog-", suffix=".tmp", dir=inbox)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write(content)
        os.replace(temporary, target)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
    return target


def run(script_path):
    credentials = read_credentials()
    codex_token = read_codex_token()
    secrets = [value for value in credentials.values() if value] + ([codex_token] if codex_token else [])
    try:
        timeout = float(os.environ.get("MODEL_CATALOG_TIMEOUT", "20"))
        if timeout <= 0:
            raise ValueError
    except ValueError:
        fail("invalid MODEL_CATALOG_TIMEOUT")
    today = os.environ.get("MODEL_CATALOG_TODAY", datetime.now(timezone.utc).date().isoformat())
    try:
        date.fromisoformat(today)
    except ValueError:
        fail("invalid MODEL_CATALOG_TODAY")

    reference_payload = None
    model_dev_base = os.environ.get("MODEL_CATALOG_MODELS_DEV_BASE", "https://models.dev")
    try:
        reference_payload = request_json(clean_url(model_dev_base, "api.json"), {"Accept": "application/json"}, timeout)
    except FetchFailure as error:
        model_dev_failure = error.reason
    else:
        model_dev_failure = None

    ignore_pins = read_ignore_pins()
    skipped = []
    rows_by_vendor = {}
    for spec in VENDORS:
        try:
            items = fetch_vendor(spec, credentials, codex_token, timeout)
        except FetchFailure as error:
            skipped.append((spec["name"], error.reason))
            continue
        if model_dev_failure:
            skipped.append((spec["name"], "models.dev " + model_dev_failure))
            continue
        try:
            reference = reference_models(reference_payload, spec["provider"])
            rows = compare_vendor(items, reference, spec["name"], ignore_pins)
        except FetchFailure as error:
            skipped.append((spec["name"], error.reason))
            continue
        if rows:
            rows_by_vendor[spec["name"]] = rows

    if model_dev_failure:
        skipped.insert(0, ("models.dev", model_dev_failure))
    if not rows_by_vendor and not skipped:
        return 0
    inbox = Path(os.environ.get("MODEL_CATALOG_INBOX", INBOX_DEFAULT)).expanduser()
    target = write_report(inbox, today, short_sha(script_path), rows_by_vendor, skipped, secrets)
    print(f"model-catalog-diff: wrote {target.name}")
    return 0


def main(argv):
    if len(argv) != 3 or argv[1] != "run":
        fail("usage: model-catalog-diff.py run SCRIPT_PATH")
    return run(argv[2])


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
