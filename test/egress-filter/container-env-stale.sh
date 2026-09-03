#!/usr/bin/env bash
# The same containerEnv block, and a NO_PROXY that has fallen behind.
#
# The block is a fixed string in a config file. It cannot read the routing table, so the subnets in
# it are the ones somebody copied on the day they wrote it. This scenario names none of them, while
# localNetworks is auto and the firewall opens whatever docker attached. A process that reads the
# block then sends a request for a peer on one of those subnets to the proxy, which denies it.
#
# Two things have to happen. status has to say so and print the block to paste, and /etc/environment
# has to end up with the complete list, because the CLI appends the container environment to that
# file after this feature's entrypoint has run.
set -e
source dev-container-features-test-lib

check "the firewall opened a subnet the block does not name" bash -c '
    nets=$(ip -4 route show scope link | awk "\$1 ~ /\\// { print \$1 }")
    [ -n "$nets" ] || { echo "no on-link subnets, so there is nothing to fall behind"; exit 1; }
    echo "  open: $nets"
    np=$(tr "\0" "\n" < /proc/1/environ | sed -n "s/^NO_PROXY=//p" | head -1)
    echo "  block says: $np"
    for net in $nets; do
        case ",$np," in *",$net,"*) echo "$net is in the block after all"; exit 1 ;; esac
    done'

check "status reports the block as out of date" bash -c '
    out=$(egress-status | tee /dev/stderr)
    echo "$out" | grep -qE "container env +set, but NO_PROXY is out of date" ||
        { echo "status calls it fine"; exit 1; }
    echo "$out" | grep -q "update containerEnv in .devcontainer/devcontainer.json" ||
        { echo "no warning"; exit 1; }
    for net in $(ip -4 route show scope link | awk "\$1 ~ /\\// { print \$1 }"); do
        echo "$out" | grep -q "$net" || { echo "$net is not named in the warning"; exit 1; }
    done
    echo "  the warning names every open subnet"'

# pam_env takes the last assignment in the file. The CLI appends the container environment after the
# entrypoint has run, so the watcher is what puts the complete list back at the end.
check "the last NO_PROXY in /etc/environment is the complete one" bash -c '
    nets=$(ip -4 route show scope link | awk "\$1 ~ /\\// { print \$1 }")
    for _ in $(seq 1 15); do
        v=$(sed -n "s/^NO_PROXY=//p" /etc/environment | tail -1 | tr -d "\"")
        ok=yes
        for net in $nets; do
            case ",$v," in *",$net,"*) ;; *) ok=no ;; esac
        done
        [ "$ok" = yes ] && break
        sleep 1
    done
    echo "  effective NO_PROXY: $v"
    [ "$ok" = yes ] || { grep -n PROXY /etc/environment; echo "the stale value still wins"; exit 1; }'

reportResults
