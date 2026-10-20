#!/bin/sh
# No global fallback, endpoint inference, package download or token acquisition.
printf '%s\n' '3rdr: this legacy MCP entry point is disabled. Start a new managed agent tab in 3rdr.' >&2
exit 1
