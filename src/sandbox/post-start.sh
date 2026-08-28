#!/usr/bin/env bash
# postStart, as the remote user. Belt and braces over the entrypoint, plus the part a human reads.
#
# The entrypoint has already sealed the fixed paths and started the sweeper by now, so ordinarily
# this only checks and reports. It earns its place in the case the entrypoint did not run at all --
# an orchestrator that skips feature entrypoints, or a project that overrides the container
# entrypoint -- where this is the last chance to notice and say so out loud.
#
# It runs unprivileged, so it cannot seal anything itself, and that is the honest division of
# labour: root does the sealing, this reports what is actually true afterwards. The one thing it
# can do that root cannot is read the forwarding manifest -- see check-manifest in sandbox.sh.
set -uo pipefail

SHARE_DIR=/usr/local/share/nshafer-sandbox

if ! pgrep -f 'sandbox\.sh daemon' >/dev/null 2>&1; then
    echo "!!! sandbox: the sweeper is not running, so the feature's entrypoint did not run." >&2
    echo "!!!   Check that nothing in this project overrides the container entrypoint." >&2
fi

# $$ is this script's pid: BASH_ENV has already scrubbed the variables out of this
# shell, but the kernel's copy of what it was exec'd with still has them.
"$SHARE_DIR/sandbox.sh" check-manifest "$$" || true
"$SHARE_DIR/sandbox.sh" report || true

exit 0
