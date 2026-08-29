#!/usr/bin/env bash
set -e
source dev-container-features-test-lib

check "the port option reached the config" bash -c '
    . /usr/local/share/devcontainer/tidewave/config
    [ "$PORT" = 9876 ] || { echo "port: $PORT"; exit 1; }'

check "allowRemoteAccess=false drops the flag" bash -c '
    . /usr/local/share/devcontainer/tidewave/config
    case "$ARGS" in *--allow-remote-access*) echo "args: $ARGS"; exit 1;; esac'

# This scenario carries every boolean off its default, so it is where flag composition gets
# checked. debug=true is the third flag, and the checks below prove it reaches the command line
# and that the CLI still comes up with it.
check "debug=true adds the flag" bash -c '
    . /usr/local/share/devcontainer/tidewave/config
    case "$ARGS" in *--debug*) ;; *) echo "args: $ARGS"; exit 1;; esac'

check "post-start brings it up on the custom port" bash -c '
    /usr/local/share/devcontainer/tidewave/post-start.sh | grep -q "listening on 9876"'

check "the log records the debug flag" bash -c '
    grep -q -- "--debug" /tmp/tidewave.log'

check "it reports the custom port" bash -c '
    curl -sf --max-time 5 -X POST http://127.0.0.1:9876/about | grep -q "\"http_port\":9876"'

# 2694 is 9876 in hex, 0100007F is 127.0.0.1. Without the flag the CLI binds loopback only, which
# is why the default turns it on -- a published port cannot reach this.
check "without the flag it binds loopback only" bash -c '
    awk "{print \$2}" /proc/net/tcp | grep -qi "^0100007F:2694$"
    ! awk "{print \$2}" /proc/net/tcp | grep -qi "^00000000:2694$"'

reportResults
