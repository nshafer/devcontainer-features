#!/usr/bin/env bash
set -e
source dev-container-features-test-lib

check "claude runs" claude --version
check "settings file was seeded" test -s "$HOME/.claude/settings.json"

check "the seeded values are there" bash -c '
    node -e "
      const s = require(process.env.HOME + \"/.claude/settings.json\");
      if (s.includeCoAuthoredBy !== false) { console.error(\"includeCoAuthoredBy:\", s.includeCoAuthoredBy); process.exit(1); }
      if (s.cleanupPeriodDays !== 45) { console.error(\"cleanupPeriodDays:\", s.cleanupPeriodDays); process.exit(1); }
    "'

# Seeding happens before the installer, which merges its own key in rather than replacing the file.
# If that order ever flips, this is what catches it.
check "the installer merged rather than replaced" bash -c '
    grep -q autoUpdatesChannel "$HOME/.claude/settings.json"'

check "settings belong to the remote user and stay writable" bash -c '
    [ "$(stat -c %U "$HOME/.claude/settings.json")" = "$(whoami)" ] &&
    [ -w "$HOME/.claude/settings.json" ]'

reportResults
