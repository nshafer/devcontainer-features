#!/usr/bin/env bash
# Every option away from its default, which is the only way to know they are consulted at all.
#
# Runs as root, because one check reads the iptables chain and iptables answers nobody else. It
# cannot get there with sudo: sudo is setuid, and a container that carries no_new_privs -- which
# every container started by a dockerd inside a sandboxed dev container does -- refuses to run it.
# Root is not exempt from the filter (only the proxy uid is), so every check below still means what
# it says.
set -e
source dev-container-features-test-lib
fetch() { timeout 15 curl -s -o /dev/null -w "%{http_code}" -x "http://127.0.0.1:8888" "https://$1" 2>/dev/null || echo 000; }
export -f fetch

check "the options reached the config" bash -c '
    . /usr/local/share/devcontainer/egress-filter/config
    [ "$BASELINE" = false ]   || { echo "baseline: $BASELINE"; exit 1; }
    [ "$ALLOW_DNS" = false ]  || { echo "dns: $ALLOW_DNS"; exit 1; }
    [ "$PROXY_PORT" = 8888 ]  || { echo "port: $PROXY_PORT"; exit 1; }'

check "the proxy is on the configured port" bash -c '
    egress-status | tee /dev/stderr | grep -q "127.0.0.1:8888"'

check "baseline=false leaves the marketplace off the list" bash -c '
    ! grep -q "visualstudio" /etc/devcontainer/egress-filter/allow.regex \
        || { echo "baseline was merged despite baseline=false"; exit 1; }'

check "the allow option is honoured" bash -c '
    code=$(fetch example.com); echo "  example.com=$code"; [ "$code" = 200 ]'

# deny is applied last, so it overrides an allow for the same host.
check "deny overrides allow for the same host" bash -c '
    grep -q "iana" /etc/devcontainer/egress-filter/allow.regex \
        && { echo "denied host is still on the list"; exit 1; }
    code=$(fetch www.iana.org); echo "  www.iana.org=$code"; [ "$code" != 200 ]'

check "localNetworks=off leaves no local subnet in the chain" bash -c '
    for net in $(ip -4 route show scope link | awk "\$1 ~ /\\// { print \$1 }"); do
        iptables -S DEVCONTAINER_EGRESS | grep -q -- "-d $net -j ACCEPT" \
            && { echo "$net was opened despite localNetworks=off"; exit 1; }
        echo "  $net stays blocked, as configured"
    done
    egress-status | tee /dev/stderr | grep -q "local .*none"'

check "allowDns=false blocks the agent resolving for itself" bash -c '
    timeout 8 getent hosts example.com >/dev/null 2>&1 \
        && { echo "DNS still works despite allowDns=false"; exit 1; }
    echo "  resolution refused, as configured"'

check "allowDns=false leaves no accept on port 53 in the chain" bash -c '
    iptables -S DEVCONTAINER_EGRESS | grep -- "--dport 53" | grep -q ACCEPT \
        && { echo "port 53 is accepted despite allowDns=false"; exit 1; }
    egress-status | tee /dev/stderr | grep -q "dns .*blocked (allowDns=false)"'

# ...but the proxy resolves server-side, so allowed hosts still work without local DNS. That is the
# trade the README describes: the side channel closes, and anything resolving for itself breaks.
check "the proxy still reaches allowed hosts without local DNS" bash -c '
    code=$(fetch example.com); echo "  example.com via proxy=$code"; [ "$code" = 200 ]'

# deny is the one section that is not additive, so the file records it as a removal rather than
# silently omitting the host and leaving you wondering where it went.
check "a denied host is recorded as removed, not silently dropped" bash -c '
    f=/etc/devcontainer/egress-filter/allowlist.txt
    grep -q "REMOVED from everything above" "$f" || { echo "no deny section"; exit 1; }
    grep -q "^# removed: .iana.org" "$f" || { echo "deny entry not listed"; grep -A3 REMOVED "$f"; exit 1; }
    # ...and it really is gone from what the proxy reads.
    ! grep -q "iana" /etc/devcontainer/egress-filter/allow.regex || { echo "still in allow.regex"; exit 1; }'

# VS Code execs its server into the container as soon as the container runs, which can be seconds
# before this feature's entrypoint gets a turn. The environment probe the server runs then decides
# what the extension host and everything it starts carry, and nothing corrects it later. So the file
# goes into the image at build time.
#
# Provable here and not in the other scenarios: localNetworks is off, so the subnets `up` discovers
# add nothing, the content it would write is identical, and it leaves the file alone. The timestamp
# is then the build, which is before the entrypoint ran.
check "the profile.d file is in the image, so an early env probe finds it" bash -c '
    f=/etc/profile.d/00-devcontainer-egress-filter.sh
    grep -q "127.0.0.1:8888" "$f" || { cat "$f"; echo "the proxyPort option is not in it"; exit 1; }
    ts=$(sed -n "s/^=== egress-filter entrypoint //p" /var/log/devcontainer/egress-filter.log | head -1)
    [ -n "$ts" ] || { echo "no entrypoint timestamp in the log"; exit 1; }
    start=$(date -d "$ts" +%s)
    fm=$(stat -c %Y "$f")
    echo "  written $((start - fm))s before the entrypoint ran"
    [ "$fm" -lt "$start" ] || { echo "written at container start, not at build time"; exit 1; }'

# The other half of the same property: /etc/environment is written at container start and not at
# build time, because pam_env reads it for `su` and a later feature would then install through a
# proxy that does not exist yet.
check "/etc/environment carries the proxy, and was written at container start" bash -c '
    grep -q "^HTTP_PROXY=http://127.0.0.1:8888$" /etc/environment || {
        echo "no proxy in /etc/environment"; exit 1; }
    ts=$(sed -n "s/^=== egress-filter entrypoint //p" /var/log/devcontainer/egress-filter.log | head -1)
    fm=$(stat -c %Y /etc/environment)
    [ "$fm" -ge "$(date -d "$ts" +%s)" ] || { echo "written at build time, which pam_env would apply"; exit 1; }
    echo "  written by the entrypoint, as it must be"'

reportResults
