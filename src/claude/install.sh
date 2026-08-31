#!/usr/bin/env bash
# Installs the Claude Code CLI at build time with the native installer, run as the remote user so
# the result is the layout the CLI's own updater expects: ~/.local/share/claude/versions/<version>
# with a ~/.local/bin/claude symlink pointing at it.
#
# That home directory is frequently a volume (see the persist-homedir feature), and a volume that
# already has content masks whatever the image put there — so the resolved binary is also copied
# to a system path, and /usr/local/bin/claude is a wrapper that prefers the home copy and falls
# back to the system one. Whichever way the home directory ends up, `claude` resolves and runs.
set -euo pipefail

VERSION="${VERSION:-stable}"
SYSTEM_DIR=/usr/local/share/devcontainer/claude

USERNAME="${_REMOTE_USER:-root}"
USER_HOME="${_REMOTE_USER_HOME:-}"
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
    # _REMOTE_USER_HOME is resolved before features install, so it is empty when another
    # feature (common-utils) is what creates the user.
    USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
fi
: "${USER_HOME:=/home/$USERNAME}"

echo "==> claude: user=$USERNAME home=$USER_HOME version=$VERSION"

# The installer needs curl and TLS roots; it downloads everything else itself.
if ! command -v curl >/dev/null 2>&1; then
    echo "==> claude: installing curl"
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y --no-install-recommends curl ca-certificates
        rm -rf /var/lib/apt/lists/*
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl ca-certificates
    else
        echo "!!! claude: no curl and no known package manager" >&2
        exit 1
    fi
fi

# The musl build needs these; untested here, taken from the upstream feature.
if command -v apk >/dev/null 2>&1; then
    apk add --no-cache libgcc libstdc++ ripgrep
fi

echo "==> claude: running the native installer as $USERNAME"
su -l "$USERNAME" -c "curl -fsSL https://claude.ai/install.sh | bash -s '$VERSION'"

LAUNCHER="$USER_HOME/.local/bin/claude"
if [ ! -e "$LAUNCHER" ]; then
    echo "!!! claude: installer finished but $LAUNCHER is missing" >&2
    exit 1
fi

# ~/.local/bin/claude is a symlink into the versions directory; resolve it to the real binary.
BINARY="$(readlink -f "$LAUNCHER")"
install -d "$SYSTEM_DIR"
# A hard link, so the ~240MB binary is stored once in this layer rather than twice. Both names
# share an inode, which also means the system copy survives the updater retiring old versions.
# Falls back to a real copy if the two paths are not on the same filesystem.
cp -l "$BINARY" "$SYSTEM_DIR/claude" 2>/dev/null || cp "$BINARY" "$SYSTEM_DIR/claude"
chmod 0755 "$SYSTEM_DIR/claude"

# Resolves `claude` for every shell, not just interactive ones that sourced the installer's shell
# integration — and prefers the home copy, so a self-update is picked up instead of being shadowed
# by a system copy frozen at image build time.
cat > /usr/local/bin/claude <<WRAPPER
#!/bin/sh
# Installed by the claude devcontainer feature.
if [ -x "\$HOME/.local/bin/claude" ]; then
    exec "\$HOME/.local/bin/claude" "\$@"
fi
exec $SYSTEM_DIR/claude "\$@"
WRAPPER
chmod 0755 /usr/local/bin/claude

echo "==> claude: installed $("$SYSTEM_DIR/claude" --version 2>/dev/null || echo unknown)"
