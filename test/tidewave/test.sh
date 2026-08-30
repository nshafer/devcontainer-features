#!/usr/bin/env bash
set -e
source dev-container-features-test-lib

# postStartCommand does not run in this harness, so drive the start script directly. Everything
# below the first check is really testing that script, which is the half that can only fail at
# runtime.
check "tidewave runs" tidewave --version
check "binary is on PATH at a system location" bash -c '[ "$(command -v tidewave)" = "/usr/local/bin/tidewave" ]'

# The whole point of detecting the libc: this image is Debian, so the gnu asset has to be the one
# that got installed. The CLI reports its own build triple, and that triple is what it uses to pick
# the Bun it downloads at first use -- a musl CLI here fetches a Bun this image cannot load.
check "the asset matches the image's libc" bash -c '
    ldd --version 2>&1 | head -1
    ! ldd --version 2>&1 | grep -qi musl || { echo "expected a glibc test image"; exit 1; }
    ldd /usr/local/bin/tidewave | grep -q "libc.so.6" || { echo "not linked against glibc"; exit 1; }'

check "default flags were baked in" bash -c '
    . /usr/local/share/devcontainer/tidewave/config
    [ "$AUTOSTART" = true ] || { echo "autostart: $AUTOSTART"; exit 1; }
    [ "$PORT" = 9000 ]      || { echo "port: $PORT"; exit 1; }
    case "$ARGS" in *--allow-remote-access*) ;; *) echo "args: $ARGS"; exit 1;; esac
    case "$ARGS" in *--debug*) echo "args: $ARGS"; exit 1;; esac'

check "post-start brings it up" bash -c '
    out=$(/usr/local/share/devcontainer/tidewave/post-start.sh)
    echo "$out"
    echo "$out" | grep -q "listening on 9000"'

check "it identifies itself on the configured port" bash -c '
    curl -sf --max-time 5 -X POST http://127.0.0.1:9000/about | tee /dev/stderr | grep -q "\"http_port\":9000"'

# Belt and braces on the check above, from the CLI's own mouth rather than from ldd: this is the
# string it derives the Bun download name from.
check "it reports a gnu target, so it will fetch a gnu Bun" bash -c '
    curl -sf --max-time 5 -X POST http://127.0.0.1:9000/about | grep -q "unknown-linux-gnu"'

# The point of --allow-remote-access. Bound to loopback the process is unreachable through a
# published port, because Docker forwards to the container bridge address and not to its loopback.
# 2328 is 9000 in hex; 00000000 is 0.0.0.0.
check "it is bound to 0.0.0.0, not loopback" bash -c '
    awk "{print \$2}" /proc/net/tcp | grep -qi "^00000000:2328$"'

# Bound wide, the CLI is still not open to the world: it checks the Origin header itself.
check "a foreign origin is still refused" bash -c '
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -X POST \
        -H "Origin: http://192.0.2.5:9000" http://127.0.0.1:9000/about)
    [ "$code" = 403 ] || { echo "got $code"; exit 1; }'

check "an origin of localhost is accepted" bash -c '
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -X POST \
        -H "Origin: http://localhost:9000" http://127.0.0.1:9000/about)
    [ "$code" = 200 ] || { echo "got $code"; exit 1; }'

# postStart runs on every container start, so a second run must find the first and not stack a
# second process on a port that is already taken.
check "a second run leaves the running instance alone" bash -c '
    /usr/local/share/devcontainer/tidewave/post-start.sh | grep -q "already listening"
    [ "$(pgrep -c -x tidewave)" = 1 ] || { pgrep -a -x tidewave; exit 1; }'

check "the log says what was started" bash -c '
    grep -q "allow-remote-access" /tmp/tidewave.log'

# Temp files are put beside the Bun runtime under ~/.cache/tidewave, so persist-homedir keeps both
# or keeps neither. The CLI takes no flag for a temp directory, which is why this is TMPDIR.
check "the temp dir was created under the home directory" bash -c '
    ls -ldn "$HOME/.cache/tidewave/tmp"
    [ -w "$HOME/.cache/tidewave/tmp" ]'

check "the log records the temp dir it chose" bash -c '
    grep -q "^=== tmpdir $HOME/.cache/tidewave/tmp$" /tmp/tidewave.log'

# The CLI takes no flag for a temp directory, so TMPDIR is the whole mechanism. Reading it back out
# of the running process is the only proof that the export reached the daemon: post-start hands it
# over through the environment, and setsid detaches the process from the shell that set it.
check "TMPDIR reached the running process" bash -c '
    pid=$(pgrep -x tidewave | head -1)
    tr "\0" "\n" < /proc/$pid/environ | grep TMPDIR | tee /dev/stderr | grep -qx "TMPDIR=$HOME/.cache/tidewave/tmp"'

# The feature cannot set this itself -- containerEnv is a Dockerfile ENV and ${localEnv:...} is not
# substituted there -- so the least it can do is tell you when the project has not passed it in.
check "an unset TIDEWAVE_HOST_PATH is called out" bash -c '
    pkill -x tidewave; sleep 1
    env -u TIDEWAVE_HOST_PATH TIDEWAVE_LOG=/tmp/tidewave-hostpath.log \
        /usr/local/share/devcontainer/tidewave/post-start.sh | grep -q "TIDEWAVE_HOST_PATH is not set"'

# The fallback. An unwritable temp directory is a cost, and losing the bridge over it would be a
# fault, so the start goes ahead on the default temp directory instead. /proc stands in for the
# unwritable directory: it exists, so mkdir -p succeeds, and the remote user cannot write to it.
check "an unwritable temp dir warns but still starts the CLI" bash -c '
    pkill -x tidewave; sleep 1
    out=$(TIDEWAVE_TMP_DIR=/proc TIDEWAVE_LOG=/tmp/tidewave-fallback.log \
        /usr/local/share/devcontainer/tidewave/post-start.sh 2>&1)
    echo "$out"
    echo "$out" | grep -q "/proc is not writable"
    echo "$out" | grep -q "listening on 9000"
    grep -q "^=== tmpdir <default>$" /tmp/tidewave-fallback.log'

reportResults
