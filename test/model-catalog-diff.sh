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
            if self.headers.get("User-Agent", "").startswith("Python-urllib"):
                # The real models.dev refuses the default urllib User-Agent.
                self.send_response(403)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            models_dev = {
                "anthropic": {"models": {
                    "claude-shared": {"limit": {"context": 1000, "output": 100}, "cost": {"input": 1, "output": 2}, "deprecated": False},
                    "claude-gone": {"limit": {"context": 512}},
                    "claude-alias": {},
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
            }
            if self.mode == "anthropic-dated":
                models_dev["anthropic"]["models"].update({
                    "claude-opus-4-5": {"limit": {"context": 100}},
                    "claude-opus-4-5-20251101": {"limit": {"context": 300, "output": 30}},
                })
            elif self.mode == "dated":
                models_dev["openai"]["models"].update({
                    "dated-dash": {},
                    "dated-compact": {},
                    "dated-both": {"limit": {"context": 100}},
                    "dated-both-2026-05-04": {"limit": {"context": 300}},
                    "dated-latest": {"limit": {"context": 200}},
                    "exact-only-2026-05-04": {"limit": {"context": 100}},
                })
            elif self.mode == "dated-rename":
                models_dev["openai"]["models"].update({
                    "X": {"limit": {"context": 900}},
                    "X-2026-05-01": {"limit": {"context": 100}},
                })
            elif self.mode in ("openai-gone", "clean-no-provider"):
                models_dev["openai"]["models"].update({
                    "account-hidden-a": {},
                    "account-hidden-b": {},
                })
            elif self.mode == "gemini-filter":
                models_dev["google"]["models"].update({
                    "gemini-audio": {"limit": {"context": 100}, "modalities": {"output": ["audio"]}},
                    "gemini-image": {"limit": {"context": 100}, "modalities": {"output": ["text", "image"]}, "tool_call": False},
                    "gemini-tools": {"limit": {"context": 100}, "modalities": {"output": ["text"]}, "tool_call": True},
                    "gemini-unclassified": {"limit": {"context": 100}},
                })
            elif self.mode == "pricing":
                models_dev["openrouter"]["models"].update({
                    "router-window": {"cost": {"input": 0.4, "output": 0.5}},
                    "router-mismatch": {"cost": {"input": 0.6, "output": 0.7}},
                    "router-tier": {"cost": {"input": 0.4, "output": 0.5}},
                    "deepseek/deepseek-v4.1-flash-1017": {"cost": {"input": 0.3, "output": 1.2}},
                    "deepseek-weekend-only": {"cost": {"input": 0.15, "output": 0.6}},
                    "qwen/qwen3.5-9b": {"cost": {"input": 0.049, "output": 0.072}},
                })
            if self.mode in ("provider-absent", "clean-no-provider"):
                del models_dev["muse"]
            elif self.mode == "provider-empty":
                models_dev["muse"] = {"models": {}}
            send_json(self, models_dev)
        elif path == "/anthropic/v1/models":
            if self.mode == "anthropic-dated":
                send_json(self, {"data": [
                    {"id": "claude-opus-4-5-20251101", "context_window": 200, "max_tokens": 20},
                ]})
            elif self.mode in ("clean", "clean-no-provider"):
                send_json(self, {"data": [
                    {"id": "claude-shared", "context_window": 1000, "max_tokens": 100, "input_price": 1, "output_price": 2, "deprecated": False},
                    {"id": "claude-gone", "context_window": 512},
                    {"id": "claude-alias"},
                ]})
            else:
                send_json(self, {"data": [
                    {"id": "claude-shared", "context_window": 1200, "max_tokens": 99, "input_price": 1.5, "output_price": 2.5, "deprecated": True},
                    {"id": "claude-extra", "context_window": 256},
                    {"id": "claude-alias-20260504"},
                ]})
        elif path == "/openai/v1/models":
            if self.mode == "dated":
                send_json(self, {"data": [
                    {"id": "dated-dash-2026-05-04"},
                    {"id": "dated-compact-20260504"},
                    {"id": "dated-both", "context_window": 100},
                    {"id": "dated-both-2026-05-04", "context_window": 200},
                    # Newest comes first to make selection independent of catalog order.
                    {"id": "dated-latest-20260504", "context_window": 200},
                    {"id": "dated-latest-2026-05-03", "context_window": 100},
                    {"id": "exact-only-2026-05-04", "context_window": 200},
                    {"id": "chat-latest"},
                ]})
            elif self.mode == "dated-rename":
                send_json(self, {"data": [
                    {"id": "X-2026-05-01", "context_window": 200},
                    {"id": "X-2026-05-02", "context_window": 300},
                ]})
            elif "after=page-one" in self.path:
                send_json(self, {"data": [{"id": "openai-b"}, {"id": "codex-one"}, {"id": "text-embedding-3-small"}], "has_more": False})
            else:
                send_json(self, {"data": [{"id": "openai-a"}], "has_more": True, "last_id": "page-one"})
        elif path == "/gemini/v1beta/models":
            if self.mode == "gemini-filter":
                send_json(self, {"models": [
                    {"name": "models/gemini-one", "supportedGenerationMethods": ["generateContent"]},
                    {"name": "models/gemini-audio", "supportedGenerationMethods": ["generateContent"], "inputTokenLimit": 200},
                    {"name": "models/gemini-image", "supportedGenerationMethods": ["generateContent"], "inputTokenLimit": 200},
                    {"name": "models/gemini-tools", "supportedGenerationMethods": ["generateContent"], "inputTokenLimit": 200},
                    {"name": "models/gemini-unclassified", "supportedGenerationMethods": ["generateContent"], "inputTokenLimit": 200},
                    {"name": "models/gemini-unlisted", "supportedGenerationMethods": ["generateContent"]},
                ]})
            else:
                send_json(self, {"models": [{"name": "models/gemini-one", "supportedGenerationMethods": ["generateContent"]}, {"name": "models/gemini-embed", "supportedGenerationMethods": ["embedContent"]}]})
        elif path == "/codex/backend-api/codex/models":
            if "client_version" not in self.path:
                send_json(self, {"error": "client_version required"}, status=400)
            elif self.mode in ("clean", "clean-no-provider"):
                send_json(self, {"models": [{"slug": "codex-one", "context_window": 1000}, {"slug": "openai-a"}, {"slug": "openai-b"}]})
            else:
                send_json(self, {"models": [{"slug": "codex-one", "context_window": 900}, {"slug": "codex-extra"}]})
        elif path == "/openrouter/api/v1/models":
            if self.mode == "gaps":
                send_json(self, {"error": "not authorized"}, status=401)
            elif self.mode == "variants":
                send_json(self, {"data": [{"id": "x:batch"}, {"id": "plain-unknown"}]})
            elif self.mode == "pricing":
                send_json(self, {"data": [
                    {"id": "router-one", "pricing": {"prompt": "0.00000015", "completion": "0.00000025"}},
                    {"id": "router-window", "pricing": {
                        "prompt": "0.0000001", "completion": "0.0000002",
                        "overrides": [
                            {"utc_start": "00:00", "utc_end": "12:00", "prompt": "0.00000045", "completion": "0.00000055"},
                            {"utc_start": "12:00", "utc_end": "24:00", "prompt": "0.0000004", "completion": "0.0000005"},
                        ],
                    }},
                    {"id": "deepseek/deepseek-v4.1-flash-1017", "pricing": {
                        "prompt": "0.00000015", "completion": "0.0000006",
                        "overrides": [
                            {"utc_days": ["saturday", "sunday"], "prompt": "0.00000015", "completion": "0.0000006"},
                            {"utc_days": ["monday", "tuesday", "wednesday", "thursday", "friday"], "utc_start": 100, "utc_end": 400, "prompt": "0.0000003", "completion": "0.0000012"},
                        ],
                    }},
                    {"id": "deepseek-weekend-only", "pricing": {
                        "prompt": "0.0000003", "completion": "0.0000012",
                        "overrides": [
                            {"utc_days": ["saturday", "sunday"], "prompt": "0.00000015", "completion": "0.0000006"},
                        ],
                    }},
                    {"id": "qwen/qwen3.5-9b", "pricing": {"prompt": "0.000000041", "completion": "0.000000061"}},
                    {"id": "router-mismatch", "pricing": {"prompt": "0.0000001", "completion": "0.0000002"}},
                    {"id": "router-tier", "pricing": {
                        "prompt": "0.0000001", "completion": "0.0000002",
                        "overrides": [{"min_prompt_tokens": 100000, "prompt": "0.0000004", "completion": "0.0000005"}],
                    }},
                ]})
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

    # OpenAI models absent from this account's /models listing are summarized by count.
    openai_gone_inbox = temp_root / "inbox-openai-gone"
    openai_gone_result, _ = run_case("openai-gone", True, openai_gone_inbox, mode="openai-gone")
    expect(openai_gone_result.returncode == 0, f"openai-gone run failed: {openai_gone_result.stderr}")
    openai_gone_report = (openai_gone_inbox / "model-catalog-2026-05-04.md").read_text(encoding="utf-8")
    expect("2 models.dev models not listed for this account (per-account visibility)" in openai_gone_report, "OpenAI per-account visibility note missing")
    for hidden in ("account-hidden-a", "account-hidden-b"):
        expect(f"| {hidden} | gone |" not in openai_gone_report, f"OpenAI per-model gone row remained for {hidden}")
    expect("| claude-gone | gone |" in openai_gone_report, "non-OpenAI gone row was suppressed")

    expect("| claude-alias |" not in report, "dated Anthropic alias produced a row")
    expect("openrouter: HTTP 401" in report, "401 skip missing")
    expect("muse: no credential" in report, "missing credential skip missing")

    # An absent models.dev provider is a provider note, while an existing provider
    # with an empty catalog retains per-model missing rows.
    provider_absent_inbox = temp_root / "inbox-provider-absent"
    provider_absent_result, _ = run_case("provider-absent", True, provider_absent_inbox, mode="provider-absent")
    expect(provider_absent_result.returncode == 0, f"provider-absent run failed: {provider_absent_result.stderr}")
    provider_absent_report = (provider_absent_inbox / "model-catalog-2026-05-04.md").read_text(encoding="utf-8")
    expect("models.dev carries no muse provider" in provider_absent_report, "absent provider note missing")
    expect("| muse-one | missing |" not in provider_absent_report, "absent provider produced per-model missing row")

    provider_empty_inbox = temp_root / "inbox-provider-empty"
    provider_empty_result, _ = run_case("provider-empty", True, provider_empty_inbox, mode="provider-empty")
    expect(provider_empty_result.returncode == 0, f"provider-empty run failed: {provider_empty_result.stderr}")
    provider_empty_report = (provider_empty_inbox / "model-catalog-2026-05-04.md").read_text(encoding="utf-8")
    expect("models.dev carries no muse provider" not in provider_empty_report, "present empty provider was treated as absent")
    expect("| muse-one | missing |" in provider_empty_report, "present empty provider did not retain missing rows")

    # Provider-level notes alone do not create a report.
    clean_no_provider_inbox = temp_root / "inbox-clean-no-provider"
    clean_no_provider_result, _ = run_case("clean-no-provider", True, clean_no_provider_inbox, mode="clean-no-provider")
    expect(clean_no_provider_result.returncode == 0, f"clean-no-provider run failed: {clean_no_provider_result.stderr}")
    expect(clean_no_provider_result.stdout == "" and clean_no_provider_result.stderr == "", "note-only run was not quiet")
    expect(not clean_no_provider_inbox.exists(), "provider note alone wrote a report")

    expect("| codex-extra | missing |" in report, "codex missing row was not reported")
    expect("| codex-one | mismatch | context | 900 | 1000 |" in report, "codex context mismatch missing")
    expect("| openai-a | gone |" not in report and "| openai-b | gone |" not in report, "codex gone noise was reported")
    for identifier in ("text-embedding-3-small", "gemini-embed", "db-embed"):
        expect(identifier not in report, f"non-chat model {identifier} was not filtered")

    # Gemini exposes neither output modalities nor tool-call support on models.list.
    # Use models.dev to omit known non-text/non-tool-capable models, while retaining
    # models with usable or unknown reference fields and models missing from models.dev.
    gemini_filter_inbox = temp_root / "inbox-gemini-filter"
    gemini_filter_result, _ = run_case("gemini-filter", True, gemini_filter_inbox, mode="gemini-filter")
    expect(gemini_filter_result.returncode == 0, f"gemini-filter run failed: {gemini_filter_result.stderr}")
    gemini_filter_report = (gemini_filter_inbox / "model-catalog-2026-05-04.md").read_text(encoding="utf-8")
    expect("| gemini-audio |" not in gemini_filter_report, "audio-only Gemini model produced a row")
    expect("| gemini-image |" not in gemini_filter_report, "non-tool-capable Gemini image model produced a row")
    expect("| gemini-tools | mismatch | context | 200 | 100 |" in gemini_filter_report, "text Gemini model with tool calls was not diffed")
    expect("| gemini-unclassified | mismatch | context | 200 | 100 |" in gemini_filter_report, "Gemini model without modality/tool-call fields was not diffed")
    expect("| gemini-unlisted | missing |" in gemini_filter_report, "unlisted Gemini model did not retain its missing row")

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

    # OpenRouter variants are not catalog models, while ordinary unknown IDs remain visible.
    variants_inbox = temp_root / "inbox-variants"
    variants_result, _ = run_case("variants", True, variants_inbox, mode="variants")
    expect(variants_result.returncode == 0, f"variants run failed: {variants_result.stderr}")
    variants_report = (variants_inbox / "model-catalog-2026-05-04.md").read_text(encoding="utf-8")
    expect("| x:batch |" not in variants_report, "OpenRouter variant was reported")
    expect("| plain-unknown | missing |" in variants_report, "plain unknown OpenRouter ID was not reported")

    # Date-stamped IDs match an undated catalog entry for any vendor, but exact dated
    # entries still compare when the undated model is absent.
    dated_inbox = temp_root / "inbox-dated"
    dated_result, _ = run_case("dated", True, dated_inbox, mode="dated")
    expect(dated_result.returncode == 0, f"dated run failed: {dated_result.stderr}")
    dated_report = (dated_inbox / "model-catalog-2026-05-04.md").read_text(encoding="utf-8")
    expect("| dated-dash-2026-05-04 |" not in dated_report, "dashed date alias produced a row")
    expect("| dated-dash |" not in dated_report, "dashed date alias left its undated base gone")
    expect("| dated-compact-20260504 |" not in dated_report, "compact date alias produced a row")
    expect("| dated-compact |" not in dated_report, "compact date alias left its undated base gone")
    expect("| dated-both-2026-05-04 | mismatch | context | 200 | 300 |" in dated_report, "exact dated model alongside its base was not compared")
    expect("| dated-latest |" not in dated_report, "latest dated model was not selected deterministically")
    expect("| exact-only-2026-05-04 | mismatch | context | 200 | 100 |" in dated_report, "exact dated model was not compared normally")
    expect("| chat-latest | missing |" in dated_report, "undated unknown OpenAI ID was not reported missing")

    # A newer dated vendor ID must not be renamed onto a base when another dated
    # vendor ID exactly matches the reference.
    dated_rename_inbox = temp_root / "inbox-dated-rename"
    dated_rename_result, _ = run_case("dated-rename", True, dated_rename_inbox, mode="dated-rename")
    expect(dated_rename_result.returncode == 0, f"dated-rename run failed: {dated_rename_result.stderr}")
    dated_rename_report = (dated_rename_inbox / "model-catalog-2026-05-04.md").read_text(encoding="utf-8")
    expect("| X |" not in dated_rename_report, "dated alias was renamed onto the reference base")
    expect("| X-2026-05-02 |" not in dated_rename_report, "newer dated model produced a separate row")
    expect("| X-2026-05-01 | mismatch | context | 200 | 100 |" in dated_rename_report, "exact dated model fields were not compared")

    # An exact dated Anthropic model compares normally without marking its undated
    # models.dev alias as gone.
    anthropic_dated_inbox = temp_root / "inbox-anthropic-dated"
    anthropic_dated_result, _ = run_case("anthropic-dated", True, anthropic_dated_inbox, mode="anthropic-dated")
    expect(anthropic_dated_result.returncode == 0, f"Anthropic dated run failed: {anthropic_dated_result.stderr}")
    anthropic_dated_report = (anthropic_dated_inbox / "model-catalog-2026-05-04.md").read_text(encoding="utf-8")
    expect("| claude-opus-4-5 | gone |" not in anthropic_dated_report, "undated Anthropic alias was reported gone")
    expect("| claude-opus-4-5-20251101 | mismatch | context | 200 | 300 |" in anthropic_dated_report, "exact dated Anthropic context was not compared")
    expect("| claude-opus-4-5-20251101 | mismatch | output | 20 | 30 |" in anthropic_dated_report, "exact dated Anthropic output was not compared")

    # OpenRouter prices may match a time-window override; without overrides, mismatches remain.
    pricing_inbox = temp_root / "inbox-pricing"
    pricing_result, _ = run_case("pricing", True, pricing_inbox, mode="pricing")
    expect(pricing_result.returncode == 0, f"pricing run failed: {pricing_result.stderr}")
    pricing_report = (pricing_inbox / "model-catalog-2026-05-04.md").read_text(encoding="utf-8")
    expect("| router-window |" not in pricing_report, "matching OpenRouter override price produced a row")
    expect(re.search(r"\| router-mismatch \| mismatch \| input_price \| [^|]+ \| 0\.6 \|", pricing_report), "OpenRouter price mismatch without overrides was not reported")
    expect(re.search(r"\| router-tier \| mismatch \| input_price \| [^|]+ \| 0\.4 \|", pricing_report), "long-context tier price was treated as an alternative price")
    expect("| deepseek/deepseek-v4.1-flash-1017 |" not in pricing_report, "deepseek's real weekday/weekend override prices produced a row")
    expect("| deepseek-weekend-only |" not in pricing_report, "weekend-only override price was not treated as an alternative")
    expect(re.search(r"\| qwen/qwen3\.5-9b \| mismatch \| input_price \| [^|]+ \| 0\.049 \|", pricing_report), "qwen price drift without overrides was suppressed")

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
