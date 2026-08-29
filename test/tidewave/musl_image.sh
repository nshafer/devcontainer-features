#!/usr/bin/env bash
set -e
source dev-container-features-test-lib

# The other side of the detection. Alpine has no glibc loader, so the gnu asset would not execute at
# all here -- and if it somehow did, the Bun it downloaded would not.
check "this is genuinely a musl image" bash -c '
    ldd --version 2>&1 | head -1
    ldd --version 2>&1 | grep -qi musl'

check "tidewave runs" tidewave --version

check "the musl asset was chosen" bash -c '
    /usr/local/share/devcontainer/tidewave/post-start.sh >/dev/null
    curl -sf --max-time 5 -X POST http://127.0.0.1:9000/about | tee /dev/stderr | grep -q "unknown-linux-musl"'

reportResults
