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
           "fixture.partial", "fixture.invalid", "fixture.stderr", "fixture.streamStats"]
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
channels = {}
late_streams = []
next_channel = 1
closed_channels = []

def stream_frame(channel, kind, body=b""):
    return struct.pack("<IBI", channel, kind, len(body)) + body

def pump(channel):
    s = channels[channel]
    while s['remaining'] and s['credit']:
        n = min(s['remaining'], s['credit'], 16384)
        emit(stream_frame(channel, 0, b'x' * n))
        s['remaining'] -= n; s['credit'] -= n
    if s['burst'] and not s['remaining'] and not s['ended']:
        s['ended'] = True; emit(stream_frame(channel, 2, b'{"reason":"exited"}'))

def open_stream(request_id, channel, params, events=False):
    name = params.get('terminal', 'normal')
    s = channels[channel] = {'credit': 262144, 'acks': 0, 'remaining': 600000 if name == 'burst' else 0,
                              'burst': name == 'burst', 'ended': False, 'name': name, 'input': '', 'size': None}
    notify_resize = params.get('resize_notifications', False)
    result = {'channel': channel, 'resize_notifications': notify_resize, 'seq': 1, 'terminals': []}
    first = b'{"method":"heartbeat","params":{"seq":1}}\n' if events else b'initial'
    if name == 'before': emit(stream_frame(channel, 0, first))
    prefix = encoded(request_id, result)
    if notify_resize: prefix += stream_frame(channel, 3, struct.pack('<HH', 90, 25))
    if name == 'overflow': emit(prefix + stream_frame(channel, 0, b'x' * 262145)); return
    if not s['burst']:
        s['credit'] -= len(first)
        prefix += stream_frame(channel, 0, first)
    emit(prefix); pump(channel)

while True:
    header = read_exact(9)
    if header is None:
        sys.exit(0)
    channel, kind, length = struct.unpack("<IBI", header)
    assert length <= 16 << 20
    body = read_exact(length)
    if body is None:
        sys.exit(0)
    if channel:
        s = channels[channel]
        if kind == 1:
            credit = struct.unpack('<I', body)[0]
            s['acks'] += credit; s['credit'] += credit; pump(channel)
        elif kind == 2:
            if s['name'] != 'hangclose':
                closed_channels.append(channel); emit(stream_frame(channel, 2))
        elif kind == 0:
            s['input'] = body.decode('utf-8'); out = b'echo:' + body
            assert len(out) <= s['credit']; s['credit'] -= len(out); emit(stream_frame(channel, 0, out))
        elif kind == 3: s['size'] = list(struct.unpack('<HH', body))
        elif kind == 4: s['focused'] = body[0]
        elif kind == 5: s['facts'] = json.loads(body)
        else: raise AssertionError('invalid stream control')
        continue
    assert kind == 0
    call = json.loads(body)
    request_id, method, params = call["id"], call["method"], call["params"]
    assert method != 'hello'
    if method in ('terminal.attach', 'events.subscribe'):
        channel = 1 if params.get('terminal') == 'reuse' else next_channel
        next_channel += 1
        if params.get('terminal') == 'late':
            late_streams.append((request_id, channel, params))
            for barrier in barriers: emit(encoded(barrier, {}))
            barriers.clear()
        else: open_stream(request_id, channel, params, method == 'events.subscribe')
    elif method == 'fixture.streamStats':
        emit(encoded(request_id, {'closed': closed_channels, 'channels': channels}))
    elif method == "terminal.list":
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
        if slow or late_streams:
            emit(encoded(request_id, {}))
        else:
            barriers.append(request_id)
    elif method == "fixture.flush":
        for delayed in late_streams: open_stream(*delayed)
        late_streams.clear()
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
