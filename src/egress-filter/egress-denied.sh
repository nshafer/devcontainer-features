#!/bin/sh
# What the filter has refused, so an allowlist can be built from evidence instead of guesswork.
#
# This is the intended way to work out what a project needs: run the build, see what it actually
# asked for, allow those. Guessing from a generic list gets you a superset you cannot justify and
# still misses the one host that matters.
#
# Reads only, and needs no privileges -- the proxy log is deliberately world-readable and owned by
# the proxy user, because the person building the list is not root.
LOG=/var/log/devcontainer/egress-filter-proxy.log

if [ ! -r "$LOG" ]; then
    echo "egress-denied: no proxy log at $LOG"
    echo "  The proxy may not have started. Run egress-status."
    exit 1
fi

# squid writes one line per request, and the feature's logformat puts the URL last:
#   04/Sep/2026:11:22:33 +0000 127.0.0.1 TCP_DENIED/403 3966 HIER_NONE/- CONNECT example.com:443
# A CONNECT names host:port and a GET names a full URL, so both get trimmed back to the host.
denied=$(grep -E ' [A-Z_]+/403 ' "$LOG" 2>/dev/null \
         | awk '{ print $NF }' \
         | sed -e 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||' -e 's|/.*||' -e 's|:[0-9]*$||' \
         | grep -v '^$' | sort | uniq -c | sort -rn)

if [ -z "$denied" ]; then
    echo "egress-denied: nothing has been refused since this container started."
    exit 0
fi

echo "Hosts this container asked for and was refused:"
echo ""
printf '  %8s  %s\n' "REQUESTS" "HOST"
echo "$denied" | while read -r count host; do
    printf '  %8s  %s\n' "$count" "$host"
done
echo ""
echo "To allow one, give the host to whoever runs this container. Either:"
echo "  their machine   ~/.config/egress-filter/allowlist.txt   applies within ~2s, no restart"
echo "  this repo       .devcontainer/egress-allow.txt          needs a container restart"
echo ""
echo "A leading dot allows subdomains too: .github.com"
