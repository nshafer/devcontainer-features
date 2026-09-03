## Host setup

Three steps. Step 1 is once per machine, steps 2 and 3 are once per project.

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

### 3. Add the proxy to the container environment

Paste this into the same `.devcontainer/devcontainer.json`, beside `mounts`. It works for a compose
project too: the CLI renders `containerEnv` into its override file as `environment`.

```jsonc
"containerEnv": {
  "HTTP_PROXY": "http://127.0.0.1:3128",
  "HTTPS_PROXY": "http://127.0.0.1:3128",
  "http_proxy": "http://127.0.0.1:3128",
  "https_proxy": "http://127.0.0.1:3128",
  "NO_PROXY": "localhost,127.0.0.1,::1",
  "no_proxy": "localhost,127.0.0.1,::1"
}
```

Without it, a process that VS Code starts, and any process started with `docker exec`, gets no proxy
and every connection it makes is refused. A terminal is not affected. See
[Processes started by `docker exec`](#processes-started-by-docker-exec) for why the feature cannot
add this for you.

The block is the same on every machine. No subnet is in `NO_PROXY`, because the proxy forwards to
this container's local subnets by address itself. Two things in it follow an option, and only those:

- **The port** follows `proxyPort`.
- **`NO_PROXY`** repeats the names from `noProxy`: `"localhost,127.0.0.1,::1,db,redis"` for
  `"noProxy": "db,redis"`. `egress-status` prints the whole block with both filled in, so paste it
  from there.

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

**The proxy reaches these subnets too, by address.** A client that reads `HTTP_PROXY` sends a
request for `http://172.18.0.5:9000` to the proxy rather than straight to the peer. The allowlist is
hostnames, so the proxy used to deny that, and `NO_PROXY` had to name every subnet to keep such a
client off the proxy — a list that changed with every machine. Now `build_list` turns each subnet
into an anchored address pattern, `^172\.18\.[0-9]{1,3}\.[0-9]{1,3}$`, and the request reaches the
peer either way. Nothing is widened: every process here could already reach the peer directly. What
it buys is a `NO_PROXY` with no subnet in it, which is what lets the `containerEnv` block in step 3
be the same everywhere. `egress-status` lists the subnets under `local`, and the allowlist file
shows the pattern each one became.

**Name the services in `noProxy` if you talk HTTP to them.** A name is not an address, so no pattern
covers `http://db:8080`, and the proxy denies it. The feature cannot know what compose called the
service, so you say it, and the same names go into the `containerEnv` block:

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

### Docker inside the container

**An inner Docker daemon walks around the `OUTPUT` chain twice.** Add
`ghcr.io/devcontainers/features/docker-in-docker` and two holes open at once:

| what | why the chain misses it |
| --- | --- |
| `dockerd`'s own image pulls | It runs as root, so it lands on the `REJECT`. The failure reads as a registry timeout, which sends you to the registry rather than to the filter. |
| Containers that `dockerd` starts | Each one has its own network namespace. Its packets are `FORWARD`ed, never `OUTPUT`, so `-m owner` never sees them. |

The second one was a complete bypass. `docker run alpine wget https://anywhere` returned the page.

**The feature closes both, and does it only when `dockerd` is installed.** There is no option to
set. A container without an inner daemon sees no change at all.

| piece | what it does |
| --- | --- |
| `/etc/docker/daemon.json` | A `proxies` block pointing at `127.0.0.1:3128`. `dockerd` shares this container's network namespace, so its loopback is ours and the `-o lo` rule lets it through. |
| The proxy listens on every address | `127.0.0.1` inside a container is that container's own loopback, not ours. Binding named addresses would need a proxy restart every time a `docker network create` added one. |
| `~/.docker/config.json` | A `proxies.default` block naming the **bridge** address, not `eth0`. `docker run` and `docker build` copy it into every container they start. |
| `DOCKER-USER` | The same default deny as the `OUTPUT` chain, applied to the `FORWARD` path: DNS goes to the pinned resolvers, and the chain rejects everything else bound for the outside world. |
| An `INPUT` rule | Drops the proxy port on the way in from the network this container arrived on, so listening on the container address does not offer the proxy to every sibling. |

The feature **merges both JSON files and overwrites neither**. Registry credentials in `config.json` and a
`log-driver` in `daemon.json` survive. The merge uses `python3`. Where there is no `python3` and the
file already exists, the feature prints the block to add and does not touch the file.

```
$ egress-status
egress-filter:
  proxy          listening on 127.0.0.1:3128 as egressfilter
  firewall       default deny, dns=true
  dns            port 53 to 1.1.1.1 only
  local          172.17.0.0/16 172.18.0.0/16 (direct, and through the proxy by address)
  docker         filtered via http://172.17.0.2:3128, deny out eth0
```

**`DOCKER-USER` is the chain to use, and the daemon has to be running for it to matter.** Docker
promises never to rewrite that chain, and it consults it before every rule it owns. This feature's
entrypoint runs *before* `docker-init.sh`, so at that moment there is no daemon, no `docker0`, and —
because `docker-init.sh` may switch the `iptables` backend between `legacy` and `nft` — possibly not
even the right table. So the watcher already running for the global list also watches the interface
set and the resolved `iptables` binary, and re-applies the firewall when either moves. Re-applying
is safe: it empties each chain before it fills it, so this converges instead of stacking.

That same pass is what puts the inner bridge into `localNetworks`. `auto` cannot see `172.18.0.0/16`
at container start, because `dockerd` has not created it yet.

**Re-applying flushes each chain before it fills it**, so there is a window of about a millisecond
where the `OUTPUT` chain is empty and its policy is `ACCEPT`. That is how `apply_firewall` has always
worked — the `firewall` subcommand does the same thing — but with an inner daemon it now happens
again on each `docker network create` or `docker compose up` rather than once at container start. It
takes a process already running and already racing to use one.

**`dockerd` reads `daemon.json` once, when it starts, so when the file is written decides whether it
works.** Entrypoints run in install order. List `docker-in-docker` before `egress-filter` and its
entrypoint runs first, `dockerd` comes up before `egress.sh` gets a turn, and the file arrives too
late to be read. The daemon then pulls without the proxy for the life of the container, and the
failure looks like a registry timeout.

Three things close that:

| when | what |
| --- | --- |
| build time | `install.sh` writes `daemon.json` into the image. In the bad ordering `dockerd` is already installed by then, so the file is on disk before any daemon can start. |
| container start | `egress.sh` writes it again, with the real local subnets, which the build could not know. |
| after the firewall | `egress.sh` asks the running daemon what proxy it has. If the answer is wrong it restarts the daemon — but only when no containers are running. |

**The restart never takes a running container with it.** Where containers are running, `egress.sh`
warns, changes nothing, and prints the command. That case needs a person:

```
pkill dockerd; pkill containerd; /usr/local/share/docker-init.sh
```

**Every report about the daemon asks the daemon, not the file.** `egress-status` runs
`docker info` and prints a second `docker` line when the two disagree. A correct `daemon.json` and an
unproxied daemon look identical from the file, and that pair used to report success — which sent
people to read the allowlist when the daemon was the problem.

### A dev container inside a dev container

**The inner filter has no route out of its own.** The proxy it starts is a container of the *outer*
daemon, so the outer `DOCKER-USER` chain rejects it exactly like any other container. Every request
in the inner container then fails, and the inner allowlist is not the reason.

**`upstreamProxy` gives it one, and `auto` is the default.** The proxy takes a tinyproxy `Upstream`
line pointing at the outer proxy, so requests go inner proxy → outer proxy → the host:

```
$ egress-status
egress-filter:
  proxy          listening on 127.0.0.1:3128 as egressfilter
  upstream       via 172.17.0.2:3128 -- both allowlists apply
```

**Peers on the local subnets do not take the chain.** The generated config carries an
`Upstream none "172.18.0.0/16"` line for each subnet `localNetworks` opened, so a request for a peer
by address goes to the peer. Without that line it would go up the chain like everything else, and
the outer proxy would refuse an address it has no pattern for, with a 403 that reads as the inner
list's fault.

**Nothing is widened by this.** A host has to be on *both* lists to be reached. The inner proxy
refuses first on its own list, and the outer proxy refuses after on its own. Two containers deep is
two allowlists, and the outer one always wins.

`auto` reads `HTTP_PROXY` from the container's own PID 1 — the environment the runtime handed the
container, which nothing inside it can rewrite. It is deliberately *not* this script's environment:
`/etc/environment` names this proxy, so a second `egress.sh up` run from a shell would read its own
address back and chain the proxy to itself. A self-chain is caught and dropped either way.

| you want | set |
| --- | --- |
| chain to whatever the runtime gave this container | `"upstreamProxy": "auto"` (the default) |
| never chain | `"upstreamProxy": "off"` |
| a corporate proxy the environment does not name | `"upstreamProxy": "proxy.corp:8080"` |

The address the outer container hands down is its own, and `docker run` copies it in — see
`config.json` above. So a nested container needs no configuration for this to work.

**The outer proxy is also reachable directly, and the firewall keeps everything but the proxy away
from it.** That address sits on a local network, and `localNetworks: auto` opens local networks by
default. Without a rule, anything in the inner container connects to the outer proxy itself and is
filtered by the *outer* list — the wider of the two, because the inner one is applied on top of it.
So the chain rejects that address for every uid except the proxy's, above the local-network accepts:

```
-A DEVCONTAINER_EGRESS -d 172.18.0.1/32 -p tcp --dport 3128 -m owner ! --uid-owner 995 -j REJECT
-A DEVCONTAINER_EGRESS -d 172.18.0.0/16 -j ACCEPT
```

Both addresses are covered: the upstream this proxy chains to, and whatever `HTTP_PROXY` on PID 1
names. They are usually the same one. The proxy still chains through it and nothing else reaches it.
A proxy on `127.0.0.1` is the one exception, because the loopback accept sits above every rule in
the chain and narrowing it would close the route to this feature's own proxy.

**One client shape does not survive the extra hop, and busybox is the one that sends it.** Alpine's
`wget` cannot do TLS through a proxy, so for an `https://` URL it sends `GET https://host/...`
instead of a `CONNECT`. A single proxy answers that on its own. Forwarding it upstream turns the
host into `host:80https`, which matches no allowlist, and the outer proxy returns `403 Filtered` for
a host that is on both lists. Measured on the chain: plain `http`, and any real `CONNECT`, both
return 200. `curl`, `git`, `apt`, `npm` and the language toolchains all send `CONNECT`. Only reach
for `apk add curl` when a busybox container has to fetch `https` from two containers deep.

**Two things follow from this that are worth expecting.** A container you start is filtered by
hostname exactly like this one, so an image that pulls from a host you have not allowed fails the
same way — read `egress-denied`. And the proxy variables that reach a container are the ones in
`config.json`, so `docker run -e HTTP_PROXY=` clears them; the `DOCKER-USER` deny is what still
holds after that.

### Processes started by `docker exec`

**Add `containerEnv` to your own `devcontainer.json`, or a bare `docker exec` gets no proxy at
all.** The feature writes the proxy variables to two files, and a process has to read one of them:

| channel | who reads it | written |
| --- | --- | --- |
| `/etc/profile.d/00-devcontainer-egress-filter.sh` | a login shell, and the VS Code environment probe | at build time, into the image |
| `/etc/environment` | PAM, so a `su` session too | at container start |
| `containerEnv` in your `devcontainer.json` | every process in the container, `docker exec` included | by you |

A terminal goes through both, so `HTTP_PROXY` is there and everything works. A process that VS Code
or a tool starts with a plain `docker exec` reads neither, and the difference is visible from the
host:

```console
$ docker exec my-container sh -c 'env | grep -ci proxy'
0
```

**Why the profile.d file goes into the image.** VS Code execs its server into the container as soon
as the container runs, which can be seconds before this feature's entrypoint gets a turn:

```
19:05:56.0  container PID 1 starts
19:05:57.6  vscode-server starts
19:05:58.0  egress-filter entrypoint begins
19:05:58.4  writes /etc/profile.d/00-devcontainer-egress-filter.sh
```

The server runs its environment probe at start — a login shell, by default — and what that probe
returns is what the extension host and every process it starts carry for the life of the window. A
probe that ran before the file existed finds no proxy, and nothing corrects it later: the terminal
you open afterwards works, and the extension beside it does not. So `install.sh` writes the file
into the image and the ordering stops mattering. `up` rewrites it at container start with the real
local subnets, and only when the content changes.

`/etc/environment` stays at container start on purpose. `pam_env` reads it for `su`, and a build-time
copy would point a later feature that installs anything as the remote user at a proxy that does not
exist yet.

**The CLI writes to `/etc/environment` as well, and it writes last.** After the entrypoint runs, it
appends the whole container environment to that file — `containerEnv` included. `pam_env` takes the
last assignment, so a `containerEnv` with an incomplete `NO_PROXY` overrides the list this feature
wrote a second earlier. Two rules follow from that, and both are in `write_proxy_env`:

- When the container environment already carries the right values, the feature writes no block at
  all. The CLI's copy says the same thing, and a second copy of every variable only confuses whoever
  opens the file next.
- When it does not, the watcher rewrites the block every couple of seconds until it is the last one
  in the file. That fixes a login shell and a `su` session. It cannot fix a process started with
  `docker exec`, which never reads the file — only `containerEnv` reaches that one, which is why
  `status` reports the mismatch instead of quietly repairing it.

**`containerEnv` ends the race rather than shortening it.** With the block in place the server
inherits the proxy from the container config at the moment it is exec'd. No probe, no file, no
ordering to lose.

**Expect connection failures in exactly those processes until you add the block.** A VS Code
extension, a language server, a task, a CI step, anything started with `docker exec` — each one gets
no proxy, and the firewall refuses every connection it makes. What you see is a timeout, a hang, a
TLS error, or a registry that looks down. What you do not see is a missing variable, and a terminal
in the same container keeps working the whole time, which is what makes this one expensive to find.

The variables such a process inherits are the ones Docker stored when the container was created —
the image `ENV`, plus every `-e` on `docker run`. Nothing inside a running container can add to that
set. Only the project config can:

```jsonc
"containerEnv": {
  "HTTP_PROXY": "http://127.0.0.1:3128",
  "HTTPS_PROXY": "http://127.0.0.1:3128",
  "http_proxy": "http://127.0.0.1:3128",
  "https_proxy": "http://127.0.0.1:3128",
  "NO_PROXY": "localhost,127.0.0.1,::1",
  "no_proxy": "localhost,127.0.0.1,::1"
}
```

**Both cases earn their place.** `curl` ignores an uppercase `HTTP_PROXY` on purpose: a CGI request
header arrives under that name, and honouring it was the httpoxy vulnerability. So plain HTTP needs
`http_proxy` in lowercase. Measured in a container of this feature, against a host on no list:

| set | plain HTTP through the proxy |
| --- | --- |
| `HTTP_PROXY` alone | `000` — curl went direct and the firewall rejected it |
| `http_proxy` alone | `403` — curl used the proxy, which denied the host |

Uppercase is the spelling most other clients document, and `python`, `go` and `git` read either. So
the block carries both, and dropping a pair only costs you a client.

`status` reports which of three states this container is in:

```
container env  set -- a plain docker exec inherits the proxy
container env  NOT SET -- see the warning below
container env  http://172.18.0.1:3128 -- another proxy, see the warning below
```

A fourth state is the one that costs the most to find. The block names this proxy and its `NO_PROXY`
does not repeat a name from the `noProxy` option:

```
container env  set, but NO_PROXY is incomplete -- see the warning below
```

Every state except the first prints the whole block to paste, with this container's own port and
subnets already in it. Copy it from there rather than from this page.

The third state is a container of a filtered outer container. The outer feature writes a proxies
block into the docker client config, and Docker puts it on PID 1 of everything it starts, so
`HTTP_PROXY` is already there and it names the *outer* proxy. That proxy applies the outer list and
not this one, so the firewall refuses a direct connection to it from every uid but the proxy's —
see [A dev container inside a dev container](#a-dev-container-inside-a-dev-container).

**Why the feature cannot add it for you.** The CLI emits a feature's `containerEnv` as a Dockerfile
`ENV`, directly before that feature's own install step:

```dockerfile
ENV HTTP_PROXY=http://127.0.0.1:3128
RUN ... ./devcontainer-features-install.sh   # egress-filter
RUN ... ./devcontainer-features-install.sh   # every feature after it
```

The proxy starts at container start, not during the build, so that address refuses every connection.
`apt-get` inside this feature's `install.sh` fails, and so does every feature installed after it. A
project `containerEnv` has none of that problem: the CLI passes it as `docker run -e`, and the build
never sees it.

**The block is static, and it is meant to be.** `containerEnv` is a fixed string in a config file.
It cannot read the network, which is why no subnet is in it: the proxy forwards to the local subnets
by address (see [Sibling containers](#sibling-containers-and-docker-compose)), so the list this
feature writes is the same on every machine, and the block matches it. Three things still follow
from an option, and only those:

- **The port** follows `proxyPort`. Change both together.
- **`NO_PROXY`** repeats the names from `noProxy`. A name is not an address, so no pattern covers
  `http://db:8080`, and a client that reads the block sends it to the proxy, which denies it. The
  names belong in the option and in the block, under both spellings.
- **The upstream, in a nested dev container.** The outer proxy address reaches the inner container in
  `HTTP_PROXY`, which is the variable this block overwrites, so `upstreamProxy: auto` finds nothing
  to chain to. Set `upstreamProxy` to the outer address instead. See
  [A dev container inside a dev container](#a-dev-container-inside-a-dev-container).

`status` prints the block with the port and the names filled in, which is why it is the copy worth
taking.

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
