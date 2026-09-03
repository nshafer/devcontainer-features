#!/usr/bin/env bash
# Default-deny egress, enforced by the firewall and decided by a proxy.
#
# The split matters. HTTP_PROXY is advisory -- an agent that ignores it is not filtered at all -- so
# the env var is a convenience and the firewall is the control:
#
#   OUTPUT: loopback, established, DNS *to the container's own resolvers*, and anything owned by
#           the proxy's uid.  Everything else REJECTed. The agent has no route off the machine
#           except through the proxy.
#
# The proxy then decides by hostname, taken from the CONNECT request, so lists are domains rather
# than addresses and there is no TLS interception and no CA to install. That last part is why this
# is a CONNECT proxy and not a MITM one: filtering by SNI/CONNECT host costs nothing, and reading
# the traffic would mean handing every TLS session to a certificate this feature generated.
#
# The two halves come apart cleanly, which is the nicest property here: changing the allowlist is a
# proxy reload (SIGHUP), never a firewall change. So lists can be edited live, by an unprivileged
# user, without anything being briefly open.
#
# An inner Docker daemon needs a second copy of both halves, for reasons the OUTPUT chain cannot
# reach. See the docker section below.
set -uo pipefail

CONFIG=/usr/local/share/devcontainer/egress-filter/config
SHARE_DIR=/usr/local/share/devcontainer/egress-filter
# Defaults so the script can be driven directly, which the tests do.
ALLOW=""
DENY=""
BASELINE=true
PROJECT_ALLOWLIST="/workspaces/*/.devcontainer/egress-allow.txt"
PRESETS=""
ALLOW_DNS=true
DNS_SERVERS=""
LOCAL_NETWORKS=auto
NO_PROXY_EXTRA=""
UPSTREAM_PROXY=auto
PROXY_PORT=3128
PROXY_USER=egressfilter
USERNAME=root
USER_HOME=/root
# shellcheck source=/dev/null
[ -r "$CONFIG" ] && . "$CONFIG"

GLOBAL_LIST="${EGRESS_GLOBAL_LIST:-/mnt/egress-filter/allowlist.txt}"  # a mount you declare yourself
# What to *print* for the global list. The container path is where it is mounted, which is no help
# to the person who has to edit it -- they can only reach it from the other side of the mount. The
# status output names the file they can actually open.
# The tilde is meant to stay literal: this is display text naming a path on the *host's* home
# directory, which this script never opens and could not expand correctly if it tried.
# shellcheck disable=SC2088
GLOBAL_LIST_HOST="~/.config/egress-filter/allowlist.txt"
# Overridable after the config is sourced, the same way GLOBAL_LIST is, so the preset
# merge can be exercised without rebuilding the image.
PRESETS="${EGRESS_PRESETS:-$PRESETS}"
DNS_SERVERS="${EGRESS_DNS_SERVERS:-$DNS_SERVERS}"
LOCAL_NETWORKS="${EGRESS_LOCAL_NETWORKS:-$LOCAL_NETWORKS}"
UPSTREAM_PROXY="${EGRESS_UPSTREAM_PROXY:-$UPSTREAM_PROXY}"
FILTER_FILE=/etc/devcontainer/egress-filter/allow.regex
PROXY_CONF=/etc/devcontainer/egress-filter/tinyproxy.conf
SOURCES_FILE=/etc/devcontainer/egress-filter/sources.txt
# Every source, concatenated in merge order with a header before each one. allow.regex is what the
# proxy reads and is unreadable at a glance -- anchored, escaped regex, sorted, with no indication
# of where any line came from. This is the same content before that transformation, which is what
# you want when the question is "why is this host allowed" or "did my edit actually land".
ALLOWLIST_FILE=/etc/devcontainer/egress-filter/allowlist.txt
# Readable by anyone, because the status command has to work for the remote user and
# querying iptables needs root -- see firewall_state().
STATE_FILE=/run/devcontainer/egress-filter.state
# The proxy's own log, separate from the feature's. It has to be a different file and it has to
# be pre-created: tinyproxy drops to $PROXY_USER before opening it, so a root-owned file is
# silently not written and every denial is lost -- which is exactly the record you need to build
# an allowlist from. World-readable on purpose, so the person building the list can read it
# without root.
PROXY_LOG=/var/log/devcontainer/egress-filter-proxy.log

# Both sit under a per-project directory rather than loose in /run and /var/log, so neither can
# collide with a distro package of the same name. Created here because any subcommand may be the
# first to write one; the failure is ignored because `status` deliberately runs unprivileged.
install -d "$(dirname "$STATE_FILE")" "$(dirname "$PROXY_LOG")" 2>/dev/null || true

log() { echo "==> egress-filter: $*"; }
warn() { echo "!!! egress-filter: $*" >&2; }

# One host per line in, one POSIX extended regex per line out.
#
# The input is meant to be written by a human in a hurry, so a bare name means that exact host and a
# leading dot means the domain and everything under it. Anything already looking like a regex is
# passed through untouched, which is the escape hatch for the cases those two forms do not cover.
to_regex() {
    local line
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(echo "$line" | tr -d '[:space:]')"
        [ -n "$line" ] || continue
        # Already a regex? Pass it through -- the escape hatch for anything the two forms below
        # cannot express.
        case "$line" in
            *[\\^\$\(\[]*)
                echo "$line"; continue ;;
        esac
        local escaped="${line#.}"
        escaped="${escaped//./\\.}"
        case "$line" in
            # .github.com -> github.com and any subdomain of it, and nothing else.
            .*) echo "(^|\\.)${escaped}\$" ;;
            *)  echo "^${escaped}\$" ;;
        esac
    done
}

available_presets() {
    find "$SHARE_DIR/presets" -maxdepth 1 -name '*.txt' -printf '%f\n' 2>/dev/null \
        | sed 's/\.txt$//' | sort | tr '\n' ' '
}

# Merged in a deliberate order: baseline, then global, then project, then the feature's own option.
# Later sources only ever add. The deny list is applied last and only ever removes, so a project can
# withdraw something the global list granted but cannot quietly re-grant what a deny took away.
build_list() {
    local tmp merged denied
    tmp="$(mktemp)"; merged="$(mktemp)"; denied="$(mktemp)"

    : > "$SOURCES_FILE"

    install -d "$(dirname "$ALLOWLIST_FILE")"
    {
        echo "# Every source that went into the allowlist, in the order they are merged."
        echo "#"
        echo "# Generated by the egress-filter feature and rewritten on every reload -- editing this"
        echo "# file does nothing. Edit the source it came from; each section says which that is."
        echo "# The compiled form the proxy actually reads is $FILTER_FILE."
        echo "# Generated $(date -Is)"
    } > "$ALLOWLIST_FILE"

    # Appends a source to both the merge input and the human-readable copy, so the two cannot drift.
    add_source() {
        local label="$1" file="$2"
        cat "$file" >> "$tmp"
        {
            echo ""
            echo "# ============================================================================"
            echo "# $label"
            echo "# ============================================================================"
            cat "$file"
        } >> "$ALLOWLIST_FILE"
    }

    if [ "$BASELINE" = true ] && [ -r "$SHARE_DIR/baseline-allow.txt" ]; then
        add_source "baseline: $SHARE_DIR/baseline-allow.txt" "$SHARE_DIR/baseline-allow.txt"
        echo "baseline: $SHARE_DIR/baseline-allow.txt" >> "$SOURCES_FILE"
    fi

    # Curated ecosystem blocks. Merged before the global list so a machine-wide entry can still
    # shadow nothing -- presets only ever add -- and an unknown name is called out rather than
    # silently doing nothing, which is the failure mode that wastes an afternoon.
    if [ -n "$PRESETS" ]; then
        local name file used=""
        for name in $(echo "$PRESETS" | tr ',' ' '); do
            file="$SHARE_DIR/presets/$name.txt"
            if [ -r "$file" ]; then
                add_source "preset '$name': $file" "$file"
                used="$used $name"
            else
                warn "no such preset: $name (have: $(available_presets))"
            fi
        done
        [ -n "$used" ] && echo "presets: $used" >> "$SOURCES_FILE"
    fi

    if [ -r "$GLOBAL_LIST" ]; then
        add_source "global: $GLOBAL_LIST_HOST (on your machine; mounted at $GLOBAL_LIST)" "$GLOBAL_LIST"
        echo "global:   $GLOBAL_LIST_HOST (on your machine)" >> "$SOURCES_FILE"
    elif [ -d "$(dirname "$GLOBAL_LIST")" ]; then
        echo "global:   $GLOBAL_LIST_HOST (on your machine -- no file there yet)" >> "$SOURCES_FILE"
    else
        # The mount itself is absent, which is a different problem from an empty list and has a
        # different fix. `egress-status` prints this line, so name the cause there too.
        echo "global:   NOT MOUNTED -- add the mount to your own config" >> "$SOURCES_FILE"
    fi

    # A glob, because a feature's entrypoint is never told the workspace folder -- it runs before
    # any of that is settled. Unquoted on purpose so the pattern expands.
    local found=no p
    # shellcheck disable=SC2086
    for p in $PROJECT_ALLOWLIST; do
        if [ -r "$p" ]; then
            add_source "project: $p" "$p"
            echo "project:  $p" >> "$SOURCES_FILE"
            found=yes
        fi
    done
    [ "$found" = yes ] \
        || echo "project:  .devcontainer/egress-allow.txt (in this repo -- none yet)" >> "$SOURCES_FILE"

    if [ -n "$ALLOW" ]; then
        echo "$ALLOW" | tr ',' '\n' >> "$tmp"
        {
            echo ""
            echo "# ============================================================================"
            echo "# option: allow, from devcontainer.json"
            echo "# ============================================================================"
            echo "$ALLOW" | tr ',' '\n'
        } >> "$ALLOWLIST_FILE"
        echo "option:   allow=$ALLOW" >> "$SOURCES_FILE"
    fi

    to_regex < "$tmp" | sort -u > "$merged"

    if [ -n "$DENY" ]; then
        echo "$DENY" | tr ',' '\n' | to_regex | sort -u > "$denied"
        # Removes the exact patterns the deny list generates, so denying a host you also allowed
        # takes it out, and denying something never allowed is a no-op rather than an error.
        comm -23 "$merged" "$denied" > "$tmp" && mv "$tmp" "$merged"
        {
            echo ""
            echo "# ============================================================================"
            echo "# option: deny, from devcontainer.json -- REMOVED from everything above"
            echo "# ============================================================================"
            echo "$DENY" | tr ',' '\n' | sed 's/^/# removed: /'
        } >> "$ALLOWLIST_FILE"
        echo "option:   deny=$DENY" >> "$SOURCES_FILE"
    fi

    install -d "$(dirname "$FILTER_FILE")"
    mv "$merged" "$FILTER_FILE"
    chmod 0644 "$FILTER_FILE"
    chmod 0644 "$ALLOWLIST_FILE" 2>/dev/null
    rm -f "$tmp" "$denied" 2>/dev/null

    log "allowlist rebuilt: $(wc -l < "$FILTER_FILE") patterns"
}

# Where this proxy sends what it cannot reach itself, as a bare host:port. Empty means "reach it
# yourself", which is the answer everywhere except one arrangement.
#
# That arrangement is a dev container inside a dev container. The inner egress-filter starts its own
# proxy, and that proxy has no route out at all: it is a container of the *outer* daemon, so the
# outer DOCKER-USER chain rejects it exactly like any other. Chaining to the outer proxy gives it
# one, and both allowlists then apply -- the inner one refuses first, the outer one refuses after.
# Nothing is widened by this: a host has to be on both lists to be reached.
#
# 'auto' reads HTTP_PROXY from the container's own PID 1, which is the environment the runtime
# handed this container and nothing inside it can rewrite. Deliberately not this script's own
# environment: /etc/environment names *this* proxy, so a second `up` run from a shell would read our
# own address back and chain us to ourselves.
upstream_proxy() {
    local raw host_port
    case "$UPSTREAM_PROXY" in
        off | none | false) return 0 ;;
        auto | '')
            # Readability tested first: the shell reports a refused redirection itself, and
            # 2>/dev/null on the pipeline does not cover that. `status` runs unprivileged and would
            # otherwise print a permission error every time.
            [ -r /proc/1/environ ] || return 0
            raw="$(tr '\0' '\n' < /proc/1/environ 2>/dev/null |
                   sed -n 's/^\(HTTP_PROXY\|http_proxy\)=//p' | head -1)"
            ;;
        *) raw="$UPSTREAM_PROXY" ;;
    esac
    [ -n "$raw" ] || return 0
    # http://host:port/ -> host:port. tinyproxy takes a bare address, and a scheme or a trailing
    # slash on the Upstream line stops it starting at all.
    host_port="${raw#*://}"
    host_port="${host_port%%/*}"
    [ -n "$host_port" ] || return 0
    case "$host_port" in *:*) ;; *) host_port="$host_port:80" ;; esac
    # Never ourselves. A proxy whose upstream is itself answers nothing and says nothing about why.
    case "$host_port" in
        127.0.0.1:"$PROXY_PORT" | localhost:"$PROXY_PORT" | "[::1]:$PROXY_PORT") return 0 ;;
    esac
    echo "$host_port"
}

write_proxy_conf() {
    install -d "$(dirname "$PROXY_CONF")"
    # Created before tinyproxy starts, owned by the user it drops to, readable by everyone.
    touch "$PROXY_LOG" 2>/dev/null
    chown "$PROXY_USER:" "$PROXY_LOG" 2>/dev/null
    chmod 0644 "$PROXY_LOG" 2>/dev/null
    # Every address, and only when there is an inner daemon to need it.
    #
    # tinyproxy binds at start, and the bridges dockerd makes do not exist yet -- dockerd starts
    # after this. Naming addresses here would mean a proxy restart every time a `docker network
    # create` added one, so it binds all of them instead and the reachable set is decided elsewhere:
    # the private ranges below, and an INPUT rule that drops this port on the way in from the outer
    # network. See apply_input_guard. Loopback stays the only listener without an inner daemon.
    local listen="Listen 127.0.0.1" extra_allow="" upstream="" up
    if docker_present; then
        listen="Listen 0.0.0.0"
        extra_allow="Allow 10.0.0.0/8
Allow 172.16.0.0/12
Allow 192.168.0.0/16"
    fi
    up="$(upstream_proxy)"
    [ -n "$up" ] && upstream="Upstream http $up"
    cat > "$PROXY_CONF" <<EOF
# Generated by the egress-filter feature. Edits are overwritten.
User $PROXY_USER
Group $PROXY_USER
Port $PROXY_PORT
${listen}
Timeout 600
MaxClients 512
Allow 127.0.0.1
${extra_allow}
${upstream}
ConnectPort 443
ConnectPort 80
ErrorFile 403 "$SHARE_DIR/403.html"
Filter "$FILTER_FILE"
FilterDefaultDeny Yes
FilterType ere
FilterCaseSensitive No
LogFile "$PROXY_LOG"
LogLevel Connect
EOF
    chmod 0644 "$PROXY_CONF"
}

proxy_pid() { pgrep -x tinyproxy 2>/dev/null | head -1; }

start_proxy() {
    if [ -n "$(proxy_pid)" ]; then
        reload_proxy
        return 0
    fi
    tinyproxy -c "$PROXY_CONF" 2>/dev/null
    local i=0
    while [ "$i" -lt 25 ]; do
        [ -n "$(proxy_pid)" ] && { log "proxy listening on 127.0.0.1:$PROXY_PORT as $PROXY_USER"; return 0; }
        i=$((i + 1)); sleep 0.2
    done
    warn "the proxy did not start, so egress is UNFILTERED. Config error, most likely:"
    tail -5 "$PROXY_LOG" 2>/dev/null | sed 's/^/!!!   /' >&2
    tinyproxy -c "$PROXY_CONF" -d 2>&1 | head -3 | sed 's/^/!!!   /' >&2 &
    sleep 0.5; pkill -f "tinyproxy -c $PROXY_CONF -d" 2>/dev/null
    return 1
}

# The whole point of splitting policy from enforcement: a list change is this, and nothing else.
reload_proxy() {
    local pid; pid="$(proxy_pid)"
    [ -n "$pid" ] || return 1
    kill -HUP "$pid" 2>/dev/null && log "proxy reloaded its allowlist"
}

# Which addresses port 53 may be opened to. One per line, IPv4 only.
#
# Allowing port 53 and leaving the destination open is not "the container can resolve names", it is
# "the container can speak to any nameserver on the internet". That is a general-purpose tunnel:
# iodine, dnscat, and plain TXT-record smuggling all need nothing more than a route to a resolver
# the other end controls, and they get one for free from a blanket --dport 53 ACCEPT. Pinning the
# destination leaves recursion through the *configured* resolvers -- slower, and visible in the
# resolver's own logs -- and takes the direct channel away.
#
# The list is the dnsServers option if it was set, and otherwise whatever the container runtime put
# in /etc/resolv.conf, which is the set that was already going to be used. Snapshotted when the
# rules are applied rather than looked up per packet: resolv.conf is written before the entrypoint
# runs and does not change under a running container, and anyone who could rewrite it later is root
# and could have flushed the chain instead.
#
# A resolver on loopback -- Docker's embedded 127.0.0.11, systemd-resolved's 127.0.0.53 -- is
# already covered by the -o lo rule and is reachable whether or not it appears here. That is not a
# gap: loopback goes nowhere, and the forwarder behind it decides its own upstreams.
dns_resolvers() {
    local raw ns
    if [ -n "$DNS_SERVERS" ]; then
        raw="$(echo "$DNS_SERVERS" | tr ',' '\n')"
    else
        raw="$(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf 2>/dev/null)"
    fi
    while IFS= read -r ns; do
        ns="$(echo "$ns" | tr -d '[:space:]')"
        [ -n "$ns" ] || continue
        case "$ns" in
            # The chain is iptables, so a v6 resolver cannot be expressed in it. Named rather than
            # dropped silently, because the symptom -- resolution simply not working -- gives no
            # hint that a line in resolv.conf was skipped.
            *:*) warn "ignoring IPv6 resolver $ns: this firewall is IPv4 only" ; continue ;;
        esac
        if echo "$ns" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'; then
            echo "$ns"
        else
            warn "ignoring resolver '$ns': not an IPv4 address or CIDR"
        fi
    done <<< "$raw"
}

# Which subnets count as local, and may be reached directly without the proxy.
#
# A dev container is often one service of a docker-compose project, and the others -- Postgres on
# 5432, Redis on 6379 -- are peers on the same docker network. Those connections never touch the
# proxy and never leave the machine, but a default-deny OUTPUT chain rejects them exactly like a
# connection to the internet, and the failure looks like the database is down.
#
# "auto" means the subnets this container is directly attached to, which is the compose network and
# nothing else. It is read from the container's own routing table, so it needs no configuration and
# stays correct when docker renumbers the network on the next `up`.
#
# The relaxation is real and worth naming: the subnet contains the docker gateway, which is the
# host, and every other container on that network. Those peers usually have unfiltered internet
# access, so an agent that can reach one and make it relay is out. This is a trade of local
# reachability against that, taken because a filter that breaks the project's own database is a
# filter people turn off. Narrow it with explicit CIDRs -- localNetworks="172.18.0.5/32" is one peer
# -- or close it with localNetworks="off".
PRIVATE_RANGES="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10"

# Base 10 is forced on every octet: 010 is ten in an address and eight in bash arithmetic.
ip_to_int() {
    local o1 o2 o3 o4
    read -r o1 o2 o3 o4 <<< "$(echo "$1" | tr '.' ' ')"
    echo $(( (10#$o1 * 16777216) + (10#$o2 * 65536) + (10#$o3 * 256) + 10#$o4 ))
}

# True when the CIDR sits wholly inside one of the private ranges. A prefix shorter than the
# range's own cannot, which is why the length is compared before the address.
cidr_is_private() {
    local cidr="$1" addr bits a r rnet rbits mask
    addr="${cidr%%/*}"; bits="${cidr#*/}"
    [ "$bits" = "$cidr" ] && bits=32
    a="$(ip_to_int "$addr")"
    for r in $PRIVATE_RANGES; do
        rnet="$(ip_to_int "${r%%/*}")"; rbits="${r#*/}"
        [ "$bits" -ge "$rbits" ] || continue
        mask=$(( 0xFFFFFFFF - (2 ** (32 - rbits) - 1) ))
        [ $(( a & mask )) -eq "$rnet" ] && return 0
    done
    return 1
}

# The subnets on the container's own interfaces. iproute2 when it is there, and /proc/net/route
# when it is not -- the file is always present, and a minimal image without `ip` is common enough
# that falling back beats reporting no local networks at all.
on_link_subnets() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 route show scope link 2>/dev/null | awk '$1 ~ /\// { print $1 }'
        return 0
    fi
    # Columns: Iface Destination Gateway Flags RefCnt Use Metric Mask MTU Window IRTT.
    # Addresses are hex, little-endian, so the low byte is the first octet. An on-link route is one
    # with no gateway and a real mask, which excludes the default route.
    local iface dest gw rest mask d m bits
    # shellcheck disable=SC2034  # iface is read to consume the column, not to be used.
    while read -r iface dest gw rest; do
        [ "$dest" = Destination ] && continue
        [ "$gw" = 00000000 ] || continue
        mask="$(echo "$rest" | awk '{ print $5 }')"
        case "$mask" in '' | 00000000) continue ;; esac
        d=$((16#$dest)); m=$((16#$mask))
        bits=0
        while [ "$m" -ne 0 ]; do bits=$(( bits + (m & 1) )); m=$(( m >> 1 )); done
        echo "$((d & 255)).$(( (d >> 8) & 255 )).$(( (d >> 16) & 255 )).$(( (d >> 24) & 255 ))/$bits"
    done < /proc/net/route 2>/dev/null
}

local_networks() {
    local n
    case "$LOCAL_NETWORKS" in
        off | false | none | "")
            return 0 ;;
        auto)
            for n in $(on_link_subnets); do
                if cidr_is_private "$n"; then
                    echo "$n"
                else
                    # A public subnet on an interface means host networking or a macvlan, where
                    # "the local network" is the internet. Opening it would undo the filter.
                    warn "not treating $n as local: it is outside the private ranges."
                    warn "  Name it in localNetworks if you meant it."
                fi
            done ;;
        *)
            for n in $(echo "$LOCAL_NETWORKS" | tr ',' ' '); do
                if echo "$n" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'; then
                    echo "$n"
                else
                    warn "ignoring localNetworks entry '$n': not an IPv4 address or CIDR"
                fi
            done ;;
    esac
}

# ---------------------------------------------------------------------------
# The inner Docker daemon.
#
# docker-in-docker puts a second dockerd inside this container, and it walks around the OUTPUT chain
# twice over:
#
#   1. dockerd runs as root, so its own image pulls land on the REJECT. The failure reads as a
#      registry timeout, which sends people to the registry rather than to the filter.
#   2. A container that dockerd starts has its own network namespace. Its packets are FORWARDed and
#      never OUTPUT, so `-m owner` never sees them and nothing filters them at all.
#      `docker run alpine wget https://anywhere` is a complete bypass of this feature.
#
# So the daemon is told about the proxy by configuration, and the FORWARD path gets the same default
# deny the OUTPUT path has. Inner containers reach the proxy at this container's own address --
# their loopback is their own, not ours -- which is why the proxy listens there too.
#
# All of it is conditional on dockerd being installed. A container without one sees no change.
docker_present() { command -v dockerd >/dev/null 2>&1; }

# The interface an inner container's packet leaves by when it is bound for the internet. That is
# exactly what a default route is, so it is read from there rather than guessed from a name --
# "docker0" is the inner bridge here, and the outer interface is not always eth0.
wan_iface() {
    command -v ip >/dev/null 2>&1 || return 0
    ip -4 route show default 2>/dev/null |
        awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

# This container's own address on that interface. An inner container can reach it: the address is
# local to us, so the packet arrives on INPUT and is never forwarded, which is what keeps the proxy
# reachable from inside a container while everything else out of one is denied.
primary_ip() {
    local dev
    dev="$(wan_iface)"
    [ -n "$dev" ] || return 0
    ip -4 -o addr show dev "$dev" scope global 2>/dev/null |
        awk '{ print $4 }' | cut -d/ -f1 | head -1
}

# This container's own addresses on the bridges the inner daemon made. docker0 first, because that
# is the network `docker run` attaches a container to without being told otherwise.
docker_bridge_ips() {
    local dev
    command -v ip >/dev/null 2>&1 || return 0
    for dev in docker0 $(ip -4 -o link show 2>/dev/null |
                         awk -F': ' '{ print $2 }' | cut -d@ -f1 | grep '^br-'); do
        ip -4 -o addr show dev "$dev" scope global 2>/dev/null |
            awk '{ print $4 }' | cut -d/ -f1
    done
}

# The address inner containers are told to send their traffic to. Empty when there is no inner
# daemon or no usable address, and every caller reads that as "leave Docker alone".
#
# The bridge address, not this container's own eth0, and the difference is not cosmetic. A container
# that runs a daemon of its own -- a dev container inside a dev container -- lets that daemon pick a
# bridge range, and the picker takes the first free one it sees. From in there our eth0 subnet looks
# free, so it gets claimed, and our eth0 address then routes to that container's own bridge and
# nowhere. The bridge address cannot be taken that way: it sits on the subnet the container's own
# eth0 is on, so the picker skips it.
#
# docker0 does not exist when `up` first runs -- dockerd creates it later -- so this falls back to
# eth0, and the watcher rewrites the client config once the bridge appears.
docker_proxy_url() {
    local ip
    docker_present || return 0
    ip="$(docker_bridge_ips | head -1)"
    [ -n "$ip" ] || ip="$(primary_ip)"
    [ -n "$ip" ] || return 0
    echo "http://$ip:$PROXY_PORT"
}

# Every module this chain needs, in the order the rules below use them. Named so the failure can
# say which one, because the kernel's own message for a missing match -- "No chain/target/match by
# that name" -- names nothing and sends people to look for a typo.
REQUIRED_MODULES="ip_tables iptable_filter xt_conntrack xt_owner ipt_REJECT"

# Printed once, the first time a rule is refused.
#
# A container cannot load a kernel module. With a rootful dockerd that never shows, because the
# daemon writes its own iptables rules on the host and the modules are loaded before any container
# starts. Under a rootless runtime -- rootless Docker, or Podman -- nothing on the host has
# necessarily used netfilter at all, the container's tables live in a user namespace, and a user
# namespace may not autoload. So the modules have to be on the host already, and loading them is
# the host's job, not this container's.
MODULE_HINT_SHOWN=no
module_hint() {
    [ "$MODULE_HINT_SHOWN" = yes ] && return 0
    MODULE_HINT_SHOWN=yes
    warn "The kernel refused a match this firewall needs."
    warn "  A container cannot load a kernel module, and under a rootless runtime -- rootless"
    warn "  Docker, or Podman -- nothing else has necessarily loaded these. Load them on the host:"
    warn "    printf '%s\\n' $REQUIRED_MODULES | sudo tee /etc/modules-load.d/devcontainer-egress.conf"
    warn "    sudo systemctl restart systemd-modules-load"
    warn "  Then rebuild the container. Check NET_ADMIN as well: this feature asks for the"
    warn "  capability, but a runtime configured to refuse it fails here in the same way."
}

# Adds one rule to the chain and names it when the kernel refuses.
#
# Failing loudly matters more here than anywhere else in this file, and in both directions. A chain
# that loses its owner rule blocks the proxy too, so the container has no route out at all. A chain
# that loses its REJECT filters nothing while every report says it does. Neither is a state to
# start a container in quietly.
add_rule() {
    local why="$1"; shift
    iptables -A DEVCONTAINER_EGRESS "$@" 2>/dev/null && return 0
    warn "iptables refused the $why rule: $*"
    module_hint
    return 1
}

# Closes the proxy port on the way in from the outer network, where this container's siblings live.
# A bridge the inner daemon made is a different interface and is not matched, which is what still
# lets an inner container reach the proxy. Without this, listening on the container's own address
# would hand every peer on the host's docker network a proxy to the allowlisted hosts.
apply_input_guard() {
    local wan
    docker_present || return 0
    wan="$(wan_iface)"
    [ -n "$wan" ] || return 0
    iptables -D INPUT -i "$wan" -p tcp --dport "$PROXY_PORT" -j DROP 2>/dev/null
    iptables -I INPUT 1 -i "$wan" -p tcp --dport "$PROXY_PORT" -j DROP 2>/dev/null ||
        warn "iptables refused the INPUT rule: the proxy port stays open to peers on $wan"
}

# The FORWARD half. Same policy as the OUTPUT chain, applied to the packets the OUTPUT chain never
# sees: DNS to the pinned resolvers, everything else towards the outside world REJECTed.
#
# Our rules live in a chain of our own, jumped to from DOCKER-USER. DOCKER-USER is the one chain the
# daemon promises never to rewrite, and it is consulted before every rule dockerd owns. Keeping our
# rules one level down means flushing ours can never take dockerd's with it.
#
# Two orderings have to work, which is why the watcher calls this again. This entrypoint runs before
# docker-init.sh, so the first call usually happens with no daemon and no DOCKER-USER; and
# docker-init.sh may switch the iptables backend between legacy and nft after we have run, which
# leaves our first set of rules in the other table.
apply_docker_firewall() {
    local wan ns
    docker_present || return 0
    wan="$(wan_iface)"
    if [ -z "$wan" ]; then
        warn "no default route, so containers started by the inner daemon cannot be filtered"
        return 1
    fi

    iptables -F DEVCONTAINER_EGRESS_FWD 2>/dev/null || iptables -N DEVCONTAINER_EGRESS_FWD 2>/dev/null
    if ! iptables -S DEVCONTAINER_EGRESS_FWD >/dev/null 2>&1; then
        warn "iptables cannot create the forward chain, so containers started by the inner daemon"
        warn "  are UNFILTERED. This container's own traffic is still filtered."
        return 1
    fi
    # An inner container on the default bridge queries the resolvers from resolv.conf itself, so
    # without this it resolves nothing. Pinned to the same addresses as the OUTPUT chain, so the
    # tunnel that a blanket --dport 53 would open stays closed on this path as well.
    if [ "$ALLOW_DNS" = true ]; then
        while IFS= read -r ns; do
            [ -n "$ns" ] || continue
            iptables -A DEVCONTAINER_EGRESS_FWD -p udp --dport 53 -d "$ns" -j RETURN 2>/dev/null
            iptables -A DEVCONTAINER_EGRESS_FWD -p tcp --dport 53 -d "$ns" -j RETURN 2>/dev/null
        done <<< "$(dns_resolvers)"
    fi
    # The deny. Anything bound for the outside world leaves by the default route's interface.
    # Container to container never does, and neither does a packet to this container's own address,
    # which is the address the proxy answers on.
    if ! iptables -A DEVCONTAINER_EGRESS_FWD -o "$wan" \
            -j REJECT --reject-with icmp-port-unreachable 2>/dev/null; then
        warn "iptables refused the forward deny, so containers started by the inner daemon are"
        warn "  UNFILTERED. This container's own traffic is still filtered."
        iptables -F DEVCONTAINER_EGRESS_FWD 2>/dev/null
        return 1
    fi
    iptables -N DOCKER-USER 2>/dev/null
    iptables -C FORWARD -j DOCKER-USER 2>/dev/null || iptables -I FORWARD 1 -j DOCKER-USER 2>/dev/null
    iptables -D DOCKER-USER -j DEVCONTAINER_EGRESS_FWD 2>/dev/null
    if ! iptables -I DOCKER-USER 1 -j DEVCONTAINER_EGRESS_FWD 2>/dev/null; then
        warn "the forward chain was built but could not be attached, so containers started by the"
        warn "  inner daemon are UNFILTERED."
        return 1
    fi
    return 0
}

# Rules are idempotent: the chain is flushed first, so a restart or a reload cannot stack duplicates
# or leave a half-applied policy.
apply_firewall() {
    local uid ns resolvers pinned=""
    uid="$(id -u "$PROXY_USER" 2>/dev/null)" || { warn "no $PROXY_USER user; refusing to firewall"; return 1; }

    iptables -F DEVCONTAINER_EGRESS 2>/dev/null || iptables -N DEVCONTAINER_EGRESS 2>/dev/null
    # The chain itself is the first thing that can fail, and it fails for a different reason than a
    # single rule does: no NET_ADMIN, or no ip_tables at all. Checked rather than assumed, because
    # every -A below would then fail too and the pile of warnings would bury the cause.
    if ! iptables -S DEVCONTAINER_EGRESS >/dev/null 2>&1; then
        warn "iptables cannot create a chain, so nothing can be filtered."
        module_hint
        flush_firewall "iptables cannot create a chain (NET_ADMIN, or the ip_tables module)"
        return 1
    fi
    iptables -D OUTPUT -j DEVCONTAINER_EGRESS 2>/dev/null

    add_rule loopback -o lo -j ACCEPT || {
        flush_firewall "iptables refused the loopback rule"; return 1; }
    add_rule "established-connection" -m state --state ESTABLISHED,RELATED -j ACCEPT || {
        flush_firewall "the kernel has no xt_conntrack module"; return 1; }
    # Peers on the container's own networks, by destination address only, so a packet bound for the
    # internet never matches -- it carries an address outside the subnet even though it leaves
    # through the same gateway.
    local nets="" net
    while IFS= read -r net; do
        [ -n "$net" ] || continue
        if add_rule "local-network" -d "$net" -j ACCEPT; then
            nets="${nets:+$nets }$net"
        else
            warn "  peers on $net stay blocked"
        fi
    done <<< "$(local_networks)"
    # Per resolver, not per port: everything else on 53 falls through to the REJECT below.
    if [ "$ALLOW_DNS" = true ]; then
        resolvers="$(dns_resolvers)"
        while IFS= read -r ns; do
            [ -n "$ns" ] || continue
            if add_rule "dns" -p udp --dport 53 -d "$ns" -j ACCEPT &&
               add_rule "dns" -p tcp --dport 53 -d "$ns" -j ACCEPT; then
                pinned="${pinned:+$pinned }$ns"
            else
                warn "  queries to $ns will be blocked"
            fi
        done <<< "$resolvers"
        if [ -z "$pinned" ]; then
            warn "allowDns is on but no usable resolver was found, so name resolution will fail."
            warn "  Set the dnsServers option, or set allowDns=false to mean it deliberately."
        fi
    fi
    # The one route out. Everything the agent runs is some other uid, so it lands on the REJECT.
    # Above the DNS rules in effect, not in order: the proxy resolves server-side for the hosts it
    # is allowed to reach, and restricting it too would break allowDns=false, where resolving on
    # the container's behalf is the entire point.
    #
    # This rule and the REJECT under it are the firewall. Either one missing is a container nobody
    # should work in -- the first blocks the proxy along with everything else, the second leaves
    # egress open -- so the chain comes down rather than being left in that shape.
    add_rule "proxy-uid" -m owner --uid-owner "$uid" -j ACCEPT || {
        flush_firewall "the kernel has no xt_owner module, so the proxy cannot be let out"
        return 1; }
    add_rule "default-deny" -j REJECT --reject-with icmp-port-unreachable || {
        flush_firewall "the kernel has no ipt_REJECT target, so there is no default deny"
        return 1; }

    if ! iptables -A OUTPUT -j DEVCONTAINER_EGRESS 2>/dev/null ||
       ! iptables -C OUTPUT -j DEVCONTAINER_EGRESS 2>/dev/null; then
        # The chain built cleanly and then was not attached to anything. Verified rather than
        # assumed: an unattached chain filters nothing, and every earlier line of output says the
        # rules went in, which is exactly the report that gets believed.
        warn "the chain was built but could not be attached to OUTPUT; egress is unrestricted."
        module_hint
        flush_firewall "the chain could not be attached to OUTPUT"
        return 1
    fi
    # Docker's two extra paths, applied only once the OUTPUT chain is up and attached. Deliberately
    # last: a failure in either one leaves this container filtered exactly as before, and says so.
    local docker_state=none
    if docker_present; then
        apply_input_guard
        if apply_docker_firewall; then
            docker_state="filtered via $(docker_proxy_url), deny out $(wan_iface)"
        else
            docker_state="UNFILTERED -- see the log"
        fi
    fi

    # Line 1 is the marker, line 2 the resolvers that were actually pinned, line 3 the local
    # subnets that were opened, line 5 the state of the inner daemon. Separate lines because status
    # has to answer all of them and cannot query iptables without root.
    { echo applied; echo "$pinned"; echo "$nets"; echo; echo "$docker_state"; } \
        > "$STATE_FILE" 2>/dev/null
    chmod 0644 "$STATE_FILE" 2>/dev/null
    log "firewall applied: default deny, out via uid $uid only, dns=${pinned:-none}," \
        "local=${nets:-none}, docker=$docker_state"
}

# Takes an optional reason, which becomes line 4 of the state file. `status` runs as the remote
# user and cannot query iptables, so without it the only thing an unprivileged reader learns from a
# failed firewall is that it failed.
flush_firewall() {
    iptables -D OUTPUT -j DEVCONTAINER_EGRESS 2>/dev/null
    iptables -F DEVCONTAINER_EGRESS 2>/dev/null
    iptables -X DEVCONTAINER_EGRESS 2>/dev/null
    # The forward half comes down with it. Leaving it would filter containers started by the inner
    # daemon in a container whose own egress is open, which is a shape nobody would predict.
    local wan
    wan="$(wan_iface)"
    [ -n "$wan" ] && iptables -D INPUT -i "$wan" -p tcp --dport "$PROXY_PORT" -j DROP 2>/dev/null
    iptables -D DOCKER-USER -j DEVCONTAINER_EGRESS_FWD 2>/dev/null
    iptables -F DEVCONTAINER_EGRESS_FWD 2>/dev/null
    iptables -X DEVCONTAINER_EGRESS_FWD 2>/dev/null
    { echo absent; echo; echo; echo "${1:-}"; echo; } > "$STATE_FILE" 2>/dev/null
    chmod 0644 "$STATE_FILE" 2>/dev/null
    if [ -n "${1:-}" ]; then
        log "firewall removed: $1"
    else
        log "firewall removed"
    fi
}

# The firewall lets a peer through, and NO_PROXY is what stops a client sending the request to the
# proxy instead, where it would be denied for not being on the allowlist. CIDRs cover the clients
# that understand them (Go, docker); a service reached by name -- "db", "redis" -- has to be named
# in the noProxy option, because nothing here can know what compose called it.
#
# One function, three consumers: the shell environment, /etc/docker/daemon.json, and the client
# config that docker copies into every container it starts.
no_proxy_list() {
    local no_proxy="localhost,127.0.0.1,::1" net
    while IFS= read -r net; do
        [ -n "$net" ] && no_proxy="$no_proxy,$net"
    done <<< "$(local_networks 2>/dev/null)"
    [ -n "$NO_PROXY_EXTRA" ] && no_proxy="$no_proxy,$NO_PROXY_EXTRA"
    echo "$no_proxy"
}

# Advisory, and labelled as such. Tools that honour it get working networking without being told;
# tools that ignore it get REJECT instead of a silent bypass, which is the property that matters.
write_proxy_env() {
    local url="http://127.0.0.1:$PROXY_PORT" no_proxy
    no_proxy="$(no_proxy_list)"
    cat > /etc/profile.d/00-devcontainer-egress-filter.sh <<EOF
# Installed by the egress-filter feature. The firewall is the control; this is the convenience.
export HTTP_PROXY=$url  http_proxy=$url
export HTTPS_PROXY=$url https_proxy=$url
export NO_PROXY=$no_proxy no_proxy=$no_proxy
EOF
    chmod 0644 /etc/profile.d/00-devcontainer-egress-filter.sh
    # Read by PAM and by VS Code's environment probe, so terminals inherit it too.
    sed -i '/devcontainer-egress-filter/,+6d' /etc/environment 2>/dev/null
    {
        echo "# devcontainer-egress-filter"
        echo "HTTP_PROXY=$url"
        echo "HTTPS_PROXY=$url"
        echo "http_proxy=$url"
        echo "https_proxy=$url"
        echo "NO_PROXY=$no_proxy"
        echo "no_proxy=$no_proxy"
    } >> /etc/environment
}

# Merges a proxies block into a JSON file, keeping whatever else is in it -- registry credentials in
# config.json, a log-driver in daemon.json. The merge itself arrives on stdin as a python program,
# because the two files below hold the same three values under different names.
#
# Where there is no python3 the file is written only when there is nothing to lose. Overwriting
# somebody's daemon.json to add a proxy is not a trade to make quietly, so that case prints the
# block to add and leaves the file alone.
merge_json_conf() {
    local file="$1" fallback="$2" url="$3" np="$4" prog
    prog="$(cat)"
    if command -v python3 >/dev/null 2>&1; then
        # stderr is captured rather than let through: a traceback in the middle of a build log is
        # noise, and its last line -- the PermissionError, the JSONDecodeError -- is the whole
        # message. Kept, and printed under the warning that names the file.
        local err
        err="$(EGRESS_JSON_FILE="$file" EGRESS_PROXY_URL="$url" EGRESS_NO_PROXY="$np" \
            python3 -c "$prog" 2>&1)" && return 0
        warn "could not merge the proxy settings into $file"
        [ -n "$err" ] && printf '%s\n' "$err" | tail -1 | sed 's/^/!!!   /' >&2
        return 1
    fi
    if [ ! -s "$file" ]; then
        printf '%s\n' "$fallback" > "$file"
        return 0
    fi
    warn "$file already exists and python3 is not installed, so the proxy was not merged into it."
    warn "  Merge this by hand, or the inner Docker daemon cannot reach anything:"
    printf '%s\n' "$fallback" | sed 's/^/!!!   /' >&2
    return 1
}

# The daemon's own pulls. dockerd runs as root, so the OUTPUT chain rejects it like everything else,
# and it reads neither /etc/environment nor /etc/profile.d -- docker-init.sh starts it from the
# container environment. A daemon.json is the one channel that works without the person adding the
# feature also having to add containerEnv to their devcontainer.json.
#
# 127.0.0.1 and not the container address: dockerd shares this container's network namespace, so its
# loopback is ours, and the -o lo rule lets it through.
#
# dockerd reads this file once, when it starts, so *when* it is written decides whether it works at
# all. Written in two places for that reason, and neither one is redundant:
#
#   install.sh, at build time, covers the ordering this feature does not control. Entrypoints run in
#   install order, so when docker-in-docker installs first its entrypoint runs first and dockerd is
#   up before egress.sh gets a turn. In exactly that case dockerd is already installed when
#   install.sh runs, so the file is in the image before any daemon can start.
#
#   `up`, at container start, covers the other ordering and rewrites the no-proxy list with the
#   container's real local subnets, which the build could not know.
#
# Writing the file is all this does. Whether the running daemon is *using* it is a separate question
# with a separate answer -- see docker_daemon_sync.
docker_daemon_conf() {
    docker_present || return 0
    local f=/etc/docker/daemon.json url="http://127.0.0.1:$PROXY_PORT" np
    np="$(no_proxy_list)"
    install -d /etc/docker 2>/dev/null
    merge_json_conf "$f" \
"{
  \"proxies\": {
    \"http-proxy\": \"$url\",
    \"https-proxy\": \"$url\",
    \"no-proxy\": \"$np\"
  }
}" "$url" "$np" <<'PY' || return 1
import json, os
f = os.environ["EGRESS_JSON_FILE"]
url, np = os.environ["EGRESS_PROXY_URL"], os.environ["EGRESS_NO_PROXY"]
try:
    with open(f) as fh:
        d = json.load(fh)
    if not isinstance(d, dict):
        raise ValueError("daemon.json does not hold a JSON object")
except FileNotFoundError:
    d = {}
p = d.setdefault("proxies", {})
p["http-proxy"], p["https-proxy"], p["no-proxy"] = url, url, np
with open(f, "w") as fh:
    json.dump(d, fh, indent=2)
    fh.write("\n")
PY
    chmod 0644 "$f" 2>/dev/null
    return 0
}

# What the *running* daemon is using, which is not always what the file says. Asked of the daemon
# itself, because that is the only thing that answers the question -- a correct daemon.json proves
# nothing about a dockerd that started before it was written.
#
# Returns non-zero when the daemon could not be asked at all: no client, a socket the caller cannot
# open, a daemon still coming up. Every caller has to tell that apart from an answer of "no proxy" --
# they look identical in the output, and acting on the first as though it were the second would
# restart a healthy daemon and warn about a container the reader cannot fix.
docker_live_proxy() {
    command -v docker >/dev/null 2>&1 || return 1
    timeout 10 docker info --format '{{.HTTPProxy}}' 2>/dev/null
}

docker_daemon_running() { pgrep -x dockerd >/dev/null 2>&1; }

docker_running_containers() { timeout 10 docker ps -q 2>/dev/null; }

# docker-in-docker's own start script. Running it bare is what it is built for: it ends in
# `exec "$@"`, and `exec` with no arguments is a shell no-op that returns. It kills and retries
# dockerd itself when a start fails, so the pkill below is a move it already makes.
DOCKER_INIT=/usr/local/share/docker-init.sh

docker_restart_daemon() {
    local i=0
    if [ ! -x "$DOCKER_INIT" ]; then
        warn "there is no $DOCKER_INIT, so there is no start script to restart the daemon with"
        return 1
    fi
    pkill -x dockerd 2>/dev/null
    pkill -x containerd 2>/dev/null
    # The socket stays held for a moment after the signal, and docker-init.sh starting a second
    # daemon over the top of the first fails in a way that reads like a broken image. So wait.
    while [ "$i" -lt 50 ] && docker_daemon_running; do
        sleep 0.2; i=$((i + 1))
    done
    # Bounded, because this runs from the entrypoint. docker-init.sh retries five times with its own
    # waits, and a container that never finishes starting is worse than one that starts and says the
    # daemon is not proxied.
    timeout 120 "$DOCKER_INIT" || true
    i=0
    while [ "$i" -lt 30 ]; do
        timeout 5 docker info >/dev/null 2>&1 && return 0
        sleep 1; i=$((i + 1))
    done
    return 1
}

# Reports what the daemon is actually doing, and repairs the one case worth repairing.
#
# Saying "proxied" because the file is correct is worse than saying nothing. A daemon that missed its
# config fails its pulls as registry timeouts, so a person who reads that line goes looking at the
# allowlist rather than at the daemon. This follows the daemon instead.
#
# Returns 0 when the daemon is right or absent, 2 when it restarted the daemon, 1 when the daemon is
# wrong and stays wrong.
docker_daemon_sync() {
    local want="http://127.0.0.1:$PROXY_PORT" live
    docker_present || return 0
    if ! docker_daemon_running; then
        log "inner docker daemon will read $want when it starts"
        return 0
    fi
    if ! live="$(docker_live_proxy)"; then
        warn "dockerd is running but does not answer, so its proxy could not be checked."
        warn "  Run egress-status once it is up. If that reports a mismatch, restart it:"
        warn "    pkill dockerd; pkill containerd; $DOCKER_INIT"
        return 1
    fi
    if [ "$live" = "$want" ]; then
        log "inner docker daemon proxied via $want"
        return 0
    fi
    # A restart takes every running container with it. At container start there are none, which is
    # the only case this path exists for. Anywhere else it warns and changes nothing: a feature that
    # kills a person's containers to fix its own config is a worse bargain than a warning.
    if [ -n "$(docker_running_containers)" ]; then
        warn "dockerd is running WITHOUT the proxy and has containers running, so it was left alone."
        warn "  Its image pulls fail as registry timeouts, not as proxy errors."
        warn "  /etc/docker/daemon.json is correct. Restart the daemon when nothing needs it:"
        warn "    pkill dockerd; pkill containerd; $DOCKER_INIT"
        return 1
    fi
    warn "dockerd started before its proxy config was written, so it reports proxy '${live:-none}'."
    warn "  Restarting it. No containers are running, so nothing is lost."
    if ! docker_restart_daemon; then
        warn "the restart failed. dockerd is NOT proxied and every pull will time out."
        warn "  Restart it by hand: pkill dockerd; pkill containerd; $DOCKER_INIT"
        return 1
    fi
    live="$(docker_live_proxy)"
    if [ "$live" = "$want" ]; then
        log "inner docker daemon restarted, proxied via $want"
        return 2
    fi
    warn "dockerd restarted and still reports proxy '${live:-none}', not $want."
    warn "  Something else is setting it -- a containerEnv, or another daemon.json. Check both."
    return 1
}

# The client half. `docker run` and `docker build` copy this into every container they start, and it
# is the only way an inner container learns where the proxy is: it cannot read this container's
# environment, and 127.0.0.1 in there is its own loopback and not ours.
#
# Advisory in exactly the way HTTP_PROXY is out here. The DOCKER-USER rules are the control, and
# this is what keeps a well-behaved image from walking into one.
docker_client_conf() {
    local url f dir np
    url="$(docker_proxy_url)"
    [ -n "$url" ] || return 0
    [ -n "${USER_HOME:-}" ] && [ -d "$USER_HOME" ] || return 0
    dir="$USER_HOME/.docker"; f="$dir/config.json"
    np="$(no_proxy_list)"
    install -d "$dir" 2>/dev/null || return 0
    merge_json_conf "$f" \
"{
  \"proxies\": {
    \"default\": {
      \"httpProxy\": \"$url\",
      \"httpsProxy\": \"$url\",
      \"noProxy\": \"$np\"
    }
  }
}" "$url" "$np" <<'PY' || return 1
import json, os
f = os.environ["EGRESS_JSON_FILE"]
url, np = os.environ["EGRESS_PROXY_URL"], os.environ["EGRESS_NO_PROXY"]
try:
    with open(f) as fh:
        d = json.load(fh)
    if not isinstance(d, dict):
        raise ValueError("config.json does not hold a JSON object")
except FileNotFoundError:
    d = {}
p = d.setdefault("proxies", {}).setdefault("default", {})
p["httpProxy"], p["httpsProxy"], p["noProxy"] = url, url, np
with open(f, "w") as fh:
    json.dump(d, fh, indent=2)
    fh.write("\n")
PY
    chown -R "$USERNAME:" "$dir" 2>/dev/null
    chmod 0644 "$f" 2>/dev/null
    log "containers started by the inner daemon are pointed at $url"
}

status() {
    echo "egress-filter:"
    if [ -n "$(proxy_pid)" ]; then
        printf '  %-14s listening on 127.0.0.1:%s as %s\n' "proxy" "$PROXY_PORT" "$PROXY_USER"
    else
        printf '  %-14s NOT RUNNING\n' "proxy"
    fi

    # Read from the generated config rather than resolved again, because this runs unprivileged and
    # /proc/1/environ needs root. The file is what the proxy is actually using either way.
    local up
    up="$(sed -n 's/^Upstream http //p' "$PROXY_CONF" 2>/dev/null | head -1)"
    [ -n "$up" ] && printf '  %-14s via %s -- both allowlists apply\n' "upstream" "$up"

    # iptables cannot be queried without root, and this runs as the remote user, so asking it
    # directly reports "not applied" on a perfectly good firewall. Root gets the authoritative
    # answer; everyone else reads the marker the entrypoint left.
    local applied=no ns
    if [ "$(id -u)" = 0 ]; then
        iptables -C OUTPUT -j DEVCONTAINER_EGRESS 2>/dev/null && applied=yes
    elif [ "$(head -1 "$STATE_FILE" 2>/dev/null)" = applied ]; then
        applied=yes
    fi
    if [ "$applied" = yes ]; then
        printf '  %-14s default deny, dns=%s\n' "firewall" "$ALLOW_DNS"
    else
        printf '  %-14s NOT APPLIED -- egress is unrestricted\n' "firewall"
        # Line 4 of the state file, written by flush_firewall. Without it the only thing an
        # unprivileged reader learns is that the firewall is not there, which is the half of the
        # answer they already had.
        local why
        why="$(sed -n 4p "$STATE_FILE" 2>/dev/null)"
        [ -n "$why" ] && printf '  %-14s %s\n' "" "$why"
        [ -n "$why" ] && printf '  %-14s see the log: %s\n' "" "/var/log/devcontainer/egress-filter.log"
    fi

    # What port 53 may be opened to, which is a separate question from whether DNS is on at all.
    if [ "$ALLOW_DNS" != true ]; then
        printf '  %-14s blocked (allowDns=false); the proxy resolves instead\n' "dns"
    else
        if [ "$applied" = yes ]; then
            # What was pinned, not what would be. The two differ exactly when it matters: a
            # resolver iptables refused leaves the firewall up and DNS dead, and reading
            # resolv.conf here would report that container as fine.
            ns="$(sed -n 2p "$STATE_FILE" 2>/dev/null)"
        else
            ns="$(dns_resolvers 2>/dev/null | paste -sd' ' -)"
        fi
        if [ -n "$ns" ]; then
            printf '  %-14s port 53 to %s only\n' "dns" "$ns"
        else
            printf '  %-14s NO RESOLVER -- name resolution will fail\n' "dns"
        fi
    fi

    # Line 3 of the state file, for the same reason as the resolvers: what was opened, not what
    # would be. An unprivileged status has no other way to know.
    local nets
    if [ "$applied" = yes ]; then
        nets="$(sed -n 3p "$STATE_FILE" 2>/dev/null)"
    else
        nets="$(local_networks 2>/dev/null | paste -sd' ' -)"
    fi
    if [ -n "$nets" ]; then
        printf '  %-14s %s (direct, no proxy)\n' "local" "$nets"
    else
        printf '  %-14s none -- peers on the docker network are blocked too\n' "local"
    fi

    # Line 5, and only when there is an inner daemon to say anything about. The answer people need
    # here is not "is docker configured" but "does the filter reach what docker starts", so the
    # line says that and nothing else.
    if docker_present; then
        local dk
        dk="$(sed -n 5p "$STATE_FILE" 2>/dev/null)"
        [ -n "$dk" ] || dk="unknown -- the firewall has not been applied"
        printf '  %-14s %s\n' "docker" "$dk"
        # Asked of the daemon rather than read from daemon.json, because dockerd reads that file
        # once, at start. A correct file and an unproxied daemon look identical from the file, and
        # that pair is what sends people to read the allowlist when the daemon is the problem.
        # Only when the daemon actually answered. A `docker info` this reader cannot run -- no
        # docker group, no socket -- says nothing about the daemon's proxy, and reporting it as
        # "unset" would send the next person after a problem that is not there.
        local live want="http://127.0.0.1:$PROXY_PORT"
        if docker_daemon_running && live="$(docker_live_proxy)" && [ "$live" != "$want" ]; then
            printf '  %-14s daemon proxy is %s, not %s -- its pulls will time out\n' \
                "" "${live:-unset}" "$want"
            printf '  %-14s restart it: pkill dockerd; pkill containerd; %s\n' "" "$DOCKER_INIT"
        fi
    fi

    printf '  %-14s %s patterns (%s)\n' "allowlist" \
        "$( [ -r "$FILTER_FILE" ] && wc -l < "$FILTER_FILE" || echo 0 )" "$ALLOWLIST_FILE"
    [ -r "$SOURCES_FILE" ] && sed 's/^/                 /' "$SOURCES_FILE"
}

# Watches the global list, and *only* the global list. This is the part to be careful about.
#
# The global list is a bind mount of a file on the host, and it has to be read-only. Nothing in the
# container can write a read-only mount, so re-reading it whenever it changes is safe: the only
# party who can change it is the person at the keyboard, outside the container, and they get the
# change applied live.
#
# This feature cannot declare that mount itself, so it cannot enforce the flag either -- see the
# mount note in NOTES.md. check_global_mount below warns at container start when the mount is
# read-write, because the watcher here does not know the difference and applies whatever it reads.
#
# The project list is the opposite. It lives in the repo, which the container's user can write, so
# anything that re-read it on change would hand the agent a way to widen its own allowlist -- write
# a hostname, wait, reach it. That is not a filter. The project list is therefore read exactly once,
# at container start, and a change to it needs a restart. A restart is a human action and the file
# is in git, so widening the allowlist stays something a person does and can see in a diff.
#
# A checksum poll rather than inotify, unlike the sandbox sweeper: there, the gap between a socket
# appearing and being sealed is a hole someone can drive through. Here the gap is between the person
# editing their global list and it taking effect, and two seconds of that is a wait, not a weakness.
lists_checksum() {
    [ -r "$GLOBAL_LIST" ] && cksum < "$GLOBAL_LIST" 2>/dev/null
}

# The second thing the watcher looks at, and it exists for the inner Docker daemon alone.
#
# dockerd starts after this feature's entrypoint, and starting is when it creates docker0, when it
# builds its own FORWARD rules, and -- through docker-init.sh -- when the iptables backend may be
# switched from legacy to nft under us. Every one of those leaves the rules from the first pass in
# the wrong place or in the wrong table. So the interface set and the resolved iptables binary are
# watched, and the firewall goes back on when either moves.
#
# Re-applying is safe rather than merely tolerable: apply_firewall flushes its own chains first, so
# this converges instead of stacking. It also picks up a new docker network as a local network,
# which is what lets this container reach a container it just started.
topology_checksum() {
    { on_link_subnets 2>/dev/null | sort
      readlink -f "$(command -v iptables 2>/dev/null)" 2>/dev/null
    } | cksum 2>/dev/null
}

watch_daemon() {
    local last current last_topo topo
    last="$(lists_checksum)"
    last_topo="$(topology_checksum)"
    while true; do
        sleep "${WATCH_INTERVAL:-2}"
        current="$(lists_checksum)"
        if [ "$current" != "$last" ]; then
            last="$current"
            build_list >/dev/null 2>&1
            reload_proxy >/dev/null 2>&1
            log "the global list changed; allowlist reloaded"
        fi
        # Only when there is a daemon that can move the ground. Without one the interface set does
        # not change, and re-applying the firewall on a timer would be noise.
        docker_present || continue
        topo="$(topology_checksum)"
        if [ "$topo" != "$last_topo" ]; then
            last_topo="$topo"
            log "the container's networks changed; re-applying the firewall"
            apply_firewall
            # The address handed to inner containers is a bridge address, and the bridge is what
            # just changed. At container start there was none and the client config named eth0
            # instead, which a nested daemon can shadow -- see docker_proxy_url.
            docker_client_conf
        fi
    done
}

start_watcher() {
    pgrep -f 'egress\.sh watch' >/dev/null 2>&1 && return 0
    if command -v setsid >/dev/null 2>&1; then
        setsid nohup "$0" watch >> /var/log/devcontainer/egress-filter.log 2>&1 < /dev/null &
    else
        nohup "$0" watch >> /var/log/devcontainer/egress-filter.log 2>&1 < /dev/null &
    fi
    disown 2>/dev/null || true
    log "watching the global list for changes"
}

# The agent-facing half. A blocked request surfaces as a bare 403 with no mention of a filter, and
# npm goes further and blames your dependency versions -- so an agent that hits one will reasonably
# retry, switch registries, or start turning off certificate verification. None of that can work,
# and the last one is actively harmful. Telling it what happened costs nothing and changes no
# permissions: this is instructions, not capability, and there is still no way to widen the list
# from in here.
#
# Written at container start and not at build time, because persist-homedir puts /home on a volume
# that masks whatever the image left in $HOME -- the same trap that keeps the sandbox feature's env
# scrub in /etc.
install_agent_docs() {
    [ -n "${USER_HOME:-}" ] && [ -d "$USER_HOME" ] || return 0
    local dir="$USER_HOME/.claude/skills/egress-filter"
    install -d "$dir" 2>/dev/null || return 0
    cat > "$dir/SKILL.md" <<EOF
---
name: egress-filter
description: Diagnose and resolve blocked network requests in this container, which has default-deny outbound networking. Use this skill whenever ANY network operation fails - a 403, "CONNECT tunnel failed", "Filtered", a hang or timeout, or an npm, pip, apt, go, mix, hex, cargo or git error that looks like a permissions, registry, credentials or TLS problem - even when the error appears to be about something else entirely, which it usually does. Read this BEFORE retrying, switching registry or mirror, or disabling certificate verification, because none of those can work here and the last one is harmful.
---

$(cat "$SHARE_DIR/BLOCKED.md")
EOF
    chown -R "${USERNAME:-root}:" "$USER_HOME/.claude" 2>/dev/null || true
    log "agent notes installed at $dir/SKILL.md"
}

# The global list arrives on a mount this feature asks for and does not declare. Two things can be
# wrong with it, they have different fixes, so they get different warnings. Neither one is fatal:
# the baseline, the presets, the project list and the options all still apply, and a filter that
# refuses to start over a shorter allowlist is a filter people turn off.
#
# Read /proc/mounts rather than trying a write. A probe write on a read-write mount would land in
# the host's own config directory, which is the thing this check exists to protect.
#
# SC2016: the single quotes are the point. ${localEnv:HOME} is devcontainer.json syntax and ${HOME}
# is compose syntax, and both are meant to reach the reader unexpanded, exactly as they type them.
# shellcheck disable=SC2016
check_global_mount() {
    local dir opts
    dir="$(dirname "$GLOBAL_LIST")"

    if [ ! -d "$dir" ]; then
        warn "$dir is not mounted, so the global allowlist is not in effect."
        warn "  This feature does not declare the mount. Add it to your own config:"
        warn "    devcontainer.json, for a single container:"
        warn '      "mounts": ["type=bind,src=${localEnv:HOME}/.config/egress-filter,dst=/mnt/egress-filter,readonly"]'
        warn "    docker-compose.yml, for a compose project (readonly is dropped in devcontainer.json there):"
        warn '      volumes: ["${HOME}/.config/egress-filter:/mnt/egress-filter:ro"]'
        warn "  https://github.com/nshafer/devcontainer-features/tree/main/src/egress-filter"
        return 0
    fi

    opts="$(awk -v d="$dir" -v f="$GLOBAL_LIST" '$2 == d || $2 == f { print $4 }' /proc/mounts | tail -n1)"
    case ",${opts:-none}," in
        *,ro,*)
            ;;
        ,none,)
            warn "$dir exists but nothing is mounted there, so the global allowlist is yours only"
            warn "  in name. Mount the host directory over it -- see the feature's README."
            ;;
        *)
            warn "$dir is mounted READ-WRITE, so this container's own user can widen the global"
            warn "  allowlist, and the watcher applies the change within two seconds. The live"
            warn "  re-read is only safe on a read-only mount. Add readonly to the mount string in"
            warn "  devcontainer.json, or :ro to the volume in docker-compose.yml."
            ;;
    esac
}

up() {
    for tool in tinyproxy iptables; do
        command -v "$tool" >/dev/null 2>&1 || {
            warn "$tool is missing, so egress cannot be filtered. Leaving the network open rather"
            warn "  than half-closed -- a container that silently cannot reach anything is worse."
            return 1
        }
    done
    check_global_mount
    build_list
    write_proxy_conf
    start_proxy || return 1
    write_proxy_env
    # Both before apply_firewall, and both before docker-init.sh gets its turn at the entrypoint
    # chain. A daemon.json written after dockerd has read one is a daemon.json that does nothing.
    docker_daemon_conf
    docker_client_conf
    apply_firewall || return 1
    # After the firewall and not before it. This is where a daemon that started too early gets
    # restarted, and a restart is seconds long -- seconds this container spends unfiltered if the
    # chain is not up yet. A restart also rebuilds docker's own iptables chains, so the firewall
    # goes back on straight after rather than waiting for the watcher's next pass.
    docker_daemon_sync
    case $? in 2) apply_firewall ;; esac
    install_agent_docs
    start_watcher
}

case "${1:-status}" in
    up)          up ;;
    build)       build_list ;;
    reload)      build_list && reload_proxy ;;
    firewall)    apply_firewall ;;
    flush)       flush_firewall ;;
    watch)       watch_daemon ;;
    # Write /etc/docker/daemon.json and nothing else. install.sh calls this at build time, where
    # there is no daemon to sync with and no container network to read a no-proxy list from.
    docker-conf) docker_daemon_conf ;;
    status)      status ;;
    *)           echo "usage: egress.sh {up|build|reload|firewall|flush|watch|docker-conf|status}" >&2
                 exit 2 ;;
esac
