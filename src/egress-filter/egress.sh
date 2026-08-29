#!/usr/bin/env bash
# Default-deny egress, enforced by the firewall and decided by a proxy.
#
# The split matters. HTTP_PROXY is advisory -- an agent that ignores it is not filtered at all -- so
# the env var is a convenience and the firewall is the control:
#
#   OUTPUT: loopback, established, DNS, and anything owned by the proxy's uid.  Everything else
#           REJECTed. The agent has no route off the machine except through the proxy.
#
# The proxy then decides by hostname, taken from the CONNECT request, so lists are domains rather
# than addresses and there is no TLS interception and no CA to install. That last part is why this
# is a CONNECT proxy and not a MITM one: filtering by SNI/CONNECT host costs nothing, and reading
# the traffic would mean handing every TLS session to a certificate this feature generated.
#
# The two halves come apart cleanly, which is the nicest property here: changing the allowlist is a
# proxy reload (SIGHUP), never a firewall change. So lists can be edited live, by an unprivileged
# user, without anything being briefly open.
set -uo pipefail

CONFIG=/usr/local/share/nshafer-egress-filter/config
SHARE_DIR=/usr/local/share/nshafer-egress-filter
# Defaults so the script can be driven directly, which the tests do.
ALLOW=""
DENY=""
BASELINE=true
PROJECT_ALLOWLIST="/workspaces/*/.devcontainer/egress-allow.txt"
PRESETS=""
ALLOW_DNS=true
PROXY_PORT=3128
PROXY_USER=egressfilter
USERNAME=root
USER_HOME=/root
# shellcheck source=/dev/null
[ -r "$CONFIG" ] && . "$CONFIG"

GLOBAL_LIST="${EGRESS_GLOBAL_LIST:-/mnt/egress-filter/allowlist.txt}"  # read-only mount
# Overridable after the config is sourced, the same way GLOBAL_LIST is, so the preset
# merge can be exercised without rebuilding the image.
PRESETS="${EGRESS_PRESETS:-$PRESETS}"
FILTER_FILE=/etc/nshafer-egress-filter/allow.regex
PROXY_CONF=/etc/nshafer-egress-filter/tinyproxy.conf
SOURCES_FILE=/etc/nshafer-egress-filter/sources.txt
# Readable by anyone, because the status command has to work for the remote user and
# querying iptables needs root -- see firewall_state().
STATE_FILE=/run/nshafer-egress-filter.state
# The proxy's own log, separate from the feature's. It has to be a different file and it has to
# be pre-created: tinyproxy drops to $PROXY_USER before opening it, so a root-owned file is
# silently not written and every denial is lost -- which is exactly the record you need to build
# an allowlist from. World-readable on purpose, so the person building the list can read it
# without root.
PROXY_LOG=/var/log/nshafer-egress-filter-proxy.log

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

    if [ "$BASELINE" = true ] && [ -r "$SHARE_DIR/baseline-allow.txt" ]; then
        cat "$SHARE_DIR/baseline-allow.txt" >> "$tmp"
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
                cat "$file" >> "$tmp"
                used="$used $name"
            else
                warn "no such preset: $name (have: $(available_presets))"
            fi
        done
        [ -n "$used" ] && echo "presets: $used" >> "$SOURCES_FILE"
    fi

    if [ -r "$GLOBAL_LIST" ]; then
        cat "$GLOBAL_LIST" >> "$tmp"
        echo "global:   $GLOBAL_LIST" >> "$SOURCES_FILE"
    else
        echo "global:   $GLOBAL_LIST (absent)" >> "$SOURCES_FILE"
    fi

    # A glob, because a feature's entrypoint is never told the workspace folder -- it runs before
    # any of that is settled. Unquoted on purpose so the pattern expands.
    local found=no p
    # shellcheck disable=SC2086
    for p in $PROJECT_ALLOWLIST; do
        if [ -r "$p" ]; then
            cat "$p" >> "$tmp"
            echo "project:  $p" >> "$SOURCES_FILE"
            found=yes
        fi
    done
    [ "$found" = yes ] || echo "project:  $PROJECT_ALLOWLIST (none matched)" >> "$SOURCES_FILE"

    if [ -n "$ALLOW" ]; then
        echo "$ALLOW" | tr ',' '\n' >> "$tmp"
        echo "option:   allow=$ALLOW" >> "$SOURCES_FILE"
    fi

    to_regex < "$tmp" | sort -u > "$merged"

    if [ -n "$DENY" ]; then
        echo "$DENY" | tr ',' '\n' | to_regex | sort -u > "$denied"
        # Removes the exact patterns the deny list generates, so denying a host you also allowed
        # takes it out, and denying something never allowed is a no-op rather than an error.
        comm -23 "$merged" "$denied" > "$tmp" && mv "$tmp" "$merged"
        echo "option:   deny=$DENY" >> "$SOURCES_FILE"
    fi

    install -d "$(dirname "$FILTER_FILE")"
    mv "$merged" "$FILTER_FILE"
    chmod 0644 "$FILTER_FILE"
    rm -f "$tmp" "$denied" 2>/dev/null

    log "allowlist rebuilt: $(wc -l < "$FILTER_FILE") patterns"
}

write_proxy_conf() {
    install -d "$(dirname "$PROXY_CONF")"
    # Created before tinyproxy starts, owned by the user it drops to, readable by everyone.
    touch "$PROXY_LOG" 2>/dev/null
    chown "$PROXY_USER:" "$PROXY_LOG" 2>/dev/null
    chmod 0644 "$PROXY_LOG" 2>/dev/null
    cat > "$PROXY_CONF" <<EOF
# Generated by the egress-filter feature. Edits are overwritten.
User $PROXY_USER
Group $PROXY_USER
Port $PROXY_PORT
Listen 127.0.0.1
Timeout 600
Allow 127.0.0.1
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

# Rules are idempotent: the chain is flushed first, so a restart or a reload cannot stack duplicates
# or leave a half-applied policy.
apply_firewall() {
    local uid
    uid="$(id -u "$PROXY_USER" 2>/dev/null)" || { warn "no $PROXY_USER user; refusing to firewall"; return 1; }

    iptables -F NSHAFER_EGRESS 2>/dev/null || iptables -N NSHAFER_EGRESS 2>/dev/null
    iptables -D OUTPUT -j NSHAFER_EGRESS 2>/dev/null

    iptables -A NSHAFER_EGRESS -o lo -j ACCEPT
    iptables -A NSHAFER_EGRESS -m state --state ESTABLISHED,RELATED -j ACCEPT
    if [ "$ALLOW_DNS" = true ]; then
        iptables -A NSHAFER_EGRESS -p udp --dport 53 -j ACCEPT
        iptables -A NSHAFER_EGRESS -p tcp --dport 53 -j ACCEPT
    fi
    # The one route out. Everything the agent runs is some other uid, so it lands on the REJECT.
    iptables -A NSHAFER_EGRESS -m owner --uid-owner "$uid" -j ACCEPT
    iptables -A NSHAFER_EGRESS -j REJECT --reject-with icmp-port-unreachable

    iptables -A OUTPUT -j NSHAFER_EGRESS
    echo applied > "$STATE_FILE" 2>/dev/null; chmod 0644 "$STATE_FILE" 2>/dev/null
    log "firewall applied: default deny, out via uid $uid only, dns=$ALLOW_DNS"
}

flush_firewall() {
    iptables -D OUTPUT -j NSHAFER_EGRESS 2>/dev/null
    iptables -F NSHAFER_EGRESS 2>/dev/null
    iptables -X NSHAFER_EGRESS 2>/dev/null
    echo absent > "$STATE_FILE" 2>/dev/null
    log "firewall removed"
}

# Advisory, and labelled as such. Tools that honour it get working networking without being told;
# tools that ignore it get REJECT instead of a silent bypass, which is the property that matters.
write_proxy_env() {
    local url="http://127.0.0.1:$PROXY_PORT"
    cat > /etc/profile.d/00-nshafer-egress-filter.sh <<EOF
# Installed by the egress-filter feature. The firewall is the control; this is the convenience.
export HTTP_PROXY=$url  http_proxy=$url
export HTTPS_PROXY=$url https_proxy=$url
export NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1
EOF
    chmod 0644 /etc/profile.d/00-nshafer-egress-filter.sh
    # Read by PAM and by VS Code's environment probe, so terminals inherit it too.
    sed -i '/nshafer-egress-filter/,+4d' /etc/environment 2>/dev/null
    {
        echo "# nshafer-egress-filter"
        echo "HTTP_PROXY=$url"
        echo "HTTPS_PROXY=$url"
        echo "http_proxy=$url"
        echo "https_proxy=$url"
    } >> /etc/environment
}

status() {
    echo "egress-filter:"
    if [ -n "$(proxy_pid)" ]; then
        printf '  %-14s listening on 127.0.0.1:%s as %s\n' "proxy" "$PROXY_PORT" "$PROXY_USER"
    else
        printf '  %-14s NOT RUNNING\n' "proxy"
    fi

    # iptables cannot be queried without root, and this runs as the remote user, so asking it
    # directly reports "not applied" on a perfectly good firewall. Root gets the authoritative
    # answer; everyone else reads the marker the entrypoint left.
    if [ "$(id -u)" = 0 ]; then
        if iptables -C OUTPUT -j NSHAFER_EGRESS 2>/dev/null; then
            printf '  %-14s default deny, dns=%s\n' "firewall" "$ALLOW_DNS"
        else
            printf '  %-14s NOT APPLIED -- egress is unrestricted\n' "firewall"
        fi
    elif [ "$(cat "$STATE_FILE" 2>/dev/null)" = applied ]; then
        printf '  %-14s default deny, dns=%s\n' "firewall" "$ALLOW_DNS"
    else
        printf '  %-14s NOT APPLIED -- egress is unrestricted\n' "firewall"
    fi

    printf '  %-14s %s patterns\n' "allowlist" "$( [ -r "$FILTER_FILE" ] && wc -l < "$FILTER_FILE" || echo 0 )"
    [ -r "$SOURCES_FILE" ] && sed 's/^/                 /' "$SOURCES_FILE"
}

# Watches the global list, and *only* the global list. This is the part to be careful about.
#
# The global list is a read-only bind mount of a file on the host. Nothing in the container can
# write it, so re-reading it whenever it changes is safe: the only party who can change it is the
# person at the keyboard, outside the container, and they get the change applied live.
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

watch_daemon() {
    local last current
    last="$(lists_checksum)"
    while true; do
        sleep "${WATCH_INTERVAL:-2}"
        current="$(lists_checksum)"
        if [ "$current" != "$last" ]; then
            last="$current"
            build_list >/dev/null 2>&1
            reload_proxy >/dev/null 2>&1
            log "the global list changed; allowlist reloaded"
        fi
    done
}

start_watcher() {
    pgrep -f 'egress\.sh watch' >/dev/null 2>&1 && return 0
    if command -v setsid >/dev/null 2>&1; then
        setsid nohup "$0" watch >> /var/log/nshafer-egress-filter.log 2>&1 < /dev/null &
    else
        nohup "$0" watch >> /var/log/nshafer-egress-filter.log 2>&1 < /dev/null &
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

up() {
    for tool in tinyproxy iptables; do
        command -v "$tool" >/dev/null 2>&1 || {
            warn "$tool is missing, so egress cannot be filtered. Leaving the network open rather"
            warn "  than half-closed -- a container that silently cannot reach anything is worse."
            return 1
        }
    done
    build_list
    write_proxy_conf
    start_proxy || return 1
    write_proxy_env
    apply_firewall || return 1
    install_agent_docs
    start_watcher
}

case "${1:-status}" in
    up)         up ;;
    build)      build_list ;;
    reload)     build_list && reload_proxy ;;
    firewall)   apply_firewall ;;
    flush)      flush_firewall ;;
    watch)      watch_daemon ;;
    status)     status ;;
    *)          echo "usage: egress.sh {up|build|reload|firewall|flush|watch|status}" >&2; exit 2 ;;
esac
