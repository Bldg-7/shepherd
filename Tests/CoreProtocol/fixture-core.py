#!/usr/bin/env python3
"""Independent generation-1 peer, never a real core or agent. Owned stdio only."""
import json
import os
import signal
import struct
import sys
import time

mode = sys.argv[1]
assert not any(os.isatty(fd) for fd in (0, 1, 2)), "must not launch in a PTY"
if mode == "ignore-term":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)


def read_exact(size):
    data = b""
    while len(data) < size:
        part = os.read(0, size - len(data))
        if not part:
            return None
        data += part
    return data


def emit(raw):
    # os.write may be partial even for a synthetic peer.
    while raw:
        written = os.write(1, raw)
        raw = raw[written:]


def encoded(request_id, result=None, error=None):
    obj = {"jsonrpc": "2.0", "id": request_id}
    obj["error" if error is not None else "result"] = error if error is not None else result
    body = json.dumps(obj, separators=(",", ":")).encode()
    return struct.pack("<IBI", 0, 0, len(body)) + body


line = b""
while not line.endswith(b"\n"):
    byte = read_exact(1)
    if byte is None:
        sys.exit(0)
    line += byte
hello = json.loads(line)
assert hello["method"] == "hello" and hello["params"] == {"framed": True, "generation": 1}
if mode in ("hang-hello", "ignore-hello"):
    if mode == "ignore-hello":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True:
        time.sleep(1)
if mode == "bad-hello":
    emit(b"this is not JSON\n")
    while True:
        time.sleep(1)
if mode == "partial-hello":
    emit(b'{"jsonrpc":"2.0"')
    sys.exit(0)
methods = ["terminal.list", "terminal.attach", "events.subscribe", "fixture.echo", "fixture.reverse",
           "fixture.slow", "fixture.slowBarrier", "fixture.flush", "fixture.fail", "fixture.last",
           "fixture.partial", "fixture.invalid", "fixture.stderr"]
response = json.dumps({"jsonrpc": "2.0", "id": hello["id"], "result": {
    "core": {"id": "owned-process-fixture", "name": "fixture"}, "generation": 1,
    "version": "0.1.16", "methods": methods, "features": [], "framed": True,
}}, separators=(",", ":")).encode() + b"\n"
emit(response[:7])
time.sleep(0.002)
emit(response[7:])
if mode == "close-input":
    os.close(0)
    while True:
        time.sleep(1)
if mode == "no-read":
    while True:
        time.sleep(1)
reverse = []
slow = []
barriers = []
while True:
    header = read_exact(9)
    if header is None:
        sys.exit(0)
    channel, kind, length = struct.unpack("<IBI", header)
    assert channel == 0 and kind == 0 and length <= 16 << 20
    body = read_exact(length)
    if body is None:
        sys.exit(0)
    call = json.loads(body)
    request_id, method, params = call["id"], call["method"], call["params"]
    assert method not in ("hello", "terminal.attach", "events.subscribe"), "connection must reject reserved/streaming methods before writing"
    if method == "terminal.list":
        emit(encoded(request_id, {"terminals": [], "hidden_finished": 0,
                                 "inherited_marker": "CORE_UNEXPECTED_PARENT_ENV" in os.environ, "cwd": os.getcwd()}))
    elif method == "fixture.reverse":
        reverse.append((request_id, params))
        if len(reverse) == 2:
            emit(b"".join(encoded(i, p) for i, p in reversed(reverse)))
            reverse.clear()
    elif method == "fixture.slow":
        slow.append((request_id, params))
        for barrier in barriers:
            emit(encoded(barrier, {}))
        barriers.clear()
    elif method == "fixture.slowBarrier":
        if slow:
            emit(encoded(request_id, {}))
        else:
            barriers.append(request_id)
    elif method == "fixture.flush":
        emit(b"".join(encoded(i, p) for i, p in slow) + encoded(request_id, {}))
        slow.clear()
    elif method == "fixture.fail":
        emit(encoded(request_id, error={"code": -32000, "message": "PRIVATE-FIXTURE-TEXT", "data": {"kind": "not_found"}}))
    elif method == "fixture.last":
        emit(encoded(request_id, {"value": 99}))
        sys.exit(0)
    elif method == "fixture.partial":
        emit(struct.pack("<IBI", 0, 0, 100) + b"{}")
        sys.exit(0)
    elif method == "fixture.invalid":
        emit(encoded("wrong-id", {}))
    elif method == "fixture.stderr":
        data = b"PRIVATE-STDERR-FIXTURE\n" * 8192
        while data:
            size = os.write(2, data)
            data = data[size:]
        emit(encoded(request_id, {}))
    else:
        emit(encoded(request_id, params))
