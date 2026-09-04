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
    out=$(timeout 180 docker pull alpine:latest 2>&1) || {
        echo "$out" | tail -3 | sed "s/^/  /"
        echo "  container env HTTP_PROXY: $(tr "\0" "\n" < /proc/1/environ |
            sed -n "s/^HTTP_PROXY=//p" | head -1)"
        echo "  cache_peer line: $(grep "^cache_peer " \
            /etc/devcontainer/egress-filter/squid.conf | head -1)"
        tail -5 /var/log/devcontainer/egress-filter-proxy.log 2>/dev/null | sed "s/^/  /"
        echo "the pull failed"; exit 1; }
    echo "  alpine:latest pulled"'

# The client half, copied by `docker run` into every container it starts. 127.0.0.1 would be the
# inner container's own loopback, so this has to name an address of the container we are in.
#
# Reachability is asserted and not assumed, because that is the half that broke. A container running
# a daemon of its own lets that daemon pick a bridge range, and from in there this container's eth0
# subnet looks free. Once it is claimed, our eth0 address routes to that container's own bridge and
# nowhere -- the proxy is named correctly and answers nothing.
check "containers are told an address they can reach" bash -c '
    url=$(sed -n "s/.*\"httpProxy\": \"\([^\"]*\)\".*/\1/p" ~/.docker/config.json | head -1)
    echo "  config.json: ${url:-none}"
    [ -n "$url" ] || { echo "no proxy in config.json"; exit 1; }
    hostport=${url#*://}; host=${hostport%%:*}; port=${hostport##*:}
    ip -4 -o addr show scope global | awk "{ print \$4 }" | cut -d/ -f1 | grep -qx "$host" \
        || { echo "$host is not an address of this container"; exit 1; }
    timeout 60 docker run --rm alpine:latest nc -z -w5 "$host" "$port" \
        || { echo "a container cannot reach $hostport"; exit 1; }
    echo "  $hostport answers from inside a container"'

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
#
# Two choices here are deliberate, and both come from the same place: this suite runs inside a dev
# container that may itself be filtered, so the request crosses two allowlists.
#
# The host is a debian mirror rather than something only this scenario allows. A host on the inner
# list alone comes back "403 Forbidden" from the *outer* proxy, which reads exactly like the filter
# working when it is the test that is wrong. This one is on both, which is why the scenario carries
# the debian preset.
#
# The URL is plain http and not https, and that is about busybox. Alpine's wget cannot do TLS
# through a proxy, so for an https URL it sends `GET https://host/...` instead of a CONNECT. A proxy
# answers that on its own, but a parent proxy does not have to fetch an absolute https URL and
# refuses it. Measured: plain http and a real CONNECT both cross the chain and return 200, and that
# shape alone returns 403. Any ordinary client is fine -- see the note in the README.
check "a container can reach an allowed host through the proxy" bash -c '
    out=$(timeout 60 docker run --rm alpine:latest \
        wget -q -O- -T 20 http://deb.debian.org/debian/ 2>&1 || true)
    echo "  ${out:-<nothing>}" | head -2
    echo "$out" | grep -qi "403 " && { echo "the proxy filtered an allowed host"; exit 1; }
    echo "$out" | grep -qi "dists\|pool" || { echo "no page came back"; exit 1; }
    echo "  the mirror answered, so the request reached it"'

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

# A dev container inside a dev container. The proxy this container runs is itself a container of the
# outer daemon, so the outer DOCKER-USER chain rejects it exactly like any other -- it has no route
# out of its own. Chaining to the outer proxy gives it one.
#
# Written to hold in both places this suite runs. On a plain CI runner there is no outer proxy, no
# HTTP_PROXY reaches PID 1, and the correct answer is no cache_peer line at all.
check "the proxy chains to an outer proxy when the container was given one" bash -c '
    want=$(tr "\0" "\n" < /proc/1/environ | sed -n "s/^HTTP_PROXY=//p" | head -1)
    have=$(sed -n "s/^cache_peer \\([^ ]*\\) parent \\([0-9]*\\) .*/\\1:\\2/p" /etc/devcontainer/egress-filter/squid.conf | head -1)
    echo "  container env: ${want:-none}"
    echo "  upstream line: ${have:-none}"
    if [ -z "$want" ]; then
        [ -z "$have" ] || { echo "an upstream appeared with nothing to read it from"; exit 1; }
        echo "  no outer proxy, and no cache_peer line"
        exit 0
    fi
    exp=${want#*://}; exp=${exp%%/*}
    [ "$have" = "$exp" ] || { echo "expected $exp"; exit 1; }
    egress-status | grep -q "^  upstream" || { echo "status does not report it"; exit 1; }
    echo "  chained to $exp"'

# The rest of this file is about the ordering this feature does not control.
#
# dockerd reads daemon.json once, at start. Entrypoints run in install order, so a config that lists
# docker-in-docker before egress-filter starts dockerd before egress.sh writes anything, and the
# daemon runs unproxied for the life of the container. install.sh writes the file at build time to
# stop that happening at all; these checks cover the recovery when it happens anyway.
#
# The broken state is reproduced rather than waited for: an empty daemon.json, a restart, and the
# proxy variables cleared so dockerd cannot pick one up from the environment instead.
break_the_daemon() {
    echo "{}" > /etc/docker/daemon.json
    pkill -x dockerd 2>/dev/null; pkill -x containerd 2>/dev/null
    for _ in $(seq 1 30); do pgrep -x dockerd >/dev/null 2>&1 || break; sleep 1; done
    env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
        /usr/local/share/docker-init.sh
    for _ in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 1; done
    [ -z "$(docker info --format '{{.HTTPProxy}}' 2>/dev/null)" ]
}
export -f break_the_daemon

check "a daemon that started before its config is restarted and re-reads it" bash -c '
    break_the_daemon || { echo "could not reproduce an unproxied daemon"; exit 1; }
    echo "  before: proxy=$(docker info --format "{{.HTTPProxy}}" 2>/dev/null | sed "s/^$/unset/")"
    out=$(/usr/local/share/devcontainer/egress-filter/egress.sh up 2>&1)
    echo "$out" | grep -i "docker\|dockerd" | sed "s/^/  /"
    live=$(docker info --format "{{.HTTPProxy}}" 2>/dev/null)
    echo "  after: proxy=${live:-unset}"
    [ "$live" = "http://127.0.0.1:3128" ] || { echo "the daemon was not repaired"; exit 1; }
    echo "$out" | grep -q "restarted, proxied via" || { echo "the repair went unreported"; exit 1; }'

# A restart takes every running container with it, so the repair only runs when there is nothing to
# lose. This is the guard, and it is the half that must never regress: a feature that kills a
# person's containers to fix its own config is a worse bargain than a warning.
check "a daemon with containers running is reported and left alone" bash -c '
    break_the_daemon || { echo "could not reproduce an unproxied daemon"; exit 1; }
    cid=$(docker run -d --rm alpine:latest sleep 300)
    out=$(/usr/local/share/devcontainer/egress-filter/egress.sh up 2>&1)
    echo "$out" | grep -i "left alone\|Restarting it" | sed "s/^/  /"
    running=$(docker inspect -f "{{.State.Running}}" "$cid" 2>/dev/null)
    docker rm -f "$cid" >/dev/null 2>&1
    [ "$running" = true ] || { echo "the running container was killed"; exit 1; }
    echo "$out" | grep -q "left alone" || { echo "the guard did not warn"; exit 1; }
    echo "$out" | grep -q "Restarting it" && { echo "it restarted anyway"; exit 1; }
    echo "  the container survived and the warning names the daemon"'

# The line that sent a person to read the allowlist when the daemon was the problem. daemon.json is
# correct at this point and the daemon is not using it, which is exactly the pair that used to
# report success.
check "egress-status names the daemon when the daemon is the problem" bash -c '
    grep -q 127.0.0.1:3128 /etc/docker/daemon.json || { echo "daemon.json was not repaired"; exit 1; }
    out=$(egress-status)
    echo "$out" | sed "s/^/  /"
    echo "$out" | grep -q "daemon proxy is" || { echo "status did not name the daemon"; exit 1; }
    echo "$out" | grep -q "pkill dockerd" || { echo "status did not say how to fix it"; exit 1; }'

check "the daemon is proxied again once nothing is running" bash -c '
    /usr/local/share/devcontainer/egress-filter/egress.sh up >/dev/null 2>&1
    live=$(docker info --format "{{.HTTPProxy}}" 2>/dev/null)
    echo "  proxy=${live:-unset}"
    [ "$live" = "http://127.0.0.1:3128" ] || { echo "the daemon is still unproxied"; exit 1; }
    egress-status | grep -q "daemon proxy is" && { echo "status still reports a mismatch"; exit 1; }
    echo "  status is quiet about the daemon again"'

reportResults
