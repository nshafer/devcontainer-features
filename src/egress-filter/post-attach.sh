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
echo "==> egress-filter: to allow a host, add it to the global list on your host machine (applies"
echo "    live), or to the project list and restart the container."
echo "    A blocked request shows up as a bare 403 -- see"
echo "    /usr/local/share/nshafer-egress-filter/BLOCKED.md"
exit 0
