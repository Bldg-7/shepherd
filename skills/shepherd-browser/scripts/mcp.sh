#!/bin/sh
# No global fallback, endpoint inference, package download or token acquisition.
printf '%s\n' 'Shepherd: this legacy MCP entry point is disabled. Start a new managed agent tab in Shepherd.' >&2
exit 1
