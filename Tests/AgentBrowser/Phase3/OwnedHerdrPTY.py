#!/usr/bin/env python3
"""Owned herdr terminal attach under a real PTY, no arbitrary shell or PID kill.

The outer finite identity-checking runner owns failure cleanup. A watchdog failure
never means readiness or a natural exit. Successful pane close must naturally end
this exact attach child, and stdout is drained through PTY EOF.
"""
import argparse
import json
import fcntl
import signal
import struct
import termios
import os
from pathlib import Path
import select
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--session', required=True)
parser.add_argument('--terminal', required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--closed-marker', type=Path, required=True)
args = parser.parse_args()
master, slave = os.openpty()
fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 200, 0, 0))
def controlling_terminal():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    for sig in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, signal.SIG_DFL)
child = subprocess.Popen(['herdr', '--session', args.session, 'terminal', 'attach', args.terminal, '--takeover'], stdin=slave, stdout=slave, stderr=slave, preexec_fn=controlling_terminal)
os.close(slave)
start = time.monotonic()
args.output.parent.mkdir(parents=True, exist_ok=True)
fd = os.open(args.output, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
try:
    eof = False
    while time.monotonic() - start < 70:
        readable, _, _ = select.select([master], [], [], 0.1)
        if readable:
            try:
                data = os.read(master, 16384)
            except OSError as error:
                if error.errno != 5:
                    raise
                data = b''
            if not data:
                eof = True
                break
            os.write(fd, data)
        if child.poll() is not None and not readable:
            # A final readiness check still drains all queued PTY output.
            continue
    # PTY EOF can precede the child exit event. Reap its actual status within
    # the original deadline; EOF alone is not process-exit evidence.
    if eof and child.poll() is None:
        try:
            child.wait(timeout=max(0.001, 70 - (time.monotonic() - start)))
        except subprocess.TimeoutExpired:
            pass
    code = child.poll()
    expected_disappearance = False
    if code == 1 and eof:
        marker_deadline = time.monotonic() + 2
        while time.monotonic() < marker_deadline and not args.closed_marker.exists():
            time.sleep(0.05)
        if args.closed_marker.exists():
            marker = json.loads(args.closed_marker.read_text())
            expected_disappearance = (marker.get('terminal') == args.terminal and marker.get('session') == args.session and
                                      ('terminal ' + args.terminal + ' not found').encode() in args.output.read_bytes())
    record = {'pid': child.pid, 'elapsedSeconds': time.monotonic() - start, 'processExitCode': code,
              'ptyEOF': eof, 'naturalExit': code is not None and eof, 'commandSuccess': code == 0,
              'expectedPaneDisappearanceFailure': expected_disappearance, 'timedOut': code is None, 'signalsSent': []}
    args.output.with_suffix('.exit.json').write_text(json.dumps(record, indent=2))
    if code is None:
        raise RuntimeError('Owned attach did not naturally exit before its deadline; outer runner cleanup is a failed gate')
    child.wait(timeout=1)
    if (code != 0 and not expected_disappearance) or not eof:
        raise RuntimeError('Owned attach failed or PTY output did not reach EOF')
finally:
    os.close(fd)
    os.close(master)
