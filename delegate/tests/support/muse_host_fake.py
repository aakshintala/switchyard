#!/usr/bin/env python3
"""A local MSP host fake for supervisor tests; never starts a real model."""

import json
import os
import re
import select
import signal
import sys
import time

FAKE_DIR = os.environ["FAKE_DIR"]
SCENARIOS = {
    item.strip()
    for item in os.environ.get("FAKE_SCENARIO", "").split(",")
    if item.strip()
}
SESSION_ID = "fake-session"
TURN_NUMBER = 0
ACTIVE_TURN = None
ACTIVE_SCENARIOS = set()
HELD_TERMINAL = "completed"
STOP_READING = False


def write_file(name, text):
    with open(os.path.join(FAKE_DIR, name), "w", encoding="utf-8") as output:
        output.write(text)


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
    words = set(re.findall(r"[A-Z][A-Z0-9_]+", text.upper()))
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
    frames = []
    if include_ack is not None:
        frames.append(include_ack)
    frames.extend(
        [
            event("session/statusChanged", {"sessionId": SESSION_ID, "status": "running"}),
            event("turn/started", {"sessionId": SESSION_ID, "turnId": turn_id}),
            event(
                "item/completed",
                {"item": {"kind": "userMessage", "turnId": turn_id, "text": text, "commandId": command_id}},
            ),
        ]
    )
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
    send_frames(*frames)
    ACTIVE_TURN = None


def start_turn(frame):
    global TURN_NUMBER, STOP_READING
    params = frame.get("params", {})
    text = params.get("input", [{}])[0].get("text", "")
    features = current_features(text)
    TURN_NUMBER += 1
    turn_id = "fake-turn-{}".format(TURN_NUMBER)
    command_id = params.get("commandId")

    if "MUTE_AFTER_START" in features and TURN_NUMBER > 1:
        return
    if "SLOW_ACK" in features:
        time.sleep(0.15)

    if "QUEUED_ACK" in features:
        queued = response(frame["id"], {"status": "accepted", "turnId": "queued-turn", "disposition": "queued"})
        started = event("turn/started", {"turnId": "host-started-turn"})
        send_frames(queued, started)
        global ACTIVE_TURN, ACTIVE_SCENARIOS
        ACTIVE_TURN = "host-started-turn"
        ACTIVE_SCENARIOS = features
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
    if "APPROVAL" in features:
        send_frames({"jsonrpc": "2.0", "id": 981, "method": "approval/request", "params": {"sessionId": SESSION_ID}})
    if "NOISE" in features and "NOISE_WRITTEN" not in SCENARIOS:
        sys.stderr.write("sandbox warning: helper unavailable\n{\"jsonrpc\":\"2.0\",\"id\":99,\"result\":{}}\n")
        sys.stderr.flush()
        send_frames("this is not JSON-RPC")
        SCENARIOS.add("NOISE_WRITTEN")

    if "IDLE_EARLY" in features:
        send_frames(event("session/statusChanged", {"sessionId": SESSION_ID, "status": "idle"}))
        return
    if any(flag in features for flag in ("HOLD", "HOLD_INTERRUPT", "STEERREFUSE", "STEERREFUSE_HOLD", "IGNORE_INTERRUPT")):
        if "STEERREFUSE" in features or "STEERREFUSE_HOLD" in features:
            ACTIVE_SCENARIOS |= {"STEERREFUSE"} if "STEERREFUSE" in features else set()
        return

    complete_turn("failed" if "BADMODEL" in features else None)
    if "STOP_READING" in features and TURN_NUMBER == 1:
        STOP_READING = True


def handle(frame):
    global ACTIVE_TURN, ACTIVE_SCENARIOS, HELD_TERMINAL
    log_frame(frame)
    method = frame.get("method")
    params = frame.get("params", {})
    request_id = frame.get("id")

    if method == "initialize":
        if "NO_INIT_ACK" not in SCENARIOS:
            send_frames(response(request_id, {"protocolVersion": "1.0", "capabilities": {}}))
    elif method == "initialized":
        return
    elif method == "session/start":
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
        if "STEERREFUSE" in SCENARIOS:
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
        send_frames(ack)
        if ACTIVE_TURN is not None and "IGNORE_INTERRUPT" not in SCENARIOS and "HOLD_INTERRUPT" not in SCENARIOS:
            complete_turn("cancelled")
        elif ACTIVE_TURN is not None:
            HELD_TERMINAL = "cancelled"
    elif request_id is not None:
        send_frames(error_response(request_id, "unknown method"))


def main():
    global STOP_READING
    os.makedirs(FAKE_DIR, exist_ok=True)
    write_file("argv.txt", "\n".join(sys.argv[1:]) + "\n")
    write_file("host.pid", str(os.getpid()) + "\n")
    probe_descriptors()
    if "IGNORE_TERM" in SCENARIOS:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)

    source = sys.stdin.buffer
    eof = False
    while True:
        if STOP_READING or eof:
            if eof and not ("IGNORE_EOF" in SCENARIOS or "IGNORE_TERM" in SCENARIOS):
                return 0
            if ACTIVE_TURN is not None and os.path.exists(os.path.join(FAKE_DIR, "go")):
                complete_turn()
            time.sleep(0.05)
            continue

        ready, _, _ = select.select([source], [], [], 0.05)
        if not ready:
            if ACTIVE_TURN is not None and os.path.exists(os.path.join(FAKE_DIR, "go")):
                complete_turn()
            continue
        line = source.readline()
        if not line:
            eof = True
            continue
        try:
            frame = json.loads(line)
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        handle(frame)


if __name__ == "__main__":
    raise SystemExit(main())
