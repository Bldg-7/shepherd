#!/usr/bin/env python3
"""A private PTY/session with a two-process job. No shell, agents or accounts.
Only reports PIDs belonging to this invocation, never argv/environment contents.
"""
import json
import os
import pty
import signal
import sys
import tty


def timeout(*_):
    raise TimeoutError("owned fixture deadline")


commands_read, commands_write = os.pipe()
root, master = pty.fork()
if root == 0:
    os.close(commands_write)
    signal.signal(signal.SIGTTOU, signal.SIG_IGN)
    signal.signal(signal.SIGALRM, timeout)
    signal.alarm(20)
    tty.setraw(0)
    workers = []
    gate = None
    group = os.getpid()

    def report():
        data = (json.dumps({"anchor": os.getpid(), "group": group, "members": workers or [os.getpid()]}) + "\n").encode()
        while data:
            data = data[os.write(1, data):]

    def retire():
        global gate, workers, group
        os.tcsetpgrp(0, os.getpid())
        if gate is not None:
            os.close(gate); gate = None
        for pid in workers:
            got, status = os.waitpid(pid, 0)
            if got != pid or status != 0: raise RuntimeError("owned worker did not exit cleanly")
        workers = []; group = os.getpid()

    try:
        report()
        while command := os.read(commands_read, 1):
            if command == b"q": break
            if command == b"f":
                if workers: raise RuntimeError("duplicate job")
                reader, gate = os.pipe()
                for index in range(2):
                    pid = os.fork()
                    if pid == 0:
                        os.close(gate)
                        os.setpgid(0, 0 if index == 0 else group)
                        os.read(reader, 1)
                        os._exit(0)
                    if index == 0: group = pid
                    os.setpgid(pid, group)
                    workers.append(pid)
                os.close(reader)
                os.tcsetpgrp(0, group)
            elif command == b"l":
                if len(workers) != 2: raise RuntimeError("no leader to retire")
                # Exact unreaped owned child only, never a process-group kill.
                leader = workers.pop(0)
                os.kill(leader, signal.SIGTERM)
                got, status = os.waitpid(leader, 0)
                if got != leader or not os.WIFSIGNALED(status): raise RuntimeError("leader cleanup failed")
            elif command == b"s":
                retire()
            else:
                raise RuntimeError("unknown command")
            report()
    finally:
        retire()
        os.close(commands_read)
    os._exit(0)

os.close(commands_read)
signal.signal(signal.SIGALRM, timeout)
signal.alarm(25)


def forward():
    data = b""
    while not data.endswith(b"\n"):
        part = os.read(master, 1)
        if not part or len(data) > 4096: raise RuntimeError("bad fixture response")
        data += part
    record = json.loads(data)
    print(json.dumps(record), flush=True)


try:
    forward()
    while command := sys.stdin.buffer.read(1):
        os.write(commands_write, command)
        if command == b"q": break
        forward()
finally:
    os.close(commands_write)
    got, status = os.waitpid(root, 0)
    os.close(master)
    if got != root or status != 0: raise RuntimeError("owned session did not exit cleanly")
