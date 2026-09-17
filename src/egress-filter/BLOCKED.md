# A request was blocked by egress-filter

This container blocks all outbound network traffic, except to the hosts on an allowlist. A firewall
in the container does the blocking. No setting in the failing tool can change it.

## How to recognize it

The error is almost always a bare 403 from the proxy. Most tools describe it badly:

| Tool                            | What you see                                                    |
| ------------------------------- | --------------------------------------------------------------- |
| `curl` (https)                  | `curl: (56) CONNECT tunnel failed, response 403`                |
| `curl` (http)                   | An HTML page with the title *Blocked by egress-filter*          |
| `git`                           | `fatal: unable to access '...': CONNECT tunnel failed, response 403` |
| `npm`                           | `npm error 403 Forbidden`, then advice about package versions   |
| `dig @8.8.8.8`, `nslookup ... 1.1.1.1` | A timeout, or `connection refused`                      |

DNS is a special case. Names still resolve, but only through the servers in `/etc/resolv.conf`. The
firewall refuses port 53 to any other address. So a lookup against a public resolver fails, even
though normal name resolution works. `egress-status` prints the servers that are allowed.

The message from npm is misleading. It is not a problem with a version, a registry or a credential.
If a request fails with a 403 and you did not expect an authorization error, run `egress-status`
first.

## What is not blocked

You can reach the other containers on the Docker network of this container. A Docker Compose
database on 5432, or a cache on 6379, is an example. The firewall allows the subnets of this
container, and `egress-status` prints them on the `local` line. So a failed
connection to such a service is an ordinary problem: the service is down, the port is wrong, or the
name does not resolve.

There is one exception. For HTTP to such a service, a client that reads `HTTP_PROXY` sends the
request to the proxy, which denies it. The fix belongs in the `noProxy` option of the feature, and
it needs a container restart. Report it in the same way as a blocked host.

## Containers that you start

If this container runs a Docker daemon, the same allowlist covers the image pulls of the daemon and
every container that you start. A build that fetches a host outside the list fails inside
the container. That error names no proxy at all:

| What you run                       | What you see                                       |
| ---------------------------------- | -------------------------------------------------- |
| `docker pull`                      | A registry timeout, or `failed to resolve reference` |
| `RUN apt-get update` in a build    | `Could not connect` for every mirror               |
| `docker run ... curl https://...`  | `Connection refused`, or a 403 from the proxy      |

`egress-status` prints a `docker` line when this applies. Treat it like any other block.
`egress-denied` lists every refusal, and a person still has to allow the host.

Two moves look like a fix and are not. `--network host` puts the container in the network namespace
of this container, where the same firewall rejects it. `docker run -e HTTP_PROXY=` removes the
polite route out, and the firewall then refuses the direct one.

## What will not work

There is deliberately no command in this container that adds a host to the allowlist. With such a
command, anything in here could widen its own network access, which is what this feature exists to
prevent. These do not help:

- A retry, or a wait and a retry.
- Another mirror, registry, proxy or CDN.
- `npm config set strict-ssl false`, `GIT_SSL_NO_VERIFY` or `curl -k`. The block is not a TLS
  failure. Turning off certificate checks makes things worse and gains nothing.
- Another nameserver: `dig @1.1.1.1`, a `DNS_SERVER` variable, or an edit of `/etc/resolv.conf`.
  The firewall pins port 53 to the servers of this container. A name that resolves does
  not mean that the host behind it is reachable.
- An edit of `.devcontainer/egress-allow.txt`. That file is read once at container start. It
  changes nothing until someone restarts the container.

## What to do instead

Ask the person you are working with to allow the host. Name the host, the tool and your goal. There
are two lists, and the difference matters:

| List    | Where                                                        | Scope           | Takes effect              |
| ------- | ------------------------------------------------------------ | --------------- | ------------------------- |
| global  | `~/.config/egress-filter/allowlist.txt` **on their machine** | Every container | within ~2s, no restart    |
| project | `.devcontainer/egress-allow.txt` **in this repository**      | This project    | After a container restart |

A bare name allows that host only: `example.com`. A leading dot also allows the subdomains:
`.github.com`. One for each line.

A good request looks like this:

> I need `registry.npmjs.org` allowed, so that I can install the dependencies. `npm ci` fails with
> a 403 from the egress filter. In `~/.config/egress-filter/allowlist.txt` the host applies
> immediately. In `.devcontainer/egress-allow.txt` it needs a container restart.

## How to work out what to ask for

`egress-denied` lists every host that this container asked for and did not reach, with a count.
Hand that list over. It is what the build needed, and not a guess. It reads only and needs no
privileges.

## How to check what is allowed

`egress-status` prints the active policy and every file that it came from. It reads only, so it is
always safe to run.
