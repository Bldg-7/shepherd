#!/usr/bin/env python3
"""Synthetic attributed grid. No agent, shell startup, network or credentials."""
import os
import signal
import tty

tty.setraw(0)
received = 0


def emit(value):
    data = value.encode()
    while data:
        data = data[os.write(1, data):]


def draw(*_):
    cols, rows = os.get_terminal_size(0)
    emit('\033[0m\033[H\033[2JGRID:%dx%d\r\n' % (cols, rows)
         + '\033[41mred\033[0m\033[10Gplain\r\n'
         + '\033[44m\033[2K\033[0m\r\n'
         + '\033[1m›\033[0m \033[2mAsk fixture\033[0m\r\n'
         + '\033]8;id=cell;https://example.invalid/passive\007link\033]8;;\007\r\n'
         + 'CJK 한글😀\r\nINPUT:%d\r\n' % received
         + 'PAINT-DONE:%dx%d\r\n' % (cols, rows)
         + '\033]7501;state=idle:app=fixture\007')


signal.signal(signal.SIGWINCH, draw)
draw()
while True:
    data = os.read(0, 4096)
    if not data: break
    received += len(data)
    draw()
