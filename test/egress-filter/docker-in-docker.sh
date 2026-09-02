#!/usr/bin/env bash
# An inner Docker daemon, which is the one arrangement that walks around the OUTPUT chain.
#
# Two separate holes, and this scenario measures both. The daemon itself runs as root, so its pulls
# land on the REJECT and read as a registry timeout. A container the daemon starts has its own
# network namespace, so its packets are FORWARDed rather than OUTPUT and `-m owner` never sees them
# at all -- `docker run alpine wget https://anywhere` used to be a complete bypass of the feature.
#
# Root, and not sudo, for the reason privileged.sh gives: sudo is setuid and no_new_privs refuses
# it. Root is not exempt from the filter, so every reachability check below still measures the
# filter rather than a hole in it.
set -e
source dev-container-features-test-lib

# dockerd is started by the docker-in-docker entrypoint, which runs after this feature's. It is up
# within a second or two of attach, but "within" is not "already", so the suite waits for it once
# rather than each check racing it separately.
check "the inner daemon comes up" bash -c '
    for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 1; done
    docker info >/dev/null 2>&1 || { echo "dockerd never started"; exit 1; }
    echo "  dockerd is up"'

# The daemon reads neither /etc/environment nor /etc/profile.d, so a daemon.json is the only channel
# the feature has to it. 127.0.0.1 is right here and not a mistake: dockerd shares this container's
# network namespace, so the -o lo rule lets it through.
check "the daemon was pointed at the proxy" bash -c '
    cat /etc/docker/daemon.json | sed "s/^/  /"
    grep -q "127.0.0.1:3128" /etc/docker/daemon.json || { echo "no proxy in daemon.json"; exit 1; }
    docker info 2>/dev/null | grep -i "http proxy" | sed "s/^/  /" | grep -q 3128 \
        || { echo "the running daemon did not read it"; exit 1; }'

# Which is what makes a pull work at all. Any image will do; alpine is the smallest one the docker
# preset allows.
check "the daemon can pull through the proxy" bash -c '
    timeout 180 docker pull alpine:latest >/dev/null 2>&1 || { echo "the pull failed"; exit 1; }
    echo "  alpine:latest pulled"'

# The client half, copied by `docker run` into every container it starts. 127.0.0.1 would be the
# inner container's own loopback, so this one has to name the address of the container we are in.
check "containers are told where the proxy is" bash -c '
    cat ~/.docker/config.json | sed "s/^/  /"
    ip=$(ip -4 route show default | sed -n "s/.* dev \([^ ]*\).*/\1/p")
    addr=$(ip -4 -o addr show dev "$ip" scope global | awk "{ print \$4 }" | cut -d/ -f1 | head -1)
    grep -q "$addr:3128" ~/.docker/config.json \
        || { echo "config.json does not point at $addr"; exit 1; }'

# The property the whole scenario exists for. Before the FORWARD rules this returned the page.
#
# The proxy variables are cleared on the command line, which beats the ones the client config
# injects. That is the point: this has to measure the firewall and not the proxy, and a container
# that politely used the proxy would be denied by the allowlist instead and prove nothing. The host
# resolves, so a failure here is the deny and not a missing DNS answer.
check "a container that ignores the proxy cannot get out" bash -c '
    out=$(timeout 60 docker run --rm \
        -e http_proxy= -e https_proxy= -e HTTP_PROXY= -e HTTPS_PROXY= \
        alpine:latest wget -q -O- -T 10 http://example.org 2>&1 || true)
    echo "  ${out:-<nothing>}" | head -2
    echo "$out" | grep -qi "<html" && { echo "the container reached the internet"; exit 1; }
    echo "  blocked"'

# The proxy path denies it too, for a different reason: not on the allowlist. Both roads closed.
check "a container that uses the proxy is still held to the list" bash -c '
    out=$(timeout 60 docker run --rm alpine:latest \
        wget -q -O- -T 20 http://example.org 2>&1 || true)
    echo "  ${out:-<nothing>}" | head -2
    echo "$out" | grep -qi "iana\|<h1>Example Domain" && { echo "an unlisted host was served"; exit 1; }
    echo "  denied"'

# And the other half of it: allowed is still allowed, through the proxy the client config named.
# Without this the check above would pass on a container with no network at all.
check "a container can reach an allowed host through the proxy" bash -c '
    out=$(timeout 60 docker run --rm alpine:latest \
        wget -q -O- -T 20 http://example.com 2>&1 || true)
    echo "$out" | head -2 | sed "s/^/  /"
    echo "$out" | grep -qi "example domain" || { echo "an allowed host was not reachable"; exit 1; }'

# The rules behind all of it. DOCKER-USER is the one chain dockerd promises not to rewrite, and our
# own chain hangs off it so that flushing ours can never take dockerd's with it.
check "the forward chain is attached and ends in a deny" bash -c '
    iptables -S DOCKER-USER | sed "s/^/  /"
    iptables -S DEVCONTAINER_EGRESS_FWD | sed "s/^/  /"
    iptables -C DOCKER-USER -j DEVCONTAINER_EGRESS_FWD \
        || { echo "the forward chain is not attached"; exit 1; }
    wan=$(ip -4 route show default | sed -n "s/.* dev \([^ ]*\).*/\1/p")
    iptables -S DEVCONTAINER_EGRESS_FWD | tail -1 | grep -q -- "-o $wan -j REJECT" \
        || { echo "the chain does not end in a deny out $wan"; exit 1; }'

# Same policy as the OUTPUT chain, and for the same reason: a --dport 53 with no destination is not
# name resolution, it is a tunnel to any nameserver the other end controls.
check "port 53 is pinned on the forward path too" bash -c '
    dns=$(iptables -S DEVCONTAINER_EGRESS_FWD | grep -- "--dport 53" || true)
    echo "$dns" | sed "s/^/  /"
    [ -n "$dns" ] || { echo "containers have no DNS at all"; exit 1; }
    open=$(echo "$dns" | grep -cv -- " -d " || true)
    [ "$open" = 0 ] || { echo "$open accepts on 53 with no destination"; exit 1; }'

# Listening on the container address is what lets an inner container reach the proxy, and it is also
# what would offer the proxy to every peer on the network this container arrived on. The INPUT rule
# is the difference between those two.
check "the proxy port is closed on the way in from outside" bash -c '
    wan=$(ip -4 route show default | sed -n "s/.* dev \([^ ]*\).*/\1/p")
    iptables -C INPUT -i "$wan" -p tcp --dport 3128 -j DROP \
        || { echo "the proxy port is open to peers on $wan"; exit 1; }
    echo "  dropped on $wan"'

check "egress-status reports the inner daemon" bash -c '
    egress-status | tee /dev/stderr | grep -q "^  docker" \
        || { echo "status says nothing about docker"; exit 1; }'

reportResults
