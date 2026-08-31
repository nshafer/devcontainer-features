# A request was blocked by egress-filter

This container has default-deny outbound networking. Everything is refused except hosts on an
allowlist, and the refusal happens at the firewall, so it is not something the failing tool can be
configured around.

## Recognizing it

The error is almost always a bare 403 from the proxy, and most tools describe it badly:

| tool | what you see |
| --- | --- |
| `curl` (https) | `curl: (56) CONNECT tunnel failed, response 403` |
| `curl` (http) | an HTML page titled *Blocked by egress-filter* |
| `git` | `fatal: unable to access '...': CONNECT tunnel failed, response 403` |
| `npm` | `npm error 403 ... Filtered`, followed by advice about forbidden package versions |
| `dig @8.8.8.8`, `nslookup ... 1.1.1.1` | a timeout, or `connection refused` |

DNS is its own case. Names still resolve, but only through the resolvers in `/etc/resolv.conf`:
port 53 to any other address is refused at the firewall, so pointing a lookup at a public resolver
fails even though ordinary resolution works. `egress-status` prints the resolvers that are allowed.

npm's message is misleading: it is not a version problem, a registry problem, or a credentials
problem. If a request fails with 403 and you did not expect an authorisation error, run
`egress-status` before doing anything else.

## What is *not* blocked

Other containers on this container's own docker network — a `docker-compose` database on 5432, a
cache on 6379 — are reachable directly. The firewall allows the subnets this container is attached
to. `egress-status` prints them on the `local` line. So a connection that fails to a service like
that is an ordinary problem — the service is not up, the port is wrong, the name does not resolve —
and not this filter.

One exception, for HTTP to such a service: a client that reads `HTTP_PROXY` sends the request to the
proxy, which denies it. The fix belongs in the feature's `noProxy` option and needs a restart, so
report it the same way as a blocked host.

## What will not work

There is deliberately no command in this container that adds a host to the allowlist. If there
were, anything running in here could widen its own network access, which is the thing this feature
exists to prevent. Specifically, none of these will help:

- retrying, or waiting and retrying
- a different mirror, registry, proxy or CDN
- `npm config set strict-ssl false`, `GIT_SSL_NO_VERIFY`, `curl -k` — the block is not a TLS
  failure, and turning off certificate checking makes things worse for no gain
- querying a different nameserver — `dig @1.1.1.1`, setting `DNS_SERVER`, editing
  `/etc/resolv.conf` — the firewall pins port 53 to the resolvers this container was given, and
  a name resolving does not mean the host behind it is reachable anyway
- editing `.devcontainer/egress-allow.txt` yourself — it is read once at container start and is not
  re-read while the container runs, so this changes nothing until someone restarts it

## What to do instead

Ask the person you are working with to allow the host, and tell them which one and why. There are
two lists, and the difference matters:

| list | where | scope | takes effect |
| --- | --- | --- | --- |
| global | `~/.config/egress-filter/allowlist.txt` **on their machine** | every container | within ~2s, no restart |
| project | `.devcontainer/egress-allow.txt` **in this repo** | this project | after a container restart |

A bare name allows that host exactly (`example.com`). A leading dot allows the domain and its
subdomains (`.github.com`). One per line.

A good request names the host, the tool, and what you were trying to do:

> I need `registry.npmjs.org` allowed to install dependencies — `npm ci` is failing with a 403 from
> the egress filter. Adding `registry.npmjs.org` to `~/.config/egress-filter/allowlist.txt` applies
> immediately; putting it in `.devcontainer/egress-allow.txt` needs a container restart.

## Working out what to ask for

`egress-denied` lists every host this container asked for and was refused, with a count. That is the
list to hand over -- it is what the build actually needed, rather than a guess. It reads only and
needs no privileges.

## Checking what is allowed

`egress-status` prints the active policy and every file it was merged from. It only reads, so it is
always safe to run.
