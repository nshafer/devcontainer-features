#!/usr/bin/env bash
set -e
source dev-container-features-test-lib

check "the CLI is still installed" tidewave --version

check "post-start starts nothing and says why" bash -c '
    out=$(/usr/local/share/devcontainer/tidewave/post-start.sh)
    echo "$out"
    echo "$out" | grep -q "autostart is off"
    ! pgrep -x tidewave'

reportResults
