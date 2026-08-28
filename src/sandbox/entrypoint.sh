#!/usr/bin/env bash
# Container start, as root, before anything else the container will do.
#
# This is the earliest hook a feature gets, and being early is the whole value: the CLI runs each
# feature's entrypoint inline and then execs the real command, so this finishes before VS Code has
# attached and therefore before any socket has been forwarded. A lifecycle hook cannot say that --
# postStart runs after the server is already up, which is a race this does not have to run.
#
# Two jobs: re-assert the fixed blocks (the image's copy of them is masked wherever the path turned
# out to be a volume), then leave a sweeper behind for the paths that carry a UUID.
#
# Nothing here exits non-zero. A container that fails to start is worse than one that starts with a
# channel open and says so in the report.
set -uo pipefail

SHARE_DIR=/usr/local/share/nshafer-sandbox
LOG=/var/log/nshafer-sandbox.log

[ "$(id -u)" = "0" ] || exit 0

{
    echo "=== sandbox entrypoint $(date -Is)"
    # Repair first, and before anything else touches these paths: a directory an older version of
    # this feature sealed will stop VS Code attaching at all, and the persisted home volume means
    # it outlives the rebuild that was supposed to fix it.
    "$SHARE_DIR/sandbox.sh" repair
    # Before the daemon and before anything is attached: with sudo in hand the remote user can undo
    # every seal below, so this is the one that has to hold for the rest to mean anything.
    "$SHARE_DIR/sandbox.sh" drop-sudo
    "$SHARE_DIR/sandbox.sh" block-fixed
} >> "$LOG" 2>&1 || true

# Already swept by a previous start of this same container? Do not stack a second daemon.
if pgrep -f 'sandbox\.sh daemon' >/dev/null 2>&1; then
    exit 0
fi

# setsid so it belongs to its own session and is not killed with the entrypoint's process group
# when the CLI execs the container command over it. nohup alone covers images with no util-linux.
if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$SHARE_DIR/sandbox.sh" daemon >> "$LOG" 2>&1 < /dev/null &
else
    nohup "$SHARE_DIR/sandbox.sh" daemon >> "$LOG" 2>&1 < /dev/null &
fi
disown 2>/dev/null || true

exit 0
