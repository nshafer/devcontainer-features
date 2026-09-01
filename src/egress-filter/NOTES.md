## Host setup

Two steps. Step 1 is once per machine, step 2 is once per project.

### 1. Create the directory on the host

```bash
mkdir -p ~/.config/egress-filter
touch ~/.config/egress-filter/allowlist.txt
```

The directory is the mount source, so only the directory has to exist. The `allowlist.txt` file is
the global list. It is optional, and an empty one is fine, but create it now so you have a place to
add hosts later.

### 2. Add the mount to your own config

This feature reads `/mnt/egress-filter` and does not mount anything there. You declare the mount,
and **it has to be read-only**: the live re-read of the global list is safe only because nothing in
the container can write it. [The mount is yours](#the-mount-is-yours) says why the feature cannot
declare it for you.

A single-container devcontainer, in `.devcontainer/devcontainer.json`:

```jsonc
"mounts": [
  "type=bind,src=${localEnv:HOME}/.config/egress-filter,dst=/mnt/egress-filter,readonly"
]
```

A compose project, in the service in your `docker-compose.yml`:

```yaml
services:
  app:
    volumes:
      - ${HOME}/.config/egress-filter:/mnt/egress-filter:ro
```

**Put it in the compose file there, not in `devcontainer.json`.** The CLI renders a
`devcontainer.json` mount into its compose override file as `<source>:<target>`, which has no place
for `readonly`, so that mount comes up read-write. The feature warns at container start when the
mount is missing, and warns again when it is read-write.

**A bind mount whose source does not exist stops the container from starting.** Docker does not
create it, so do step 1 before step 2. With no mount at all the container starts as usual, the
global list is simply not a source, and `egress-status` says `global: NOT MOUNTED`.

This feature also needs `sandbox` and its sudo drop. A remote user with sudo runs `iptables -F` and
the whole filter is gone. Use the two features together.

## Rootless Docker and Podman

This feature works under rootless Docker and under Podman, but the host has to be prepared. Three
things differ, and the first one is the only one that stops the filter completely.

**Load the kernel modules on the host.** A container cannot load a kernel module, and a rootless
container may not even ask: its netfilter tables live in a user namespace, and a user namespace
never autoloads. With a rootful `dockerd` this never shows, because the daemon writes its own
`iptables` rules on the host and the modules are already loaded by the time any container starts. A
Podman host may have used netfilter for nothing at all. Load them once, on the host:

```bash
printf '%s\n' ip_tables iptable_filter xt_conntrack xt_owner ipt_REJECT \
  | sudo tee /etc/modules-load.d/devcontainer-egress.conf
sudo systemctl restart systemd-modules-load
```

A missing module does not leave a half-built firewall. The chain comes down, `up` returns non-zero,
and the reason is written where an unprivileged reader can see it — run `egress-status`, and read
`/var/log/devcontainer/egress-filter.log` for the full text. The container starts with egress open
and says so, which is the same trade the rest of this feature makes.

**Set `localNetworks` yourself under Podman.** Podman 5 uses `pasta` by default, and `pasta` copies
the host's address and routes into the container. `auto` reads the routing table, so it sees your
LAN subnet, accepts it as private, and opens your whole home network. Name the setting instead:

```json
"features": {
    "ghcr.io/nshafer/devcontainer-features/egress-filter:2": { "localNetworks": "off" }
}
```

`slirp4netns` gives `10.0.2.0/24` and needs nothing. Under rootless Docker the subnet is the usual
private bridge range, and `auto` is correct there.

**Relabel the mount under SELinux.** On Fedora and RHEL the read-only bind mount of
`~/.config/egress-filter` carries no SELinux option, so the container cannot read the global list.
Relabel the directory on the host:

```bash
chcon -Rt container_file_t ~/.config/egress-filter
```

One thing to confirm on your own host: `-m owner --uid-owner` is the whole enforcement boundary, and
it has to match the proxy's uid inside the user namespace. Recent kernels map the uid through the
network namespace owner, so it holds. Run `egress-status` after the first build and read the
`firewall` line before you trust it.

## Notes

Default-deny outbound networking, decided by hostname. Two halves work together:

- **The firewall is the control.** `iptables` rejects everything outbound except loopback,
  established connections, DNS, and traffic owned by one dedicated uid — the proxy's. Nothing the
  agent runs is that uid, so there is no route off the machine that does not go through the proxy.
  `HTTP_PROXY` is set as a convenience. A tool that ignores it gets `REJECT`, not a bypass.
- **The proxy is the policy.** It filters on the hostname in the `CONNECT` request, so the lists are
  domains rather than addresses. **There is no TLS interception and no CA to install.**

That split is what makes the lists pleasant. Changing one is a proxy reload (`SIGHUP`), never a
firewall change, so nothing is briefly open while you edit.

### The allowlist

**Five sources, merged in order.** Later sources only add. `deny` is applied last and only removes:

| source | where | for |
| --- | --- | --- |
| baseline | built in, `baseline: false` to drop | what VS Code needs to attach and install extensions |
| presets | `presets` in `devcontainer.json` | whole ecosystems by name — `debian`, `npm`, `go`, … |
| global | `~/.config/egress-filter/allowlist.txt` on the host, on a read-only mount you declare | every container on this machine |
| project | `.devcontainer/egress-allow.txt` in the repo | this project |
| option | `allow` / `deny` in `devcontainer.json` | this container |

A bare name means that host. A leading dot means the domain and its subdomains. Anything that
already looks like a regex passes through.

**`presets` saves you from maintaining forty hostnames by hand.** Name the ecosystems instead:

```jsonc
"ghcr.io/nshafer/devcontainer-features/egress-filter:2": {
  "presets": "debian,npm,go,github,claude"
}
```

Available: `debian`, `ubuntu`, `alpine`, `npm`, `hex`, `go`, `python`, `rust`, `github`, `githubcopilot`, `gitlab`,
`docker`, `claude`. Each one is a small commented file under `src/egress-filter/presets/`. The comments say which
entries the author verified against a real image or client and which the author did not. The apt mirrors, npm registry,
Go proxy and Hex repo come from the running tools. The rest are first guesses. An unknown name is a **warning that lists
the valid ones**, never a silent no-op.

Two presets are easy to get wrong, and the feature handles both. `go` needs the *source* hosts as
well as the proxy, because `GOPROXY` ends in `,direct`. `docker` needs three hosts, since a missing
CDN fails only *after* the client has signed in.

**`/etc/devcontainer/egress-filter/allowlist.txt` shows exactly what applied.** `allow.regex` is
what the proxy reads, and it is unreadable at a glance — anchored, escaped, sorted, with no trace of
where any line came from. The concatenated file is the same content before that transformation,
every source in merge order behind a header, with each source's own comments intact:

```
# ============================================================================
# preset 'go': /usr/local/share/devcontainer/egress-filter/presets/go.txt
# ============================================================================
# Go modules. Verified with `go env GOPROXY GOSUMDB`.
proxy.golang.org
...
# ============================================================================
# option: deny, from devcontainer.json -- REMOVED from everything above
# ============================================================================
# removed: gopkg.in
```

`egress-status` names this file on the pattern-count line, so you can find it without knowing it
exists. The feature rewrites it on every reload and says so. The thing to edit is whichever source
the header points at. The feature records `deny` as a removal rather than a silent omission, since a
host quietly missing from a merged list is the hardest kind of allowlist question to answer.

### Sibling containers, and docker-compose

**A dev container is often one service of a `docker-compose` project.** The others — Postgres on
5432, Redis on 6379, MinIO on 9000 — are peers on the same docker network. Those connections never
leave the machine and never touch the proxy, but a default-deny `OUTPUT` chain rejects them exactly
like a connection to the internet. The symptom is a database that looks down.

**`localNetworks` is the answer, and it is `auto` by default.** The firewall accepts traffic whose
*destination* is one of the subnets this container is attached to, read from its own routing table:

```
$ egress-status
egress-filter:
  proxy          listening on 127.0.0.1:3128 as egressfilter
  firewall       default deny, dns=true
  dns            port 53 to 127.0.0.11 only
  local          172.18.0.0/16 (direct, no proxy)
```

The match is on the destination address, so a packet bound for the internet never qualifies. It
carries an address outside the subnet, even though it leaves through the same gateway.

`auto` accepts a subnet only when it is private — `10/8`, `172.16/12`, `192.168/16`, `100.64/10`,
`169.254/16`. A public subnet on an interface means host networking or a `macvlan`, where "the local
network" is the internet, and opening it would undo the filter. That case is a warning and a skip.

**Name the services in `noProxy` if you talk HTTP to them.** The firewall allows the peer, but a
client that reads `HTTP_PROXY` sends `http://db:8080` to the proxy, which denies it for not being on
the allowlist. The CIDRs go into `NO_PROXY` automatically, and Go and docker honour them, but `curl`
and Python match `NO_PROXY` by name only. The feature cannot know what compose called the service,
so you say it:

```jsonc
"ghcr.io/nshafer/devcontainer-features/egress-filter:2": {
  "presets": "debian,npm,github",
  "noProxy": "db,redis,minio"
}
```

**The relaxation is real, and worth naming.** The subnet holds the docker gateway, which is the
host, and every other container on that network. Those peers usually have unfiltered internet
access, so an agent that reaches one and makes it relay is out. This is a trade of local
reachability against that, taken because a filter that breaks the project's own database is a filter
people turn off. Two ways to tighten it:

| you want | set |
| --- | --- |
| one peer only | `"localNetworks": "172.18.0.5/32"` |
| no local access at all | `"localNetworks": "off"` |

Addresses from docker are not stable across a `docker compose up`, so a `/32` needs a static address
on the compose network to stay correct.

**Put the global allowlist mount in the compose file, not in `devcontainer.json`.** The CLI renders
every `devcontainer.json` mount into its compose override file as `<source>:<target>`, the short
volume syntax, which has no place for `readonly`. A `:ro` entry of your own in `devcontainer.json`
does not survive either: compose merges volumes by target path and the override file comes last, so
the override wins. The compose file is the one place where `:ro` holds. See
[The mount is yours](#the-mount-is-yours) and [Host setup](#host-setup).

### Building a list from evidence

**`egress-denied` is how you build a list from evidence.** It prints every host the container asked
for and was refused, with counts. So you allow what the build actually needed rather than a generic
superset:

```console
$ egress-denied
Hosts this container asked for and was refused:

  REQUESTS  HOST
         3  registry.npmjs.org
         1  objects.githubusercontent.com
```

It only reads and needs no privileges. The feature pre-creates the proxy log owned by the proxy user
and world-readable, so `egress-denied` can read every refusal.

### The mount is yours

**This feature declares no mount of its own, and version 1 did.** A feature's mount metadata is an
object with `source`, `target` and `type`, and that object has no field for the read-only flag.
Every way around it depends on how the container is built.

The `docker run` path renders a mount as `--mount type=<type>,src=<source>,dst=<target>`, so an
option on the end of a mount string reaches docker and `readonly` holds. A compose project renders
each mount as `<source>:<target>` instead, which has no place for an option. No single mount value
is read-only in both modes.

So a feature-declared mount promises the read-only global list this feature's whole watch model
rests on, and hands half its users a writable one — a file the container's own user can append a
hostname to, with the change live in two seconds. Version 1 did worse than that. It carried the flag
on the end of the target, `"target": "/mnt/egress-filter,readonly"`, which docker reads as an option
under `docker run` only: under compose it mounted the directory at a path literally named
`egress-filter,readonly`, read-write, and the global list was silently not a source at all.

The mount belongs to whoever knows which mode the container is in, and that is you. The feature
checks what it got. A missing mount and a read-write mount each get their own warning at container
start, in `/var/log/devcontainer/egress-filter.log`, and `egress-status` names a missing one on the
`global:` line.

### Who can widen the list, and when

**Only the global list is re-read while the container runs, and that asymmetry is the point.** It is
a read-only mount of a file on your machine, so nothing inside the container can write it. The only
party who can change it is you, at the keyboard, and a root loop applies the change within two
seconds. The project list lives in the repo, which the container's own user *can* write, so the
feature reads it exactly once at container start. Widening it needs a restart: a human action,
against a file in git, visible in a diff.

**A read-write mount breaks that asymmetry**, which is why the mount is yours to declare and why
the feature warns when it finds one. See [The mount is yours](#the-mount-is-yours).

There is deliberately **no command for adding a host from inside the container**. Anything the
container's user could run to widen the allowlist would be a way for the agent to widen it too, which
is the thing this feature exists to prevent. `egress-status` shows what is enforced and where it came
from, and it only reads.

### Explaining a block to an agent

**A blocked request explains itself, because otherwise it does not.** Measured, the failure an agent
actually sees is a bare 403 with no mention of a filter — `curl: (56) CONNECT tunnel failed,
response 403` — and npm goes further and blames your dependency versions. An agent that sees that
will reasonably retry, switch registries, or start turning off certificate verification. None of
those can work, and the last one is harmful. So three things carry the explanation:

- The proxy's 403 page names the feature, the refused host and the remedy (plain HTTP, and anything
  that surfaces the body — npm included).
- `/usr/local/share/devcontainer/egress-filter/BLOCKED.md` says the same at length, tool-agnostic,
  and the postAttach output points at it.
- The same text is installed as a Claude skill at `~/.claude/skills/egress-filter/SKILL.md`, written
  at *container start* rather than build time, because `persist-homedir` masks anything the image
  leaves in `$HOME`.

Skills are **model-invoked**, not commands. Claude sees every skill's `name` and `description` at all
times and loads the body when it judges one relevant. So the description is the whole trigger, and it
is written against the *symptoms* an agent will stare at — `403`, `CONNECT tunnel failed`, an npm
error about permissions — rather than the cause, which the agent has no way to see. Anthropic's own
`skill-creator` notes that Claude tends to *under*-trigger skills and advises making descriptions
"pushy". So this one is explicitly directive: read this **before** retrying, switching registry, or
disabling certificate verification. It is discretionary even so, which is why the 403 page and
`BLOCKED.md` carry the same information for the times it does not fire, and for agents that are not
Claude.

For HTTPS the client only ever sees the status code, so the instructions have to arrive before the
failure — which is what the skill is for. All of it is instructions and no capability. The agent
still cannot widen anything, and the notes say so, including that editing the project list will not
take effect.

### Things worth knowing

**The baseline exists because a default-deny network can hang the attach.** The VS Code server
installs extensions from inside the container and runs as the same uid as the agent, so uid rules
cannot separate them. Cut the marketplace off and you get a container that never finishes
configuring. Turn `baseline` off only if you are listing those hosts yourself.

**DNS is allowed by default and is a side channel.** Names still resolve, so an agent can encode data
into queries. `allowDns: false` closes it — the proxy resolves server-side, so allowed hosts keep
working — at the cost of anything that resolves for itself: git, package managers, most clients.

**Only HTTP and HTTPS get out.** Anything else — `git+ssh`, arbitrary TCP — is rejected outright.
This is correct for a default-deny posture, and surprising the first time. Peers on the container's
own docker network are the exception: see `localNetworks` above.

**`NET_ADMIN` is unconditional**, because `capAdd` is static metadata like everything else here.
That is why this is a separate feature rather than an option on `sandbox`. Only projects that ask for
egress filtering get the capability.
