#!/usr/bin/env bash
# Build-time half: make sure git exists and stash the script that does the copying.
#
# The copying itself cannot happen here — the host's files arrive as mounts, and mounts do not
# exist during the build — so it runs from post-create.sh instead.
set -euo pipefail

if ! command -v git >/dev/null 2>&1; then
    echo "==> git-config: installing git"
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y --no-install-recommends git ca-certificates
        rm -rf /var/lib/apt/lists/*
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache git ca-certificates
    else
        echo "!!! git-config: no git and no known package manager" >&2
        exit 1
    fi
fi

install -d /usr/local/share/devcontainer/git-config
install -m 0755 post-create.sh /usr/local/share/devcontainer/git-config/post-create.sh

echo "==> git-config: build stage done ($(git --version))"
