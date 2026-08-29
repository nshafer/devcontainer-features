#!/usr/bin/env bash
# Runtime half: starts the Tidewave CLI, as the remote user, in the workspace folder.
#
# postStart rather than postCreate, because the process does not survive the container stopping and
# has to come back with it -- postCreate would leave a rebuilt-but-restarted container with nothing
# listening. It runs on every start, so the first thing it does is check whether an instance is
# already answering and leave it alone if so.
#
# The CLI is given no project path and has no flag for one: it serves its working directory, and
# the working directory of a feature's lifecycle command is the workspace folder. That is the whole
# reason this is a lifecycle hook and not the feature's entrypoint -- an entrypoint runs as root,
# from /, before the workspace is anyone's concern.
#
# Nothing here exits non-zero. A failure to start the IDE bridge is worth shouting about in the
# creation log, but it is not worth failing the container start over.
set -uo pipefail

# Written by install.sh with the option values baked in. The defaults are here so the script can be
# run directly -- the test suite does exactly that, since the harness runs no lifecycle hooks.
AUTOSTART=true
PORT=9000
ARGS="--port 9000 --allow-remote-access"
CONFIG=/usr/local/share/devcontainer/tidewave/config
# Generated at build time, so there is nothing for the linter to follow here.
# shellcheck source=/dev/null
[ -r "$CONFIG" ] && . "$CONFIG"

LOG="${TIDEWAVE_LOG:-/tmp/tidewave.log}"

if [ "$AUTOSTART" != "true" ]; then
    echo "==> tidewave: autostart is off; run 'tidewave $ARGS' yourself"
    exit 0
fi

# POST /about is the CLI's own identity endpoint; a plain GET on it is a 405. Using it as the probe
# means a port answered by something else does not read as "already running".
running() {
    curl -sf --max-time 2 -X POST "http://127.0.0.1:$PORT/about" 2>/dev/null | grep -q tidewave-cli
}

if running; then
    echo "==> tidewave: already listening on $PORT"
    exit 0
fi

if ! command -v tidewave >/dev/null 2>&1; then
    echo "!!! tidewave: the CLI is not on PATH; the feature's build stage did not finish" >&2
    exit 0
fi

# Without this the app opens container paths the host editor cannot resolve. It cannot be set from
# the feature -- a feature's containerEnv is emitted as a Dockerfile ENV, where ${localEnv:...} is
# not substituted -- so the project has to pass it through, and the most this can do is say so.
if [ -z "${TIDEWAVE_HOST_PATH:-}" ]; then
    echo "==> tidewave: TIDEWAVE_HOST_PATH is not set, so 'open in editor' will hand the host"
    echo "    container paths. Add to devcontainer.json:"
    # Printed verbatim: ${localEnv:...} is devcontainer.json syntax for the user to copy, not
    # something this shell should expand.
    # shellcheck disable=SC2016
    echo '      "remoteEnv": { "TIDEWAVE_HOST_PATH": "${localEnv:TIDEWAVE_HOST_PATH}" }'
fi

echo "==> tidewave: starting in $PWD, logging to $LOG"
# The CLI is silent unless it fails, so the log is empty on a healthy run -- stamp it, or an empty
# file reads like the process never started. Truncated per start: the container's previous run is
# gone, and so is anything its log could still explain.
{
    echo "=== tidewave $ARGS"
    echo "=== started $(date -Is) in $PWD by $(whoami)"
} > "$LOG"

# setsid puts it in its own session so it is not a child of the lifecycle shell the CLI is waiting
# on; nohup alone covers images without util-linux.
# $ARGS is unquoted on purpose: it is a flag string baked in at build time and has to split into
# separate arguments.
if command -v setsid >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    setsid nohup tidewave $ARGS >> "$LOG" 2>&1 < /dev/null &
else
    # shellcheck disable=SC2086
    nohup tidewave $ARGS >> "$LOG" 2>&1 < /dev/null &
fi
disown 2>/dev/null || true

for _ in $(seq 1 20); do
    running && break
    sleep 0.5
done

if running; then
    echo "==> tidewave: listening on $PORT"
else
    echo "!!! tidewave: did not come up on port $PORT within 10s. Log follows:" >&2
    sed 's/^/!!!   /' "$LOG" >&2
fi

exit 0
