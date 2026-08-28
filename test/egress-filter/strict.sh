#!/usr/bin/env bash
# Every option away from its default, which is the only way to know they are consulted at all.
set -e
source dev-container-features-test-lib
fetch() { timeout 15 curl -s -o /dev/null -w "%{http_code}" -x "http://127.0.0.1:8888" "https://$1" 2>/dev/null || echo 000; }
export -f fetch

check "the options reached the config" bash -c '
    . /usr/local/share/nshafer-egress-filter/config
    [ "$BASELINE" = false ]   || { echo "baseline: $BASELINE"; exit 1; }
    [ "$ALLOW_DNS" = false ]  || { echo "dns: $ALLOW_DNS"; exit 1; }
    [ "$PROXY_PORT" = 8888 ]  || { echo "port: $PROXY_PORT"; exit 1; }'

check "the proxy is on the configured port" bash -c '
    egress-status | tee /dev/stderr | grep -q "127.0.0.1:8888"'

check "baseline=false leaves the marketplace off the list" bash -c '
    ! grep -q "visualstudio" /etc/nshafer-egress-filter/allow.regex \
        || { echo "baseline was merged despite baseline=false"; exit 1; }'

check "the allow option is honoured" bash -c '
    code=$(fetch example.com); echo "  example.com=$code"; [ "$code" = 200 ]'

# deny is applied last, so it overrides an allow for the same host.
check "deny overrides allow for the same host" bash -c '
    grep -q "iana" /etc/nshafer-egress-filter/allow.regex \
        && { echo "denied host is still on the list"; exit 1; }
    code=$(fetch www.iana.org); echo "  www.iana.org=$code"; [ "$code" != 200 ]'

check "allowDns=false blocks the agent resolving for itself" bash -c '
    timeout 8 getent hosts example.com >/dev/null 2>&1 \
        && { echo "DNS still works despite allowDns=false"; exit 1; }
    echo "  resolution refused, as configured"'

# ...but the proxy resolves server-side, so allowed hosts still work without local DNS. That is the
# trade the README describes: the side channel closes, and anything resolving for itself breaks.
check "the proxy still reaches allowed hosts without local DNS" bash -c '
    code=$(fetch example.com); echo "  example.com via proxy=$code"; [ "$code" = 200 ]'

reportResults
