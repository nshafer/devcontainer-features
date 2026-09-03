#!/usr/bin/env bash
# localNetworks set to a subnet this container is definitely not on, which is the only way to tell
# "the option was applied" apart from "the container's own subnet happened to be opened".
#
# 192.168.222.0/24 is private, so it passes the shape check, and no docker network in CI uses it.
#
# Runs as root, to read the iptables chain. See the note at the top of strict.sh for why sudo is not
# an option here.
set -e
source dev-container-features-test-lib

fetch() { timeout 15 curl -s -o /dev/null -w "%{http_code}" -x "http://127.0.0.1:3128" "https://$1" 2>/dev/null || echo 000; }
export -f fetch

check "the options reached the config" bash -c '
    . /usr/local/share/devcontainer/egress-filter/config
    [ "$LOCAL_NETWORKS" = 192.168.222.0/24 ] || { echo "localNetworks: $LOCAL_NETWORKS"; exit 1; }
    [ "$NO_PROXY_EXTRA" = "db,redis" ]       || { echo "noProxy: $NO_PROXY_EXTRA"; exit 1; }'

check "the configured subnet is accepted by destination" bash -c '
    rules=$(iptables -S DEVCONTAINER_EGRESS | grep -- "-d 192.168.222.0/24" || true)
    echo "${rules:-  (none)}" | sed "s/^/  /"
    echo "$rules" | grep -q -- "-j ACCEPT" || { echo "the subnet was not opened"; exit 1; }'

# An explicit list replaces the detected one, the same way dnsServers replaces resolv.conf: a
# network you did not name is one you did not decide to trust.
check "the containers own subnet is not opened as well" bash -c '
    for net in $(ip -4 route show scope link | awk "\$1 ~ /\\// { print \$1 }"); do
        iptables -S DEVCONTAINER_EGRESS | grep -q -- "-d $net .*ACCEPT" \
            && { echo "$net was opened despite localNetworks naming another subnet"; exit 1; }
        echo "  $net is not open, as configured"
    done
    true'

check "egress-status names the local subnet" bash -c '
    egress-status | tee /dev/stderr | grep -q "local .*192.168.222.0/24"'

# The CIDR and the service names both land in the environment, because the firewall allowing a peer
# is only half of it -- a client that reads HTTP_PROXY would still send the request to the proxy.
check "NO_PROXY carries the named services, and the proxy carries the subnet" bash -c '
    grep "^NO_PROXY=" /etc/environment | tee /dev/stderr | grep -q "192.168.222.0/24" \
        && { echo "the subnet is in NO_PROXY, which ties the block to this machine"; exit 1; }
    grep -q "^NO_PROXY=.*\bdb\b.*\bredis\b" /etc/environment \
        || { echo "the noProxy services are not in NO_PROXY"; exit 1; }
    grep -q "^\^192\\\\.168\\\\.222\\\\.\[0-9\]{1,3}\$$" /etc/devcontainer/egress-filter/allow.regex \
        || { grep "^\^[0-9]" /etc/devcontainer/egress-filter/allow.regex; echo "no address pattern for the subnet"; exit 1; }
    echo "  the subnet is an address pattern in the proxy: $(grep "^\^192" /etc/devcontainer/egress-filter/allow.regex)"
    . /etc/profile.d/00-devcontainer-egress-filter.sh
    case "$NO_PROXY" in *db,redis*) echo "  profile.d agrees: $NO_PROXY" ;;
        *) echo "profile.d disagrees: $NO_PROXY"; exit 1 ;; esac'

# Opening a local subnet must not open anything else. The destination match is what guarantees it:
# a packet to the internet carries an address outside the subnet.
check "a host on no list is still blocked" bash -c '
    code=$(fetch neverallowed.example.net); echo "  neverallowed.example.net=$code"
    [ "$code" != 200 ] || { echo "local networks opened the internet as well"; exit 1; }'

check "an allowed host still works" bash -c '
    code=$(fetch example.com); echo "  example.com=$code"; [ "$code" = 200 ]'

reportResults
