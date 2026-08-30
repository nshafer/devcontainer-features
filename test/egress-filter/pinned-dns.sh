#!/usr/bin/env bash
# dnsServers set to something that is deliberately not the container's own resolver, which is the
# only way to tell "the firewall pinned port 53" apart from "port 53 happens to work".
#
# 192.0.2.53 is TEST-NET-1, reserved for documentation. It can never be a real resolver, so nothing
# below depends on what DNS the machine running the tests uses.
#
# Runs as root, to read the iptables chain. See the note at the top of strict.sh for why sudo is not
# an option here.
set -e
source dev-container-features-test-lib

fetch() { timeout 15 curl -s -o /dev/null -w "%{http_code}" -x "http://127.0.0.1:3128" "https://$1" 2>/dev/null || echo 000; }
export -f fetch

check "the option reached the config" bash -c '
    . /usr/local/share/devcontainer/egress-filter/config
    [ "$DNS_SERVERS" = 192.0.2.53 ] || { echo "dnsServers: $DNS_SERVERS"; exit 1; }'

check "port 53 is pinned to the configured address and nothing else" bash -c '
    dns=$(iptables -S DEVCONTAINER_EGRESS | grep -- "--dport 53" || true)
    echo "$dns" | sed "s/^/  /"
    [ -n "$dns" ] || { echo "no DNS rules at all"; exit 1; }
    # One accept per protocol, both naming the configured address.
    [ "$(echo "$dns" | grep -c -- "-d 192.0.2.53")" = 2 ] \
        || { echo "expected a udp and a tcp accept for 192.0.2.53"; exit 1; }
    [ "$(echo "$dns" | grep -c -- "-j ACCEPT")" = 2 ] \
        || { echo "something else is accepted on 53"; exit 1; }'

# The option replaces resolv.conf rather than adding to it, which is the whole reason to set it:
# a resolver you did not ask for is one you did not decide to trust.
check "the resolver from resolv.conf is not pinned as well" bash -c '
    dns=$(iptables -S DEVCONTAINER_EGRESS | grep -- "--dport 53" || true)
    for ns in $(sed -n "s/^nameserver  *//p" /etc/resolv.conf); do
        case "$ns" in *:* | 192.0.2.53) continue ;; esac
        echo "$dns" | grep -q -- " -d $ns" \
            && { echo "$ns was pinned despite dnsServers naming another address"; exit 1; }
        echo "  $ns is not on the list, as configured"
    done
    true'

check "egress-status names the configured resolver" bash -c '
    egress-status | tee /dev/stderr | grep -q "port 53 to 192.0.2.53"'

# The proxy is exempt by uid and resolves server-side, so allowed hosts keep working even when the
# container itself has been pointed at a resolver it cannot reach. That separation is what makes
# pinning safe to get wrong: you lose local resolution, not the network.
check "the proxy still reaches allowed hosts" bash -c '
    code=$(fetch example.com); echo "  example.com via proxy=$code"; [ "$code" = 200 ]'

reportResults
