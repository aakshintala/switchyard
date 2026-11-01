#!/usr/bin/env -S python3 -S
"""A local MSP host fake for supervisor tests; never starts a real model."""

import os
import sys
import time

def load_config():
    import json

    try:
        with open("fake-config.json", encoding="utf-8") as config:
            data = json.load(config)
    except FileNotFoundError:
        return os.environ["FAKE_DIR"], os.environ.get("FAKE_SCENARIO", "")
    return data["fakeDir"], data.get("scenario", "")


FAKE_DIR, _SCENARIO_TEXT = load_config()
SCENARIOS = {item.strip() for item in _SCENARIO_TEXT.split(",") if item.strip()}
SESSION_ID = "fake-session"
TURN_NUMBER = 0
ACTIVE_TURN = None
ACTIVE_SCENARIOS = set()
HELD_TERMINAL = "completed"
STOP_READING = False


def write_file(name, text):
    with open(os.path.join(FAKE_DIR, name), "w", encoding="utf-8") as output:
        output.write(text)


def hold_start():
    write_file("start.pending", "")
    release_path = os.path.join(FAKE_DIR, "start.release")
    deadline = time.monotonic() + 10
    while not os.path.exists(release_path) and time.monotonic() < deadline:
        time.sleep(0.01)


def log_frame(frame):
    with open(os.path.join(FAKE_DIR, "requests.jsonl"), "a", encoding="utf-8") as output:
        output.write(json.dumps(frame, separators=(",", ":"), ensure_ascii=False) + "\n")


def send_frames(*frames):
    data = "".join(json.dumps(frame, separators=(",", ":"), ensure_ascii=False) + "\n" for frame in frames)
    sys.stdout.write(data)
    sys.stdout.flush()


def response(request_id, result):
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def error_response(request_id, message="request refused"):
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": -32020, "message": message, "data": {"kind": "requestRejected", "retryable": False}},
    }


def event(method, params):
    return {"jsonrpc": "2.0", "method": method, "params": params}


def current_features(text=""):
    import re

    words = set(re.findall(r"[A-Z][A-Z0-9_]+", text[:1024].upper()))
    return SCENARIOS | words


def probe_descriptors():
    probe = os.open("/dev/null", os.O_RDONLY)
    try:
        inherited = []
        for fd in range(3, 257):
            if fd == probe:
                continue
            try:
                os.fstat(fd)
            except OSError:
                continue
            inherited.append(str(fd))
        write_file("fds.txt", "\n".join(inherited) + ("\n" if inherited else ""))
    finally:
        os.close(probe)


def emit_start_events(turn_id, command_id, text, features, include_ack=None):
    global ACTIVE_TURN, ACTIVE_SCENARIOS, HELD_TERMINAL
    ACTIVE_TURN = turn_id
    ACTIVE_SCENARIOS = features
    HELD_TERMINAL = "cancelled" if "CANCEL_ON_GO" in features else "completed"
    if include_ack is not None:
        send_frames(include_ack)
    frames = [
            event("session/statusChanged", {"sessionId": SESSION_ID, "status": "running"}),
            event("turn/started", {"sessionId": SESSION_ID, "turnId": turn_id}),
            event(
                "item/completed",
                {"item": {"kind": "userMessage", "turnId": turn_id, "text": text, "commandId": command_id}},
            ),
        ]
    send_frames(*frames)


def complete_turn(terminal=None):
    global ACTIVE_TURN
    if ACTIVE_TURN is None:
        return
    turn_id = ACTIVE_TURN
    terminal = terminal or HELD_TERMINAL
    frames = [
        event("item/completed", {"item": {"kind": "agentMessage", "turnId": turn_id, "text": "fake response"}}),
        event("session/tokenUsage", {"sessionId": SESSION_ID, "cumulative": {"promptTokens": 2, "outputTokens": 3, "totalTokens": 5}}),
        event("session/statusChanged", {"sessionId": SESSION_ID, "status": "idle"}),
        event("turn/completed", {"turnId": turn_id, "terminal": terminal}),
    ]
    if "BADMODEL" in ACTIVE_SCENARIOS:
        frames[-1]["params"] = {
            "turnId": turn_id,
            "terminal": "failed",
            "error": {"kind": "modelError", "message": "fake model unavailable"},
        }
    ACTIVE_TURN = None
    send_frames(*frames)


def start_turn(frame):
    global TURN_NUMBER, STOP_READING, ACTIVE_TURN, ACTIVE_SCENARIOS
    params = frame.get("params", {})
    text = params.get("input", [{}])[0].get("text", "")
    features = current_features(text)
    TURN_NUMBER += 1
    turn_id = "fake-turn-{}".format(TURN_NUMBER)
    command_id = params.get("commandId")

    if "MUTE_AFTER_START" in features and TURN_NUMBER > 1:
        return
    if "SLOW_ACK" in features and TURN_NUMBER > 1:
        write_file("ack.pending", "")
        while not os.path.exists(os.path.join(FAKE_DIR, "ack.release")):
            time.sleep(0.01)

    if "QUEUED_ACK" in features:
        queued = response(frame["id"], {"status": "accepted", "turnId": "queued-turn", "disposition": "queued"})
        started = event("turn/started", {"turnId": "host-started-turn"})
        ACTIVE_TURN = "host-started-turn"
        ACTIVE_SCENARIOS = features
        send_frames(queued, started)
        complete_turn()
        return

    ack = response(frame["id"], {"commandId": command_id, "status": "accepted", "turnId": turn_id, "startedNewTurn": True, "disposition": "started"})
    if "RACE" in features:
        send_frames(
            ack,
            event("session/statusChanged", {"sessionId": SESSION_ID, "status": "idle"}),
            event("turn/completed", {"turnId": turn_id, "terminal": "completed"}),
        )
        return

    emit_start_events(turn_id, command_id, text, features, ack)
    if "DIE" in features:
        sys.stdout.flush()
        os._exit(3)
    if "PANIC_LINE" in features:
        sys.stdout.write("PANIC_LINE\n")
        sys.stdout.flush()
    if "MULTIBYTE" in features:
        sys.stdout.write("é" * 300 + "\n")
        sys.stdout.flush()
    if "APPROVAL" in features:
        send_frames({"jsonrpc": "2.0", "id": 981, "method": "approval/request", "params": {"sessionId": SESSION_ID}})
    if "NOISE" in features and "NOISE_WRITTEN" not in SCENARIOS:
        SCENARIOS.add("NOISE_WRITTEN")
        sys.stderr.write("sandbox warning: helper unavailable\n{\"jsonrpc\":\"2.0\",\"id\":99,\"result\":{}}\n")
        sys.stderr.flush()
        send_frames("this is not JSON-RPC")

    if "IDLE_EARLY" in features:
        send_frames(event("session/statusChanged", {"sessionId": SESSION_ID, "status": "idle"}))
        return
    if any(flag in features for flag in ("HOLD", "HOLD_INTERRUPT", "STEERREFUSE", "STEERREFUSE_HOLD", "IGNORE_INTERRUPT")):
        if "STEERREFUSE" in features or "STEERREFUSE_HOLD" in features:
            ACTIVE_SCENARIOS |= {"STEERREFUSE"} if "STEERREFUSE" in features else set()
        return

    if "STOP_READING" in features and TURN_NUMBER == 1:
        STOP_READING = True
    complete_turn("failed" if "BADMODEL" in features else None)


def handle(frame, raw_line=None):
    global ACTIVE_TURN, ACTIVE_SCENARIOS, HELD_TERMINAL
    if raw_line is None:
        log_frame(frame)
    else:
        with open(os.path.join(FAKE_DIR, "requests.jsonl"), "a", encoding="utf-8") as output:
            output.write(raw_line)
    method = frame.get("method")
    params = frame.get("params", {})
    request_id = frame.get("id")

    if method == "initialize":
        if "NO_INIT_ACK" not in SCENARIOS:
            send_frames(response(request_id, {"protocolVersion": "1.0", "capabilities": {}}))
    elif method == "initialized":
        return
    elif method == "session/start":
        if "HOLD_START" in SCENARIOS:
            hold_start()
        if "STARTFAIL" in SCENARIOS:
            send_frames(error_response(request_id, "fake session start failed"))
        else:
            send_frames(
                event("session/started", {"session": {"sessionId": SESSION_ID}}),
                response(request_id, {"session": {"sessionId": SESSION_ID}}),
            )
    elif method == "turn/start":
        start_turn(frame)
    elif method == "turn/steer":
        command_id = params.get("commandId")
        if "STEERREFUSE" in SCENARIOS or "STEERREFUSE_HOLD" in SCENARIOS:
            frames = [error_response(request_id, "turn already ended")]
            if "STEERREFUSE_HOLD" not in SCENARIOS and ACTIVE_TURN is not None:
                frames.append(event("turn/completed", {"turnId": ACTIVE_TURN, "terminal": "completed"}))
                ACTIVE_TURN = None
            send_frames(*frames)
        else:
            frames = [response(request_id, {"commandId": command_id, "status": "accepted", "turnId": ACTIVE_TURN})]
            if "STEER_NOEFFECT" not in SCENARIOS and ACTIVE_TURN is not None:
                frames.append(
                    event(
                        "item/completed",
                        {"item": {"kind": "userMessage", "turnId": ACTIVE_TURN, "text": params.get("input", [{}])[0].get("text", ""), "commandId": command_id}},
                    )
                )
            send_frames(*frames)
    elif method == "turn/interrupt":
        ack = response(request_id, {"status": "accepted"})
        if ACTIVE_TURN is not None and "HOLD_INTERRUPT" in SCENARIOS:
            HELD_TERMINAL = "cancelled"
        send_frames(ack)
        if ACTIVE_TURN is not None and "IGNORE_INTERRUPT" not in SCENARIOS and "HOLD_INTERRUPT" not in SCENARIOS:
            complete_turn("cancelled")
    elif request_id is not None:
        send_frames(error_response(request_id, "unknown method"))


def read_line(fd, pending):
    while True:
        newline = pending.find(b"\n")
        if newline >= 0:
            line = bytes(pending[: newline + 1])
            del pending[: newline + 1]
            return line
        chunk = os.read(fd, 65536)
        if not chunk:
            line = bytes(pending)
            pending.clear()
            return line
        pending.extend(chunk)


def main():
    global STOP_READING, json
    os.makedirs(FAKE_DIR, exist_ok=True)
    write_file("argv.txt", "\n".join(sys.argv[1:]) + "\n")
    write_file("host.pid", str(os.getpid()) + "\n")
    probe_descriptors()
    input_fd = sys.stdin.fileno()
    pending = bytearray()
    first = read_line(input_fd, pending)
    fast_init = b'"method":"initialize"' in first
    if fast_init:
        with open(os.path.join(FAKE_DIR, "requests.jsonl"), "a", encoding="utf-8") as output:
            output.write(first.decode("utf-8"))
        if "NO_INIT_ACK" not in SCENARIOS:
            sys.stdout.buffer.write(b'{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"1.0","capabilities":{}}}\n')
            sys.stdout.buffer.flush()
            initialized = read_line(input_fd, pending)
            session_start = read_line(input_fd, pending)
            with open(os.path.join(FAKE_DIR, "requests.jsonl"), "a", encoding="utf-8") as output:
                output.write(initialized.decode("utf-8"))
                output.write(session_start.decode("utf-8"))
            if "HOLD_START" in SCENARIOS:
                hold_start()
            if "STARTFAIL" in SCENARIOS:
                sys.stdout.buffer.write(b'{"jsonrpc":"2.0","id":2,"error":{"code":-32020,"message":"fake session start failed"}}\n')
            else:
                sys.stdout.buffer.write(b'{"jsonrpc":"2.0","method":"session/started","params":{"session":{"sessionId":"fake-session"}}}\n')
                sys.stdout.buffer.write(b'{"jsonrpc":"2.0","id":2,"result":{"session":{"sessionId":"fake-session"}}}\n')
            sys.stdout.buffer.flush()
    import json
    import select
    if not fast_init and first:
        try:
            handle(json.loads(first))
        except (UnicodeDecodeError, json.JSONDecodeError):
            pass
    if "IGNORE_TERM" in SCENARIOS:
        import signal

        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    eof = not first
    while True:
        if STOP_READING or eof:
            if eof and not ("IGNORE_EOF" in SCENARIOS or "IGNORE_TERM" in SCENARIOS):
                return 0
            if ACTIVE_TURN is not None and os.path.exists(os.path.join(FAKE_DIR, "go")):
                complete_turn()
            time.sleep(0.05)
            continue

        if b"\n" not in pending:
            ready, _, _ = select.select([input_fd], [], [], 0.05)
            if not ready:
                if ACTIVE_TURN is not None and os.path.exists(os.path.join(FAKE_DIR, "go")):
                    complete_turn()
                continue
        line = read_line(input_fd, pending)
        if not line:
            eof = True
            continue
        try:
            frame = json.loads(line)
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        handle(frame, line.decode("utf-8"))


if __name__ == "__main__":
    raise SystemExit(main())
