#!/usr/bin/env bash
# Container start, as root, before anything attaches.
#
# Early matters here for the same reason it does in the sandbox feature: the rules have to be in
# place before the agent gets a shell. It is also why the firewall must not be the thing that breaks
# attaching -- see the baseline list, which keeps VS Code's own traffic allowed.
#
# Nothing here exits non-zero. A container that will not start is worse than one that starts with
# egress open and says so in the status output.
set -uo pipefail
[ "$(id -u)" = "0" ] || exit 0
LOG=/var/log/devcontainer/egress-filter.log
# Per-project directory rather than loose in /var/log, and >> will not create it for us.
install -d /var/log/devcontainer 2>/dev/null || true
{
    echo "=== egress-filter entrypoint $(date -Is)"
    /usr/local/share/devcontainer/egress-filter/egress.sh up
} >> "$LOG" 2>&1 || true
exit 0
