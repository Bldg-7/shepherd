#!/bin/sh
# The `shepherd-browser` MCP server that setup.sh registers: Playwright MCP,
# connected to the browser Shepherd keeps for the herdr pane the agent runs
# in.
#
# Shepherd serves each pane's browser over CDP at
#   ws://127.0.0.1:<port>/herdr/<session>/pane/<pane id>
# with <port> 9333 unless SHEPHERD_BROWSER_PORT says otherwise, and <session>
# the herdr session the pane is in: "default", unless herdr was started with
# --session.
set -eu

if [ "${HERDR_ENV:-}" != 1 ] || [ -z "${HERDR_PANE_ID:-}" ]; then
    echo "shepherd-browser: not running in a herdr pane, so there is no Shepherd browser to connect to" >&2
    exit 1
fi
if ! command -v npx >/dev/null 2>&1; then
    echo "shepherd-browser: npx isn't on PATH; Playwright MCP needs Node.js" >&2
    exit 1
fi

# herdr's socket is .../herdr/herdr.sock for the default session and
# .../herdr/sessions/<name>/herdr.sock for a named one.
session=default
case "${HERDR_SOCKET_PATH:-}" in
    */sessions/*/herdr.sock)
        session="${HERDR_SOCKET_PATH%/herdr.sock}"
        session="${session##*/}"
        ;;
esac

exec npx -y @playwright/mcp@latest \
    --cdp-endpoint "ws://127.0.0.1:${SHEPHERD_BROWSER_PORT:-9333}/herdr/$session/pane/$HERDR_PANE_ID"
