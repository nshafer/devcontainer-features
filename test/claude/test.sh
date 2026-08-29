#!/usr/bin/env bash
set -e
source dev-container-features-test-lib

# Default options: the CLI is installed at build time and nothing is seeded. The seeding itself is
# covered by the seeded_settings scenario, which is the only way to pass an option.
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

# The file itself still exists with no settings option: the installer writes autoUpdatesChannel into
# it when given a version target. What must not be there is anything this feature seeded.
check "nothing is seeded when the option is empty" bash -c '
    [ ! -e "$HOME/.claude/settings.json" ] ||
    ! grep -qE "includeCoAuthoredBy|cleanupPeriodDays" "$HOME/.claude/settings.json"'

reportResults
