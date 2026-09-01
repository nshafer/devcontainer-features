#!/usr/bin/env bash
# postAttach, as the remote user, on every window that connects.
#
# Reports rather than enforces -- it has no privileges to enforce with. It exists because a
# default-deny network fails in ways that look like anything but a firewall: a package install that
# times out, a git fetch that hangs. Saying plainly that egress is filtered, and where the lists
# came from, turns half an hour of confusion into one line.
set -uo pipefail
SHARE_DIR=/usr/local/share/devcontainer/egress-filter
"$SHARE_DIR/egress.sh" status || true
echo
echo "==> egress-filter: to allow a host:"
echo "      - Add a preset to the feature's devcontainer-feature.json (container restart required)"
echo "      - Global list at ~/.config/egress-filter/allowlist.txt on host (applies immediately)"
echo "      - Project list: .devcontainer/egress-allow.txt in the repo (container restart required)"
echo
echo "==> egress-filter: to view denied requests:"
echo "      - List of blocked requests and counts is available with 'egress-denied' in the container"
echo "      - Log of proxy requests is available at /var/log/devcontainer/egress-filter-proxy.log"
echo
exit 0
