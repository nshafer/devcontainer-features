#!/usr/bin/env bash
# postAttach, as the remote user, on every window that connects.
#
# Reports rather than enforces -- it has no privileges to enforce with. It exists because a
# default-deny network fails in ways that look like anything but a firewall: a package install that
# times out, a git fetch that hangs. Saying plainly that egress is filtered, and where the lists
# came from, turns half an hour of confusion into one line.
set -uo pipefail
SHARE_DIR=/usr/local/share/nshafer-egress-filter
"$SHARE_DIR/egress.sh" status || true
echo
echo "==> egress-filter: to allow a host:"
echo "      - add a preset to the feature's devcontainer-feature.json (container restart required)"
echo "      - global list at ~/.config/egress-filter/allowlist.txt on host (applies immediately)"
echo "      - project list: .devcontainer/egress-allow.txt in the repo (container restart required)"
echo
echo " ==> egress-filter: list of blocked requests and counts is available with 'egress-denied' in the container"
echo
exit 0
