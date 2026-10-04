#!/bin/sh
# Registers the `shepherd-browser` MCP server (mcp.sh, next to this script)
# with Claude Code and with Codex, whichever of them this machine has.
# Running it again replaces an earlier registration.
#
# Prints one line per agent, which Shepherd's Settings reads:
#   claude=registered|missing|failed
#   codex=registered|missing|failed
# "missing" means the agent's CLI isn't installed here.
set -u

NAME=shepherd-browser
here="$(cd "$(dirname "$0")" && pwd)"
# Run by sh rather than on its own, so that it works whether or not the way
# the skill was installed kept the file executable.
launcher="$here/mcp.sh"
# Every environment variable mcp.sh reads. Claude Code gives an MCP server
# its whole environment; Codex gives it only the variables named here.
env_vars='"HERDR_ENV", "HERDR_PANE_ID", "HERDR_SOCKET_PATH", "SHEPHERD_BROWSER_PORT"'

# Prints where an agent's CLI is. The places its installers use come first,
# then PATH, and last the person's shell, started the way a terminal starts
# it: its startup files are often the only thing that puts a Node version
# manager's bin directory on PATH, and neither an app nor an SSH command
# reads them. A login shell as well as an interactive one, since on a Mac
# Homebrew's PATH comes from ~/.zprofile, which only a login shell reads.
find_cli() {
    for dir in "$HOME/.local/bin" "$HOME/.claude/local" /opt/homebrew/bin /usr/local/bin; do
        if [ -x "$dir/$1" ]; then
            echo "$dir/$1"
            return 0
        fi
    done
    if command -v "$1" >/dev/null 2>&1; then
        command -v "$1"
        return 0
    fi
    shell="${SHELL:-/bin/zsh}"
    [ -x "$shell" ] || shell=/bin/sh
    # Marked, to tell the answer apart from anything the rc files print.
    found="$("$shell" -lic "printf '@@%s\n' \"\$(command -v $1)\"" </dev/null 2>/dev/null | sed -n 's/^@@//p' | tail -n 1)"
    if [ -n "$found" ] && [ -x "$found" ]; then
        echo "$found"
        return 0
    fi
    return 1
}

# A CLI installed with npm is a Node script, and the node it runs on sits in
# the same directory.
with_cli_path() {
    PATH="$(dirname "$1"):$PATH" "$@"
}

if claude="$(find_cli claude)"; then
    with_cli_path "$claude" mcp remove --scope user "$NAME" >/dev/null 2>&1
    if with_cli_path "$claude" mcp add --scope user "$NAME" -- /bin/sh "$launcher" >/dev/null 2>&1; then
        echo claude=registered
    else
        echo claude=failed
    fi
else
    echo claude=missing
fi

if codex="$(find_cli codex)"; then
    config="${CODEX_HOME:-$HOME/.codex}/config.toml"
    with_cli_path "$codex" mcp remove "$NAME" >/dev/null 2>&1
    # `codex mcp add` can't set env_vars, so the table is appended here. Not
    # while the config still has one by that name, though: a second would
    # leave the config unreadable, and Codex with it.
    if grep -Eq "^[[:space:]]*\[mcp_servers\.(\"$NAME\"|'$NAME'|$NAME)\]" "$config" 2>/dev/null; then
        echo codex=failed
    else
        mkdir -p "$(dirname "$config")"
        backup="$(mktemp)"
        had_config=0
        if [ -f "$config" ]; then
            cp "$config" "$backup"
            had_config=1
        fi
        printf "\n[mcp_servers.%s]\ncommand = '/bin/sh'\nargs = ['%s']\nenv_vars = [%s]\n" "$NAME" "$launcher" "$env_vars" >> "$config"
        if with_cli_path "$codex" mcp get "$NAME" >/dev/null 2>&1; then
            echo codex=registered
        else
            # Codex can't read the config as it now is: put it back.
            if [ "$had_config" = 1 ]; then
                cp "$backup" "$config"
            else
                rm -f "$config"
            fi
            echo codex=failed
        fi
        rm -f "$backup"
    fi
else
    echo codex=missing
fi
