#!/usr/bin/env bash
# postAttach, as the remote user, on every window that connects.
#
# Attaching is the event this whole feature is about: each new VS Code window forwards a fresh set
# of sockets with fresh UUIDs in their names, which is why a bounded background loop is not enough
# and why the sweeper runs for the life of the container. The daemon has almost certainly sealed
# this window's set already -- it seals on the kernel's create event, so within a millisecond or so
# of each socket appearing -- so this is here to confirm that from the one vantage point that can,
# and to be loud if it did not.
#
# Quiet on success. A hook that prints a wall of text on every attach is a hook people stop reading.
set -uo pipefail

SHARE_DIR=/usr/local/share/nshafer-sandbox

# $$ is this script's pid. BASH_ENV has already scrubbed the forwarded variables out of this
# shell, but the kernel's copy of what it was exec'd with still holds them, and that is what
# check-manifest reads.
if ! "$SHARE_DIR/sandbox.sh" check-manifest "$$"; then
    echo "!!! sandbox: this window forwarded a channel that is still open. Full state:" >&2
    "$SHARE_DIR/sandbox.sh" status || true
fi

exit 0
