#!/usr/bin/env python3
"""Owned terminal workload: no shell, files, network, agents or credentials."""
import os
import signal
import sys
import tty

tty.setraw(0)

def emit(text):
    data = text.encode()
    while data:
        n = os.write(1, data); data = data[n:]

def resized(*_):
    size = os.get_terminal_size(0)
    emit('\r\nSIZE:%d,%d\r\n' % (size.columns, size.lines))

signal.signal(signal.SIGWINCH, resized)
emit('\033[2J\033[H\033[31mBOOT 한글😀\033[0m\r\n'
     '\033]8;;https://example.invalid/owned\007owned-link\033]8;;\007\r\n'
     '\033[?1000h\033[?1006h\033[>1u\033]7501;state=idle:app=fixture\007')
received = b''
while True:
    part = os.read(0, 4096)
    if not part or part == b'\x04':
        break
    received += part
    emit('\r\nRXALL:' + received.hex() + '\r\n')
    if b'L' in part:
        emit('\r\n\033]8;;https://example.invalid/live\007live-link\033]8;;\007\r\n')
    if b'R' in part:
        emit('\r\n\033]8;id=reconnect;https://example.invalid/reconnect\007reconnect-link\033]8;;\007\r\n')
    if b'Q' in part:
        emit('\033]10;?\007')
    if b'B' in part:
        emit('burst-line\r\n' * 40000 + 'BURST-DONE\r\n')
