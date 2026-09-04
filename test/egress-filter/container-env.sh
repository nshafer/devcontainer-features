#!/usr/bin/env bash
# The one gap /etc/environment and /etc/profile.d cannot close.
#
# PAM reads the first and a login shell reads the second, so a terminal has HTTP_PROXY and a plain
# `docker exec sh -c ...` has nothing. What a bare exec inherits is what docker stored when the
# container was created, and only the project's devcontainer.json can put anything there -- see
# "Processes started by docker exec" in the README. This scenario is that config, and the checks
# below are what it buys.
#
# The negative case is in test.sh, which declares no containerEnv and has to report NOT SET.
#
# Nothing here reaches a real host. This container is a container of an inner daemon, so its own
# egress depends on an upstream chain, and the block under test is exactly what takes that chain
# away -- see the last check. So the two reachability checks below use plain HTTP to a host on no
# list, where the 403 comes from the proxy itself and no upstream is needed. A 403 proves what these
# checks are about: the request reached the proxy, which means the environment reached the client.
set -e
source dev-container-features-test-lib

check "the container environment carries the proxy" bash -c '
    tr "\0" "\n" < /proc/1/environ | grep -q "^HTTP_PROXY=http://127.0.0.1:3128"'

# `env -i` is the closest a test inside the container can get to an exec from outside: it drops
# everything the login shell added and keeps only what PID 1 carries.
check "a process with no shell profile still reaches the proxy" bash -c '
    mapfile -t p < <(tr "\0" "\n" < /proc/1/environ | grep -iE "^(http|https|no)_proxy=")
    [ "${#p[@]}" -gt 0 ] || { echo "PID 1 carries no proxy variables"; exit 1; }
    code=$(env -i PATH=/usr/bin:/bin "${p[@]}" \
        timeout 15 curl -s -o /dev/null -w "%{http_code}" http://gitlab.com || echo 000)
    echo "gitlab.com -> $code"
    [ "$code" = 403 ]'

# The same process without the block. 000 and not 403: the firewall rejects a client that goes
# straight out, so this is the state every `docker exec` was in before the block existed.
check "the same process without the environment has no route at all" bash -c '
    if env -i PATH=/usr/bin:/bin timeout 15 curl -s -o /dev/null http://gitlab.com; then
        echo "gitlab.com answered with no proxy in the environment -- there is a way out"; exit 1
    fi
    echo "gitlab.com is unreachable without the proxy, as it must be"'

check "status says a plain docker exec inherits it, and prints no warning" bash -c '
    out=$(egress-status | tee /dev/stderr)
    echo "$out" | grep -qE "container env +set" || { echo "status does not see the block"; exit 1; }
    echo "$out" | grep -q "add containerEnv" && { echo "it warns about a block that is there"; exit 1; }
    echo "  no warning, because there is nothing to add"'

# Root reads PID 1 directly. The remote user cannot, so `up` records the answer on line 6 and
# status reads it from there.
# The CLI appends the container environment to /etc/environment after the entrypoint has run. When
# that block already says what this feature would say, writing a second copy explains nothing to
# whoever reads the file next, so the feature writes none. The two are identical because NO_PROXY
# carries no subnet: the proxy forwards to the local subnets by address instead.
check "there is one definition of the proxy in /etc/environment, not two" bash -c '
    grep -n "PROXY" /etc/environment | sed "s/^/  /"
    n=$(grep -c "^HTTP_PROXY=" /etc/environment)
    [ "$n" = 1 ] || { echo "$n copies of HTTP_PROXY"; exit 1; }
    ! grep -q "^# devcontainer-egress-filter$" /etc/environment ||
        { echo "the feature wrote a block the container environment already carries"; exit 1; }'

check "the state file records it for an unprivileged reader" bash -c '
    line=$(sed -n 6p /run/devcontainer/egress-filter.state)
    echo "state line 6: $line"
    [ "$line" = "http://127.0.0.1:3128" ]'

# upstreamProxy defaults to auto, which reads HTTP_PROXY from PID 1 -- now our own address. A proxy
# whose upstream is itself answers nothing and says nothing about why, so `auto` finds nothing to
# chain to and says so by writing no cache_peer line. That is also the cost of the block: a dev
# container inside a dev container has to name its upstreamProxy, because this is the variable the
# outer address would have arrived in.
check "the proxy does not chain to itself" bash -c '
    ! grep -q "^cache_peer" /etc/devcontainer/egress-filter/squid.conf'

reportResults
