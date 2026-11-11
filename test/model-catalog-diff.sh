#!/usr/bin/env bash
# Tests for bin/model-catalog-diff with local-only vendor API fixtures.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="$ROOT/bin/model-catalog-diff"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-model-catalog-diff.XXXXXX")"
trap 'rm -rf "$T"' EXIT

python3 -I - "$BIN" "$T" "$ROOT" <<'PY'
import json
import os
import re
import runpy
import socket
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

binary, temp_root, repo = map(Path, sys.argv[1:])
temp_root.mkdir(parents=True, exist_ok=True)
specs = {spec["name"]: spec for spec in runpy.run_path(str(repo / "bin/lib/model-catalog-diff.py"))["VENDORS"]}
expected_hosts = {
    "anthropic": "api.anthropic.com",
    "openai": "api.openai.com",
    "gemini": "generativelanguage.googleapis.com",
    "codex": "chatgpt.com",
    "openrouter": "openrouter.ai",
    "muse": "api.meta.ai",
}
expected_credentials = {
    "anthropic": "ANTHROPIC_API_KEY",
    "openai": "OPENAI_API_KEY",
    "gemini": "GEMINI_API_KEY",
    "openrouter": "OPENROUTER_API_KEY",
    "muse": "MUSE_API_KEY",
}
for name, host in expected_hosts.items():
    actual_host = specs[name]["base"].split("://", 1)[1].split("/", 1)[0]
    if actual_host != host:
        raise AssertionError(f"{name} credential default host changed: {actual_host}")
    if name in expected_credentials and specs[name].get("credential") != expected_credentials[name]:
        raise AssertionError(f"{name} credential was assigned to the wrong default host")
if not specs["codex"].get("auth_file") or specs["databricks"].get("credential") != "DATABRICKS_TOKEN":
    raise AssertionError("Codex and Databricks credential sources changed")
if specs["databricks"]["base"] != "" or specs["databricks"]["host_credential"] != "DATABRICKS_HOST":
    raise AssertionError("Databricks credential host must come from DATABRICKS_HOST")
secrets = {
    "ANTHROPIC_API_KEY": "fake-anthropic-KEY-1595",
    "OPENAI_API_KEY": "fake-openai-KEY-1595",
    "GEMINI_API_KEY": "fake-gemini-KEY-1595",
    "OPENROUTER_API_KEY": "fake-openrouter-KEY-1595",
    "DATABRICKS_TOKEN": "fake-databricks-KEY-1595",
    "DATABRICKS_HOST": "http://fixture.invalid",
    "MUSE_API_KEY": "fake-muse-KEY-1595",
}
requests = []


def send_json(handler, payload, status=200):
    body = json.dumps(payload).encode()
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


class FixtureHandler(BaseHTTPRequestHandler):
    mode = "gaps"

    def log_message(self, *_args):
        pass

    def do_GET(self):
        requests.append((self.path, dict(self.headers)))
        path = self.path.split("?", 1)[0]
        if path == "/modelsdev/api.json":
            send_json(self, {
                "anthropic": {"models": {
                    "claude-shared": {"limit": {"context": 1000, "output": 100}, "cost": {"input": 1, "output": 2}, "deprecated": False},
                    "claude-gone": {"limit": {"context": 512}},
                }},
                "openai": {"models": {
                    "openai-a": {"limit": {"context": 2048}},
                    "openai-b": {"limit": {"context": 4096}},
                    "codex-one": {"limit": {"context": 1000}},
                    "text-embedding-3-small": {},
                }},
                "google": {"models": {"gemini-one": {}, "gemini-embed": {}}},
                "openrouter": {"models": {"router-one": {"cost": {"input": 0.15, "output": 0.25}}}},
                "databricks": {"models": {"db-one": {}, "db-embed": {}}},
                "muse": {"models": {"muse-one": {}}},
            })
        elif path == "/anthropic/v1/models":
            if self.mode == "clean":
                send_json(self, {"data": [
                    {"id": "claude-shared", "context_window": 1000, "max_tokens": 100, "input_price": 1, "output_price": 2, "deprecated": False},
                    {"id": "claude-gone", "context_window": 512},
                ]})
            else:
                send_json(self, {"data": [
                    {"id": "claude-shared", "context_window": 1200, "max_tokens": 99, "input_price": 1.5, "output_price": 2.5, "deprecated": True},
                    {"id": "claude-extra", "context_window": 256},
                ]})
        elif path == "/openai/v1/models":
            if "after=page-one" in self.path:
                send_json(self, {"data": [{"id": "openai-b"}, {"id": "codex-one"}, {"id": "text-embedding-3-small"}], "has_more": False})
            else:
                send_json(self, {"data": [{"id": "openai-a"}], "has_more": True, "last_id": "page-one"})
        elif path == "/gemini/v1beta/models":
            send_json(self, {"models": [{"name": "models/gemini-one", "supportedGenerationMethods": ["generateContent"]}, {"name": "models/gemini-embed", "supportedGenerationMethods": ["embedContent"]}]})
        elif path == "/codex/backend-api/codex/models":
            if "client_version" not in self.path:
                send_json(self, {"error": "client_version required"}, status=400)
            elif self.mode == "clean":
                send_json(self, {"models": [{"slug": "codex-one", "context_window": 1000}, {"slug": "openai-a"}, {"slug": "openai-b"}]})
            else:
                send_json(self, {"models": [{"slug": "codex-one", "context_window": 900}, {"slug": "codex-extra"}]})
        elif path == "/openrouter/api/v1/models":
            if self.mode == "gaps":
                send_json(self, {"error": "not authorized"}, status=401)
            else:
                send_json(self, {"data": [{"id": "router-one", "pricing": {"prompt": "0.00000015000000000000002", "completion": "0.00000025"}}]})
        elif path == "/databricks/api/2.0/serving-endpoints":
            send_json(self, {"endpoints": [{"name": "db-one", "task": "llm/v1/chat"}, {"name": "db-embed", "task": "llm/v1/embeddings"}]})
        elif path == "/muse/v1/models":
            send_json(self, {"data": [{"id": "muse-one"}]})
        elif path == "/muse-redirect/v1/models":
            self.send_response(302)
            self.send_header("Location", f"{sink_base}/muse/v1/models")
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            send_json(self, {"error": "unknown fixture route"}, status=404)


server = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
base = f"http://127.0.0.1:{server.server_port}"

# A second server stands in for wherever a vendor's 30x points; it must never see a request.
sink_requests = []


class SinkHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        sink_requests.append((self.path, dict(self.headers)))
        send_json(self, {"data": [{"id": "muse-one"}]})


sink = ThreadingHTTPServer(("127.0.0.1", 0), SinkHandler)
threading.Thread(target=sink.serve_forever, daemon=True).start()
sink_base = f"http://127.0.0.1:{sink.server_port}"


def write_credentials(include_muse):
    path = temp_root / "model-catalog.env"
    values = {key: value for key, value in secrets.items() if include_muse or key != "MUSE_API_KEY"}
    path.write_text("".join(f"{key}={value}\n" for key, value in values.items()), encoding="utf-8")
    path.chmod(0o600)
    return path


def run_case(label, include_muse, inbox, mode="gaps", muse_base=None, env_file=None, codex_version=None):
    FixtureHandler.mode = mode
    env_path = env_file or write_credentials(include_muse)
    auth_dir = temp_root / "home" / ".codex"
    auth_dir.mkdir(parents=True, exist_ok=True)
    (auth_dir / "auth.json").write_text(json.dumps({"tokens": {"access_token": "fake-codex-KEY-1595"}}), encoding="utf-8")
    env = os.environ.copy()
    env.update({
        "HOME": str(temp_root / "home"),
        "MODEL_CATALOG_ENV": str(env_path),
        "MODEL_CATALOG_INBOX": str(inbox),
        "MODEL_CATALOG_TODAY": "2026-05-04",
        "MODEL_CATALOG_TIMEOUT": "1",
        "MODEL_CATALOG_MODELS_DEV_BASE": f"{base}/modelsdev",
        "MODEL_CATALOG_ANTHROPIC_BASE": f"{base}/anthropic",
        "MODEL_CATALOG_OPENAI_BASE": f"{base}/openai",
        "MODEL_CATALOG_GEMINI_BASE": f"{base}/gemini",
        "MODEL_CATALOG_CODEX_BASE": f"{base}/codex",
        "MODEL_CATALOG_OPENROUTER_BASE": f"{base}/openrouter",
        "MODEL_CATALOG_DATABRICKS_BASE": f"{base}/databricks",
        "MODEL_CATALOG_MUSE_BASE": muse_base or f"{base}/muse",
    })
    env.pop("MODEL_CATALOG_CODEX_CLIENT_VERSION", None)
    if codex_version is not None:
        env["MODEL_CATALOG_CODEX_CLIENT_VERSION"] = codex_version
    result = subprocess.run(["bash", str(binary), "run"], env=env, text=True, capture_output=True, check=False)
    return result, env


def expect(condition, message):
    if not condition:
        raise AssertionError(message)


def assert_no_secrets(*texts):
    combined = "\n".join(texts)
    for secret in list(secrets.values()) + ["fake-codex-KEY-1595"]:
        expect(secret not in combined, f"credential appeared in output: {secret}")
    expect("Authorization" not in combined, "Authorization header text appeared in output")
    expect(not re.search(r"[?&](?:key|api_key|token)=", combined, re.I), "key-bearing query URL appeared in output")

try:
    # A vendor without a credential and an HTTP 401 both become skipped entries;
    # the other APIs still produce missing, mismatch and gone rows.
    inbox = temp_root / "inbox-gaps"
    result, _ = run_case("gaps", False, inbox)
    expect(result.returncode == 0, f"run failed: {result.stderr}")
    report_path = inbox / "model-catalog-2026-05-04.md"
    expect(report_path.is_file(), "catalog report was not written")
    report = report_path.read_text(encoding="utf-8")
    expect("# Model catalog gaps 2026-05-04" in report, "report heading missing")
    expect("source: model-catalog-diff " in report, "source line missing")
    expect(re.search(r"source: model-catalog-diff [0-9a-f]{4,40}$", report, re.M), "source SHA missing")
    expect("| model | kind | field | vendor | models.dev |" in report, "table format missing")
    expect("| claude-extra | missing |" in report, "missing row not reported")
    expect("| claude-shared | mismatch | context | 1200 | 1000 |" in report, "context mismatch missing")
    for field, vendor_value, reference_value in (("output", "99", "100"), ("input_price", "1.5", "1"), ("output_price", "2.5", "2"), ("deprecated", "True", "False")):
        expect(f"| claude-shared | mismatch | {field} | {vendor_value} | {reference_value} |" in report, f"{field} mismatch missing")
    expect("| claude-gone | gone |" in report, "gone row missing")
    expect("openrouter: HTTP 401" in report, "401 skip missing")
    expect("muse: no credential" in report, "missing credential skip missing")
    expect("| codex-extra | missing |" in report, "codex missing row was not reported")
    expect("| codex-one | mismatch | context | 900 | 1000 |" in report, "codex context mismatch missing")
    expect("| openai-a | gone |" not in report and "| openai-b | gone |" not in report, "codex gone noise was reported")
    for identifier in ("text-embedding-3-small", "gemini-embed", "db-embed"):
        expect(identifier not in report, f"non-chat model {identifier} was not filtered")
    expect("## skipped" in report, "skipped section missing")
    expect(not list(inbox.glob("*.tmp")) and not list(inbox.glob(".model-catalog-*.tmp")), "temporary report file was left behind")
    assert_no_secrets(report, result.stdout, result.stderr)
    expect(any("after=page-one" in path for path, _headers in requests), "openai pagination was not followed")
    gemini_request = next(headers for path, headers in requests if path.startswith("/gemini/"))
    expect(any(key.lower() == "x-goog-api-key" and value == secrets["GEMINI_API_KEY"] for key, value in gemini_request.items()), "Gemini credential was not sent as a header")
    codex_request = next(path for path, _headers in requests if path.startswith("/codex/"))
    expect("client_version=0.1.0" in codex_request, "Codex default client_version query parameter missing")

    # A sibling ignore file pins a known Codex context mismatch without suppressing other rows.
    pinned_env = write_credentials(True)
    (pinned_env.parent / "ignore").write_text("# vendor model field\ncodex codex-one context # known API pin\n", encoding="utf-8")
    pinned_inbox = temp_root / "inbox-pinned"
    pinned_result, _ = run_case("pinned", True, pinned_inbox, env_file=pinned_env, codex_version="fixture-codex-version")
    expect(pinned_result.returncode == 0, f"pinned run failed: {pinned_result.stderr}")
    pinned_report = (pinned_inbox / "model-catalog-2026-05-04.md").read_text(encoding="utf-8")
    expect("| codex-one | mismatch | context |" not in pinned_report, "ignore pin did not suppress Codex context mismatch")
    expect("| codex-extra | missing |" in pinned_report, "ignore pin suppressed an unrelated Codex row")
    expect(any("client_version=fixture-codex-version" in path for path, _headers in requests), "Codex client_version override was ignored")

    # Connection-refused behavior is exercised against a closed localhost port.
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    closed_port = probe.getsockname()[1]
    probe.close()
    refused_inbox = temp_root / "inbox-refused"
    result, _ = run_case("refused", True, refused_inbox, muse_base=f"http://127.0.0.1:{closed_port}/muse")
    expect(result.returncode == 0, f"connection-refused run failed: {result.stderr}")
    refused_report = (refused_inbox / "model-catalog-2026-05-04.md").read_text(encoding="utf-8")
    expect("muse: connection refused" in refused_report, "connection-refused skip missing")
    assert_no_secrets(refused_report, result.stdout, result.stderr)

    # A 30x is refused, not followed, so a credential header never reaches the redirect target.
    redirect_inbox = temp_root / "inbox-redirect"
    result, _ = run_case("redirect", True, redirect_inbox, mode="clean", muse_base=f"{base}/muse-redirect")
    expect(result.returncode == 0, f"redirect run failed: {result.stderr}")
    redirect_report = (redirect_inbox / "model-catalog-2026-05-04.md").read_text(encoding="utf-8")
    expect("muse: redirect" in redirect_report, "redirect skip missing")
    expect(not any(secrets["MUSE_API_KEY"] in str(headers) for _, headers in sink_requests), "redirect target received the muse credential")
    expect(not sink_requests, "redirect was followed")
    assert_no_secrets(redirect_report, result.stdout, result.stderr)

    # With no differences and every endpoint checked, a run is quiet and writes nothing.
    clean_inbox = temp_root / "inbox-clean"
    clean_result, _ = run_case("clean", True, clean_inbox, mode="clean")
    expect(clean_result.returncode == 0, f"clean run failed: {clean_result.stderr}")
    expect(clean_result.stdout == "" and clean_result.stderr == "", "clean run was not quiet")
    expect(not clean_inbox.exists(), "clean run wrote an empty report")
    assert_no_secrets(clean_result.stdout, clean_result.stderr)

    # A mode wider than 0600 is refused without exposing file contents.
    wide = write_credentials(True)
    wide.chmod(0o644)
    wide_inbox = temp_root / "inbox-wide"
    wide_result, _ = run_case("wide", True, wide_inbox, env_file=wide)
    expect(wide_result.returncode != 0, "wide credential mode was accepted")
    expect("wider than 0600" in wide_result.stderr, "wide mode refusal missing")
    expect(not wide_inbox.exists(), "wide credential file produced a report")
    assert_no_secrets(wide_result.stdout, wide_result.stderr)

    # CLI argument and systemd timer behavior match canary-daily.
    usage = subprocess.run(["bash", str(binary), "unknown"], text=True, capture_output=True, check=False)
    expect(usage.returncode == 2 and "usage:" in usage.stderr, "invalid command handling changed")
    install_env = os.environ.copy()
    install_env["HOME"] = str(temp_root / "install-home")
    install_env["XDG_CONFIG_HOME"] = str(temp_root / "install-config")
    printed = subprocess.run(["bash", str(binary), "install", "--print", "--at", "07:45"], env=install_env, text=True, capture_output=True, check=False)
    expect(printed.returncode == 0, f"install --print failed: {printed.stderr}")
    for value in ("model-catalog-diff.service", "model-catalog-diff.timer", "Type=oneshot", "OnCalendar=*-*-* 07:45:00 UTC", "systemctl --user enable --now model-catalog-diff.timer"):
        expect(value in printed.stdout, f"install output missing {value}")
    expect(not (temp_root / "install-config").exists(), "install --print wrote files")
    invalid_time = subprocess.run(["bash", str(binary), "install", "--print", "--at", "25:00"], text=True, capture_output=True, check=False)
    expect(invalid_time.returncode == 2, "invalid install time was accepted")
    default_print = subprocess.run(["bash", str(binary), "install", "--print"], env=install_env, text=True, capture_output=True, check=False)
    expect(default_print.returncode == 0 and "OnCalendar=*-*-* 08:30:00 UTC" in default_print.stdout, "default daily timer is not 08:30")
    assert_no_secrets(usage.stdout, usage.stderr, printed.stdout, printed.stderr, default_print.stdout, default_print.stderr, invalid_time.stdout, invalid_time.stderr)
finally:
    server.shutdown()
    sink.shutdown()
    server.server_close()
    thread.join(timeout=2)

print("model-catalog-diff: all cases passed")
PY
