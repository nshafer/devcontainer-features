#!/usr/bin/env bash
# The same containerEnv block, and a NO_PROXY that does not repeat the noProxy option.
#
# The block is a fixed string in a config file. Subnets are not in it, because the proxy forwards to
# the local subnets by address, so the block is the same on every machine. Names are the one thing
# it has to carry: a client that reads the block sends `http://db:8080` to the proxy, which has no
# address pattern for a name and denies it. This scenario names db and redis in the option and not
# in the block.
#
# Two things have to happen. status has to say so in one line, and /etc/environment has to end up
# with the complete list, because the CLI appends the container environment to that
# file after this feature's entrypoint has run.
set -e
source dev-container-features-test-lib

check "the block does not repeat the noProxy names" bash -c '
    np=$(tr "\0" "\n" < /proc/1/environ | sed -n "s/^NO_PROXY=//p" | head -1)
    echo "  block says: $np"
    case ",$np," in *,db,*|*,redis,*) echo "the block carries the names after all"; exit 1 ;; esac'

check "status names what the block misses, in one line" bash -c '
    out=$(egress-status | tee /dev/stderr)
    echo "$out" | grep -qE "container env +set, but NO_PROXY misses: db redis \(see README\)" ||
        { echo "status does not name db and redis"; exit 1; }
    echo "$out" | grep -q "^!!!" && { echo "a warning block, which was retired"; exit 1; }
    echo "  one line, and it names db and redis"'

# pam_env takes the last assignment in the file. The CLI appends the container environment after the
# entrypoint has run, so the watcher is what puts the complete list back at the end.
check "the last NO_PROXY in /etc/environment is the complete one" bash -c '
    for _ in $(seq 1 15); do
        v=$(sed -n "s/^NO_PROXY=//p" /etc/environment | tail -1 | tr -d "\"")
        [ "$v" = "localhost,127.0.0.1,::1,db,redis" ] && break
        sleep 1
    done
    echo "  effective NO_PROXY: $v"
    [ "$v" = "localhost,127.0.0.1,::1,db,redis" ] ||
        { grep -n PROXY /etc/environment; echo "the incomplete value still wins"; exit 1; }'

reportResults
