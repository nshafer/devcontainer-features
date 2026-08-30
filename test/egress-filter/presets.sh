#!/usr/bin/env bash
# Presets and the denial log: the two things that make an allowlist maintainable rather than a
# guessing game.
#
# Runs as root, to rebuild the allowlist with egress.sh. See the note at the top of strict.sh for
# why sudo is not an option here.
set -e
source dev-container-features-test-lib

check "the named presets were merged" bash -c '
    . /usr/local/share/devcontainer/egress-filter/config
    [ "$PRESETS" = "debian,npm,go" ] || { echo "presets: $PRESETS"; exit 1; }
    egress-status | tee /dev/stderr | grep -q "presets: .*debian.*npm.*go"'

check "each preset contributed its hosts" bash -c '
    f=/etc/devcontainer/egress-filter/allow.regex
    grep -q "deb\\\\.debian\\\\.org" "$f"    || { echo "debian preset missing"; exit 1; }
    grep -q "registry\\\\.npmjs\\\\.org" "$f" || { echo "npm preset missing"; exit 1; }
    grep -q "proxy\\\\.golang\\\\.org" "$f"   || { echo "go preset missing"; exit 1; }'

check "a preset that was not asked for is absent" bash -c '
    ! grep -q "repo\\\\.hex\\\\.pm" /etc/devcontainer/egress-filter/allow.regex \
        || { echo "hex leaked in without being requested"; exit 1; }'

# An unknown preset must be loud. Silently ignoring it is the failure mode that costs an afternoon.
check "an unknown preset warns and lists the real ones" bash -c '
    out=$(env EGRESS_PRESETS="debian,nosuchthing" \
        /usr/local/share/devcontainer/egress-filter/egress.sh build 2>&1)
    echo "$out" | sed "s/^/  /"
    echo "$out" | grep -q "no such preset: nosuchthing" || { echo "no warning"; exit 1; }
    echo "$out" | grep -q "have:.*hex" || { echo "did not list the available presets"; exit 1; }
    # ...and the valid name alongside it still worked, so one typo does not void the rest.
    grep -q "debian" /etc/devcontainer/egress-filter/allow.regex || { echo "debian preset lost"; exit 1; }
    echo "  ok"'

# Put the configured presets back, since the check above deliberately rebuilt with a different set.
check "the configured presets are restored by a rebuild" bash -c '
    /usr/local/share/devcontainer/egress-filter/egress.sh reload >/dev/null 2>&1 \
        || { echo "reload failed"; exit 1; }
    grep -q "golang" /etc/devcontainer/egress-filter/allow.regex || { echo "go preset did not come back"; exit 1; }
    echo "  presets restored"'

check "a preset host is actually reachable" bash -c '
    code=$(timeout 20 curl -s -o /dev/null -w "%{http_code}" -x http://127.0.0.1:3128 https://registry.npmjs.org/ || echo 000)
    echo "  registry.npmjs.org=$code"; [ "$code" = 200 ]'

# ---------------------------------------------------------------------------------------------
# egress-denied. The proxy runs as its own uid and drops privileges before opening its log, so the
# log has to be pre-created owned by that uid and world-readable -- otherwise every denial is lost
# silently, which is exactly the record you need.
# ---------------------------------------------------------------------------------------------

# The mode rather than a read as the remote user, because this scenario runs as root and root can
# read the file whatever its mode says. What has to hold is that the *others* bit is set, since the
# log is owned by the proxy uid and egress-denied is run by the person, not by root.
check "the proxy log is world-readable, so egress-denied works without root" bash -c '
    f=/var/log/devcontainer/egress-filter-proxy.log
    [ "$(stat -c %U "$f")" = egressfilter ] || { echo "owner: $(stat -c %U "$f")"; exit 1; }
    mode=$(stat -c %a "$f"); echo "  mode $mode"
    case "$mode" in *[4567]) ;; *) echo "not readable by others"; exit 1 ;; esac'

check "egress-denied reports nothing before anything is refused" bash -c '
    egress-denied | tee /dev/stderr | grep -q "nothing has been refused"'

check "egress-denied lists refused hosts with counts" bash -c '
    for _ in 1 2 3; do
        timeout 8 curl -s -o /dev/null -x http://127.0.0.1:3128 https://denied-a.example.net || true
    done
    timeout 8 curl -s -o /dev/null -x http://127.0.0.1:3128 https://denied-b.example.net || true
    sleep 1
    out=$(egress-denied); echo "$out"
    echo "$out" | grep -q "denied-a.example.net" || { echo "missing denied-a"; exit 1; }
    echo "$out" | grep -q "denied-b.example.net" || { echo "missing denied-b"; exit 1; }
    # The count is the point: it tells you what the build kept retrying.
    echo "$out" | grep -E "^\s+3\s+denied-a" >/dev/null || { echo "count not aggregated"; exit 1; }
    echo "$out" | grep -q "egress-filter/allowlist.txt"'

reportResults
