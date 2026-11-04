#!/usr/bin/env python3
"""Interactive program for the hc attach test: prints a marker, echoes input."""
import sys
sys.stdout.write("READY\r\n")
sys.stdout.flush()
for line in sys.stdin:
    sys.stdout.write("GOT:" + line.rstrip("\r\n") + "\r\n")
    sys.stdout.flush()
