#!/usr/bin/env bash
set -e
source dev-container-features-test-lib

# The CLI is installed at build time, and the feature writes no settings of its own.
check "claude runs" claude --version
check "wrapper is on PATH" bash -c '[ "$(command -v claude)" = "/usr/local/bin/claude" ] || [ -x /usr/local/bin/claude ]'
check "home install is the canonical layout" bash -c '
    [ -L "$HOME/.local/bin/claude" ] &&
    readlink "$HOME/.local/bin/claude" | grep -q "/.local/share/claude/versions/"'
check "system fallback exists" test -x /usr/local/share/devcontainer/claude/claude
check "wrapper prefers the home copy" bash -c '
    grep -q "HOME/.local/bin/claude" /usr/local/bin/claude'
check "wrapper works when the home copy is gone" bash -c '
    env HOME=/nonexistent /usr/local/bin/claude --version'

# What this feature deliberately does not do. The config dir is the CLI's default, so the
# container's credentials, transcripts and file history are its own and stay inside it.
check "config dir is not redirected" bash -c '[ -z "${CLAUDE_CONFIG_DIR:-}" ]'
check "~/.claude is a real directory, not a mount" bash -c '
    [ -d "$HOME/.claude" ] && [ ! -L "$HOME/.claude" ]'
check "nothing from the host's ~/.claude is mounted" bash -c '
    ! grep -qE " /mnt/claude(-config|-settings\.json)? " /proc/mounts'
check "nothing runs at postCreate any more" bash -c '
    [ ! -e /usr/local/share/devcontainer/claude/post-create.sh ]'

# The file can still exist: the installer writes autoUpdatesChannel into it when given a version
# target. Nothing else in it comes from this feature.
check "the feature seeds no settings" bash -c '
    [ ! -e "$HOME/.claude/settings.json" ] ||
    [ "$(node -e "console.log(Object.keys(require(process.env.HOME + \"/.claude/settings.json\")).filter(k => k !== \"autoUpdatesChannel\").length)")" = "0" ]'

reportResults
