#!/usr/bin/env -S python3 -S
"""A local pi RPC host fake for supervisor tests; never starts a real model."""

import json
import os
import select
import sys
import time

GO_WAIT = 30.0
NOW = int(time.time() * 1000)

FAKE_DIR = os.environ.get("FAKE_DIR", "")
SCENARIOS = {item.strip() for item in os.environ.get("FAKE_SCENARIO", "").split(",") if item.strip()}
CASSETTE = [part for part in os.environ.get("FAKE_CASSETTE", "").split(":") if part]

TURN_NUMBER = 0
PROMPT_COUNT = 0
QUEUE = []
HELD = False
HOLD_START = 0.0
RACE_PHASE = 0
RACE_TEXT = ""
SEGMENTS = []


def path(name):
    return os.path.join(FAKE_DIR, name)


def write_file(name, data):
    mode = "w"
    if isinstance(data, bytes):
        mode = "wb"
        with open(path(name), mode) as output:
            output.write(data)
        return
    with open(path(name), mode, encoding="utf-8") as output:
        output.write(data)


def send(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":"), ensure_ascii=False) + "\n")
    sys.stdout.flush()


def log_request(line):
    with open(path("requests.jsonl"), "a", encoding="utf-8") as output:
        output.write(line)


def respond(command_id, command, success=True, data=None, error=None):
    message = {"id": command_id, "type": "response", "command": command, "success": success}
    if success:
        message["data"] = data if data is not None else {}
    else:
        message["error"] = error if error is not None else "fake failure"
    send(message)


def user_frame(text):
    return {
        "type": "message_end",
        "message": {
            "role": "user",
            "content": [{"type": "text", "text": text}],
            "timestamp": NOW,
        },
    }


def assistant_frame(text, stop="stop"):
    return {
        "type": "message_end",
        "message": {
            "role": "assistant",
            "content": [{"type": "text", "text": text}],
            "stopReason": stop,
            "timestamp": NOW,
            "usage": {
                "input": 10,
                "output": 5,
                "cacheRead": 0,
                "cacheWrite": 0,
                "totalTokens": 15,
            },
        },
    }


def settle(aborted):
    send({"type": "turn_end"})
    send({"type": "agent_end", "messages": [], "willRetry": False})
    send({"type": "agent_settled", "aborted": aborted})


def full_run(text):
    send({"type": "agent_start"})
    send({"type": "turn_start"})
    send({"type": "message_start", "message": {"role": "user"}})
    send(user_frame(text))
    send({"type": "message_start", "message": {"role": "assistant"}})
    send(assistant_frame("READY"))
    settle(False)


def hold_run(text):
    global HELD, HOLD_START
    send({"type": "agent_start"})
    send({"type": "turn_start"})
    send({"type": "message_start", "message": {"role": "user"}})
    send(user_frame(text))
    send({"type": "message_start", "message": {"role": "assistant"}})
    send(assistant_frame("working", "toolUse"))
    send({"type": "tool_execution_start", "toolName": "bash", "toolCallId": "call_1"})
    send({"type": "tool_execution_update", "toolName": "bash", "toolCallId": "call_1"})
    write_file("tool.paused", "")
    HELD = True
    HOLD_START = time.monotonic()


def deliver_queue():
    send({"type": "turn_start"})
    for text in QUEUE:
        send(user_frame(text))
        with open(path("delivered.txt"), "a", encoding="utf-8") as output:
            output.write(text + "\n")
    send(assistant_frame("saw: " + ", ".join(QUEUE)))
    QUEUE.clear()
    send({"type": "turn_end"})
    send({"type": "agent_end", "messages": [], "willRetry": False})
    send({"type": "agent_settled", "aborted": False})


def finish_hold(completed):
    global HELD
    for name in ("go", "tool.paused"):
        try:
            os.remove(path(name))
        except OSError:
            pass
    HELD = False
    if completed:
        send({"type": "tool_execution_end", "toolName": "bash", "toolCallId": "call_1"})
        send({"type": "message_start", "message": {"role": "toolResult"}})
        send({"type": "message_end", "message": {"role": "toolResult"}})
        send({"type": "turn_end"})
        if QUEUE:
            deliver_queue()
            return
    else:
        send(
            {
                "type": "tool_execution_end",
                "toolName": "bash",
                "toolCallId": "call_1",
                "isError": True,
            }
        )
        send({"type": "turn_end"})
        send({"type": "agent_end", "messages": [], "willRetry": False})
        send({"type": "agent_settled", "aborted": True})


def load_cassette():
    segments = []
    for name in CASSETTE:
        with open(name, encoding="utf-8") as cassette:
            for line in cassette:
                line = line.strip()
                if not line:
                    continue
                prefix, payload = line[0], json.loads(line[2:])
                if prefix == ">":
                    segments.append({"command": payload, "outputs": []})
                elif segments:
                    segments[-1]["outputs"].append(payload)
    return segments


def cassette_mismatch(command, expected):
    write_file(
        "mismatch.txt",
        "got {} want {}\n".format(
            json.dumps(command, separators=(",", ":")),
            json.dumps(expected, separators=(",", ":")) if expected is not None else "no segment left",
        ),
    )
    respond(command.get("id"), command.get("type"), False, error="fake cassette mismatch")


def handle_cassette(command):
    if not SEGMENTS:
        cassette_mismatch(command, None)
        return
    segment = SEGMENTS.pop(0)
    want = segment["command"]
    if command.get("type") != want.get("type"):
        cassette_mismatch(command, want)
        return
    if command.get("type") == "prompt":
        if command.get("streamingBehavior") != want.get("streamingBehavior"):
            cassette_mismatch(command, want)
            return
    for output in segment["outputs"]:
        if output.get("type") == "response":
            output = dict(output)
            output["id"] = command.get("id")
        send(output)


def set_model_bad():
    fixture_dir = os.environ.get("FAKE_FIXTURE_DIR", "")
    with open(os.path.join(fixture_dir, "set-model-bad.jsonl"), encoding="utf-8") as fixture:
        for line in fixture:
            line = line.strip()
            if line.startswith("<"):
                return json.loads(line[2:])
    raise AssertionError("set-model-bad.jsonl holds no response line")


def handle_prompt(command):
    global PROMPT_COUNT, TURN_NUMBER, RACE_PHASE, HOLD_START
    PROMPT_COUNT += 1
    TURN_NUMBER += 1
    text = command.get("message", "")
    if CASSETTE:
        handle_cassette(command)
        return
    if command.get("streamingBehavior") == "steer":
        handle_steer(command)
        return
    if "PROMPT_FAIL" in SCENARIOS and PROMPT_COUNT == 2:
        respond(command.get("id"), "prompt", False, error="fake prompt failed")
        return
    if "HANDLED" in SCENARIOS and PROMPT_COUNT == 2:
        respond(
            command.get("id"),
            "prompt",
            True,
            {"disposition": "handled"},
        )
        return
    if "DIE" in SCENARIOS and PROMPT_COUNT == 2:
        respond(command.get("id"), "prompt", True, {"disposition": "started"})
        sys.stdout.flush()
        os._exit(3)
    respond(command.get("id"), "prompt", True, {"disposition": "started"})
    if "STEER_RACE" in SCENARIOS and PROMPT_COUNT == 1:
        send({"type": "agent_start"})
        send({"type": "turn_start"})
        send({"type": "message_start", "message": {"role": "user"}})
        send(user_frame(text))
        RACE_PHASE = 1
        HOLD_START = time.monotonic()
        return
    if "HOLD_TOOL" in SCENARIOS:
        hold_run(text)
        return
    if "DIALOG" in SCENARIOS:
        send({"type": "agent_start"})
        send({"type": "turn_start"})
        send({"type": "message_start", "message": {"role": "user"}})
        send(user_frame(text))
        send(
            {
                "type": "extension_ui_request",
                "id": "ui-1",
                "method": "select",
                "title": "trust this project?",
            }
        )
        send({"type": "extension_ui_request", "id": "ui-2", "method": "notify"})
        send({"type": "message_start", "message": {"role": "assistant"}})
        send(assistant_frame("READY"))
        settle(False)
        return
    if "NOISE" in SCENARIOS and PROMPT_COUNT == 1:
        sys.stdout.write("this is not JSON\n")
        sys.stdout.flush()
        sys.stderr.write("sandbox warning: helper unavailable\n")
        sys.stderr.flush()
    full_run(text)


def handle_steer(command):
    global RACE_PHASE, RACE_TEXT
    text = command.get("message", "")
    if RACE_PHASE == 1:
        RACE_PHASE = 2
        RACE_TEXT = text
        HOLD_START = time.monotonic()
        send({"type": "agent_end", "messages": [], "willRetry": False})
        send({"type": "agent_settled", "aborted": False})
        respond(command.get("id"), "prompt", True, {"disposition": "started"})
        send({"type": "agent_start"})
        send({"type": "turn_start"})
        send(user_frame(text))
        with open(path("delivered.txt"), "a", encoding="utf-8") as output:
            output.write(text + "\n")
        return
    QUEUE.append(text)
    with open(path("queue.txt"), "a", encoding="utf-8") as output:
        output.write(text + "\n")
    send({"type": "queue_update", "steering": list(QUEUE), "followUp": []})
    respond(command.get("id"), "prompt", True, {"disposition": "queued"})


def finish_race_go():
    global RACE_PHASE
    try:
        os.remove(path("go"))
    except OSError:
        pass
    RACE_PHASE = 0
    send(assistant_frame("saw: " + RACE_TEXT))
    send({"type": "turn_end"})
    send({"type": "agent_end", "messages": [], "willRetry": False})
    send({"type": "agent_settled", "aborted": False})


def handle(command):
    kind = command.get("type")
    if kind == "set_model":
        if "SLOW_BOOT" in SCENARIOS:
            return
        if "SLOW_THINK" in SCENARIOS:
            time.sleep(1.5)
        if "BADMODEL" in SCENARIOS:
            bad = set_model_bad()
            bad["id"] = command.get("id")
            send(bad)
            return
        respond(command.get("id"), "set_model", True, {})
        return
    if kind == "set_thinking_level":
        if "SLOW_THINK" in SCENARIOS:
            return
        respond(command.get("id"), "set_thinking_level", True)
        return
    if kind == "prompt":
        handle_prompt(command)
        return
    if kind == "clear_queue":
        if CASSETTE:
            handle_cassette(command)
            return
        cleared = list(QUEUE)
        QUEUE.clear()
        with open(path("cleared.txt"), "a", encoding="utf-8") as output:
            output.write(json.dumps(cleared, separators=(",", ":")) + "\n")
        send({"type": "queue_update", "steering": [], "followUp": []})
        respond(command.get("id"), "clear_queue", True, {"steering": cleared, "followUp": []})
        return
    if kind == "abort":
        if CASSETTE:
            handle_cassette(command)
            return
        respond_later = command.get("id")
        if HELD:
            finish_hold(False)
        respond(respond_later, "abort", True)
        if QUEUE:
            send({"type": "agent_start"})
            deliver_queue()
        return
    if "id" in command:
        respond(command.get("id"), kind, False, error="fake unknown command")


def waiting():
    return HELD or RACE_PHASE in (1, 2)


def main():
    global SEGMENTS
    os.makedirs(FAKE_DIR, exist_ok=True)
    write_file("argv.txt", "\n".join(sys.argv[1:]) + ("\n" if sys.argv[1:] else ""))
    write_file("host.pid", str(os.getpid()) + "\n")
    try:
        append_index = sys.argv.index("--append-system-prompt")
        append_path = sys.argv[append_index + 1]
        with open(append_path, "rb") as prompt:
            write_file("append-prompt.txt", prompt.read())
    except (ValueError, IndexError, OSError):
        write_file("append-prompt.txt", b"")
    write_file(
        "tty.txt",
        "stdin-tty={}\nstdout-tty={}\nstderr-tty={}\nTERM-set={}\n".format(
            os.isatty(0),
            os.isatty(1),
            os.isatty(2),
            "TERM" in os.environ,
        ),
    )
    if "EXIT_NOW" in SCENARIOS:
        os._exit(2)
    if CASSETTE:
        SEGMENTS = load_cassette()
    if "EXIT_AT_START" in SCENARIOS:
        sys.stderr.write("fake host starting\n")
        sys.stderr.flush()
        line = sys.stdin.readline()
        if line:
            log_request(line)
        os._exit(2)
    stdin_fd = sys.stdin.fileno()
    pending = bytearray()
    eof = False
    while True:
        if waiting() and os.path.exists(path("go")):
            if HELD:
                finish_hold(True)
            elif RACE_PHASE == 2:
                finish_race_go()
            eof = False
        if eof and not waiting():
            return 0
        if waiting() and time.monotonic() - HOLD_START > GO_WAIT:
            return 5
        ready, _, _ = select.select([stdin_fd], [], [], 0.05)
        if not ready:
            continue
        try:
            chunk = os.read(stdin_fd, 65536)
        except OSError:
            chunk = b""
        if not chunk:
            eof = True
            continue
        pending.extend(chunk)
        while True:
            newline = pending.find(b"\n")
            if newline < 0:
                break
            raw = bytes(pending[: newline + 1])
            del pending[: newline + 1]
            try:
                line = raw.decode("utf-8")
            except UnicodeDecodeError:
                continue
            log_request(line)
            try:
                command = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(command, dict) and "type" in command:
                handle(command)


if __name__ == "__main__":
    raise SystemExit(main())
