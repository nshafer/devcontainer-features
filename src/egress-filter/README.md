
# Egress filter (nshafer) (egress-filter)

Blocks all outbound network traffic from the container, except to the hosts on an allowlist. A firewall in the container enforces control, so a program that ignores HTTP_PROXY cannot connect either. A proxy enforces policy, so the lists hold host names and there is no TLS interception. The allowlist merges a global list on your host, a list in the repository, the options here, and a baseline that keeps VS Code working. Containers that an inner Docker daemon starts are filtered too.

## Example Usage

```json
"features": {
    "ghcr.io/nshafer/devcontainer-features/egress-filter:2": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| presets | Built-in host lists to allow, comma separated. Available: debian, ubuntu, alpine, npm, hex, go, python, rust, github, githubcopilot, gitlab, docker, claude. An unknown name gives a warning that lists the valid names. | string | - |
| allow | More hosts to allow, comma separated. A leading dot also allows the subdomains: '.github.com,pypi.org'. | string | - |
| deny | Hosts to remove from the merged allowlist, comma separated. Applied last, so it overrides the global list, the project list, the presets and the baseline. | string | - |
| baseline | Allow the hosts that VS Code itself needs: the marketplace, the extension CDNs and the update hosts. Without them, the server cannot install extensions, and the attach can hang. | boolean | true |
| projectAllowlist | Where the project list is in the container. A glob, because the entrypoint of a feature is not told the workspace folder. Read one time at container start, because the remote user can write the repository. Read the README. | string | /workspaces/*/.devcontainer/egress-allow.txt |
| allowDns | Let the container resolve names itself, against the servers in dnsServers only. The firewall refuses port 53 to any other address. Turn it off to close the last slow way out, at the cost of everything that resolves names for itself: git, package managers and most clients. | boolean | true |
| dnsServers | The IPv4 addresses or CIDRs that port 53 can go to, comma separated. Empty means the servers that the container runtime put in /etc/resolv.conf. Used only when allowDns is on. | string | - |
| localNetworks | The subnets that the container can reach directly, and through the proxy by address, such as the other containers of a Docker Compose project. 'auto' means the subnets that this container is attached to, from its own routing table, and only when they are private. 'off' blocks them. Anything else is a comma separated list of IPv4 CIDRs, which is how you narrow it to one peer. Read the README. | string | auto |
| noProxy | More entries for NO_PROXY, comma separated. The proxy reaches the local subnets by address, but a name is not an address: a client that reads HTTP_PROXY sends 'http://db:8080' to the proxy, which denies it. Name such services here: 'db,redis,minio'. Repeat the names in the containerEnv block in your devcontainer.json. Read the README. | string | - |
| upstreamProxy | Where the proxy sends what it cannot reach itself. A dev container inside a dev container needs this, because the inner proxy is a container of the outer daemon, and the outer firewall rejects it. 'auto' uses the HTTP_PROXY that the runtime gave this container, and does nothing when there is none. 'off' never chains. Anything else is a host:port. Both allowlists apply, the inner one first. | string | auto |
| proxyPort | The port that the filtering proxy listens on. Loopback only, unless an inner Docker daemon is installed. Then it also answers on the address of the container, which is the only one that a started container can reach. | string | 3128 |

## What it does

The container can reach the hosts that you allow. Every other outbound connection fails. Two parts
work together:

- **A firewall enforces control.** `iptables` rejects all outbound traffic, except loopback,
  established connections, DNS, and traffic from one user: the proxy. No program that the agent
  runs has that user ID, so no traffic leaves the container except through the proxy. The feature
  sets `HTTP_PROXY` as a convenience. A tool that ignores it gets a rejected connection, not a way
  around the filter.
- **A proxy enforces policy.** The proxy reads the host name in each request and compares it with the
  allowlist. So your lists hold host names, not IP addresses. **The proxy does not read your HTTPS
  traffic, and you do not install a certificate.**

A change to a list is a proxy reload. The firewall does not change, so nothing is open while you
edit. The proxy is closed for a fraction of a second during the reload, and a request in that
moment is refused.

> **Note:** Use this feature together with [`sandbox`](../sandbox). A remote user with `sudo` runs
> `iptables -F` and the whole filter is gone.

## Install

### 1. Make the folder on the host

Do this one time on each machine:

```bash
mkdir -p ~/.config/egress-filter
touch ~/.config/egress-filter/allowlist.txt
```

The folder is the mount source, so only the folder must exist. `allowlist.txt` is your global list.
An empty file is fine. Make it now, so that you have a place to add hosts later.

### 2. Add the features and a mount to your project

The feature reads the folder at `/mnt/egress-filter` in the container. You add the mount that puts
it there, and **the mount must be read-only**. The feature re-reads the global list while the
container runs, which is only safe because nothing in the container can write the file.
[Why you add the mount](#why-you-add-the-mount) tells why the feature cannot declare it.

For a single container, in `.devcontainer/devcontainer.json`:

```jsonc
"features": {
  "ghcr.io/nshafer/devcontainer-features/sandbox:3": {},
  "ghcr.io/nshafer/devcontainer-features/egress-filter:2": {
    "presets": "debian,npm,github"
  }
},
"mounts": [
  "type=bind,src=${localEnv:HOME}/.config/egress-filter,dst=/mnt/egress-filter,readonly"
]
```

For a Docker Compose project, put the mount in your service in `docker-compose.yml`:

```yaml
services:
  app:
    volumes:
      - ${HOME}/.config/egress-filter:/mnt/egress-filter:ro
```

> **Caution:** The container does not start if `~/.config/egress-filter` does not exist on the host.
> Do step 1 first.

In a Compose project, the mount must be in the Compose file. The CLI writes each
`devcontainer.json` mount into its own Compose override file as `<source>:<target>`, which has no
place for `readonly`. Compose merges volumes by target path, and the override file wins, so a `:ro`
entry in `devcontainer.json` does not survive either.

The feature warns at container start when the mount is missing, and warns again when the mount is
read-write.

### 3. Add the proxy to the container environment (optional)

Skip this step for VS Code. The feature writes the proxy variables to `/etc/profile.d` and
`/etc/environment`. VS Code reads them with its environment probe and applies them to the extension
host. Every extension and every terminal then has the proxy.

Add this block when something starts a process with a plain `docker exec` from outside VS Code: a CI
step, a script, or `devc exec sh`. Login shells work, such as `devc exec bash` since they read
`/etc/profile.d` and `/etc/environment`. Such a process reads neither file, so it gets no proxy, and
the firewall rejects every connection that it makes. Put the block in `devcontainer.json`, next to
`mounts`. It works in a Compose project too.

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

The block is the same on every machine. Two things in it follow an option:

- **The port** must match `proxyPort`.
- **`NO_PROXY`** must repeat the names from the `noProxy` option. For `"noProxy": "db,redis"`,
  write `"localhost,127.0.0.1,::1,db,redis"`.

No subnet is in `NO_PROXY`, because the proxy reaches the local subnets by address itself.
`egress-status` lists anything that the block misses. See
[Processes started by `docker exec`](#processes-started-by-docker-exec) for the detail.

### 4. Rebuild the container and check the result

```console
$ egress-status
egress-filter:
  proxy          listening on 127.0.0.1:3128 as egressfilter
  firewall       default deny, dns=true
  dns            port 53 to 127.0.0.11 only
  local          172.18.0.0/16 (direct, no proxy)
```

Then run `curl https://example.com`. It must fail with `CONNECT tunnel failed, response 403`.

## Allow a host

### The five sources of the allowlist

The feature merges five sources in this order. Each source adds hosts. The `deny` option runs last
and only removes hosts.

| Source      | Where                                                             | Scope                        | Applies             |
| ----------- | ----------------------------------------------------------------- | ---------------------------- | ------------------- |
| baseline    | Built in. Turn it off with `"baseline": false`.                   | What VS Code needs.          | At container start.  |
| presets     | The `presets` option in `devcontainer.json`.                      | Whole ecosystems by name.    | At container start.  |
| global      | `~/.config/egress-filter/allowlist.txt` on your host.             | Every container on this machine. | In about 2 seconds. |
| project     | `.devcontainer/egress-allow.txt` in the repository.               | This project.                | At container start.  |
| options     | `allow` and `deny` in `devcontainer.json`.                        | This container.              | At container start.  |

"At container start" means that you must restart the container. A rebuild is not necessary.

**Only the global list applies while the container runs.** It is a read-only mount of a file on
your machine, so nothing in the container can change it. A root loop in the container re-reads it
every 2 seconds. The project list is in the repository, which the remote user can write, so the
feature reads it one time at container start. To widen the project list, a person must edit a file
in git and restart the container. That is visible in a diff.

**There is no command that adds a host from inside the container.** Any such command would be a way
for an agent to widen its own access, which is what this feature exists to prevent. `egress-status`
shows what applies, and it only reads.

### The format of a list

One host for each line. A `#` starts a comment.

| Line               | What it allows                                        |
| ------------------ | ----------------------------------------------------- |
| `example.com`      | That host only.                                       |
| `.github.com`      | `github.com` and every subdomain of it.               |
| ` ^.*\.example\.com$ ` | A regular expression passes through as it is.     |

### Presets

A preset is a small list of hosts for one ecosystem. Name the ecosystems instead of 40 hosts:

```jsonc
"ghcr.io/nshafer/devcontainer-features/egress-filter:2": {
  "presets": "debian,npm,go,github,claude"
}
```

The presets are `debian`, `ubuntu`, `alpine`, `npm`, `hex`, `go`, `python`, `rust`, `github`,
`githubcopilot`, `gitlab`, `docker` and `claude`. Each one is a commented file in
[`src/egress-filter/presets/`](presets). The comments say which entries come from a real image or
client, and which are a first guess. An unknown name gives a warning that lists the valid names.

### Find the hosts that you need

`egress-denied` prints every host that the container asked for and did not reach, with a count. So
you allow what the build needed, and not a larger list:

```console
$ egress-denied
Hosts this container asked for and was refused:

  REQUESTS  HOST
         3  registry.npmjs.org
         1  objects.githubusercontent.com
```

It reads only and needs no privileges.

### See what applied

The file `/etc/devcontainer/egress-filter/allowlist.txt` holds the merged list with a header for
each source, in merge order, with the comments of each source:

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

The feature writes this file again at each reload. The header tells you which source to edit. A
host that `deny` removed is listed as removed, not left out, because a host that is quietly missing
from a merged list is the hardest question to answer.

`allow.regex` is the file that the proxy reads. It is sorted, escaped and anchored, and it says
nothing about where a line came from. Read the file above instead.

## Commands and logs

| Command or file                                        | What it is                                                  |
| ------------------------------------------------------ | ----------------------------------------------------------- |
| `egress-status`                                        | The active policy, and each file that it came from. Reads only. |
| `egress-denied`                                        | Each refused host, with a count. Reads only.                 |
| `/etc/devcontainer/egress-filter/allowlist.txt`        | The merged list, with a header for each source.             |
| `/var/log/devcontainer/egress-filter.log`              | What the feature did at container start, and its warnings.  |
| `/var/log/devcontainer/egress-filter-proxy.log`        | One line for each request. World-readable.                  |
| `/var/log/devcontainer/egress-filter-squid.log`        | What the proxy said. Read this when the proxy does not run. |

## What a blocked request looks like

The error is almost always a bare 403 from the proxy, and most tools describe it badly:

| Tool              | What you see                                                    |
| ----------------- | --------------------------------------------------------------- |
| `curl` (https)    | `curl: (56) CONNECT tunnel failed, response 403`                |
| `curl` (http)     | An HTML page with the title *Blocked by egress-filter*          |
| `git`             | `fatal: unable to access '...': CONNECT tunnel failed, response 403` |
| `npm`             | `npm error 403 Forbidden`, then advice about package versions    |
| `dig @8.8.8.8`    | A timeout, or `connection refused`                              |

So the feature explains the block in three places, because an agent that sees a 403 retries,
changes registry, or turns off certificate checks. None of those can work here, and the last one is
harmful.

- The 403 page of the proxy names the feature, the refused host and what to do.
- `/usr/local/share/devcontainer/egress-filter/BLOCKED.md` says the same at length, for any tool.
  The `postAttach` output points at it.
- The same text is installed as a Claude skill at `~/.claude/skills/egress-filter/SKILL.md`. The
  feature writes it at container start, because `persist-homedir` hides what the image left in the
  home directory.

A skill is model-invoked. Claude reads the name and description of each skill at all times, and
loads the body when it judges the skill relevant. So the description names the symptoms that an
agent sees, such as a 403 or a `CONNECT tunnel failed` message, and tells it to read the skill
before it retries. Claude may not load it, which is why the 403 page and `BLOCKED.md` carry the same
text.

All of it is instructions and no access. The agent still cannot widen the list.

## Other containers on the same network

**A dev container is often one service of a Docker Compose project.** The other services, such as
Postgres on 5432 or Redis on 6379, are on the same Docker network. Those connections never leave
the machine and never reach the proxy, but a default-deny firewall rejects them like any other
outbound connection. The symptom is a database that looks down.

**The `localNetworks` option is the answer, and `auto` is the default.** The firewall accepts
traffic to the subnets that this container is attached to, read from its own routing table.
`egress-status` lists them on the `local` line. The match is on the destination address, so a packet
to the internet never matches. It has an address outside the subnet, even though it leaves through
the same gateway.

`auto` accepts a subnet only when the subnet is private: `10/8`, `172.16/12`, `192.168/16`,
`100.64/10` or `169.254/16`. A public subnet on an interface means host networking or a `macvlan`,
where "the local network" is the internet. That case gives a warning, and the feature skips the
subnet.

**The proxy also reaches these subnets, by address.** A client that reads `HTTP_PROXY` sends a
request for `http://172.18.0.5:9000` to the proxy instead of to the peer. So the feature turns each
local subnet into an address pattern in the allowlist. For `172.18.0.0/16` the pattern is:

```
^172\.18\.[0-9]{1,3}\.[0-9]{1,3}$
```

This widens nothing, because every program in the container can already reach the peer directly.
What it buys is a `NO_PROXY` with no subnet in it, so the block in step 3 is the same on every
machine.

**Name your services in `noProxy` if you use HTTP to reach them.** A name is not an address, so no
pattern matches `http://db:8080`, and the proxy denies it. The feature cannot know the names, so you
give them, and you put the same names in the `containerEnv` block:

```jsonc
"ghcr.io/nshafer/devcontainer-features/egress-filter:2": {
  "presets": "debian,npm,github",
  "noProxy": "db,redis,minio"
}
```

**This is a real relaxation.** The subnet holds the Docker gateway, which is your host, and every
other container on that network. Those containers usually have full internet access, so an agent
that reaches one and makes it fetch something is out of the container. The trade is deliberate: a
filter that breaks the database of the project is a filter that people turn off. Two ways to make
it tighter:

| What you want            | What to set                              |
| ------------------------ | ---------------------------------------- |
| One peer only            | `"localNetworks": "172.18.0.5/32"`       |
| No local access at all   | `"localNetworks": "off"`                 |

Docker addresses change between runs of `docker compose up`, so a `/32` needs a static address on
the Compose network.

## Docker inside the container

**An inner Docker daemon goes around the firewall twice.** Add
`ghcr.io/devcontainers/features/docker-in-docker` and two holes open:

| What                                | Why the firewall misses it                                                |
| ----------------------------------- | ------------------------------------------------------------------------- |
| Image pulls by the daemon           | The daemon runs as root, so the reject rule stops it. The error reads like a registry timeout, which sends you to the registry and not to the filter. |
| Containers that the daemon starts   | Each one has its own network namespace. Its packets go through the `FORWARD` chain, never `OUTPUT`, so the user match never sees them. |

The second one was a complete bypass: `docker run alpine wget https://anywhere` returned the page.

**The feature closes both, and only when a Docker daemon is installed.** There is no option to set.
A container without an inner daemon sees no change.

| Piece                            | What it does                                                                 |
| -------------------------------- | ---------------------------------------------------------------------------- |
| `/etc/docker/daemon.json`        | A `proxies` block that points at `127.0.0.1:3128`. The daemon shares the network namespace of this container, so its loopback is ours. |
| The proxy listens on every address | `127.0.0.1` inside a started container is that container's own loopback, not ours. |
| `~/.docker/config.json`          | A `proxies.default` block with the bridge address. `docker run` and `docker build` copy it into every container that they start. |
| The `DOCKER-USER` chain          | The same default deny as the `OUTPUT` chain, for the `FORWARD` path. DNS goes to the pinned servers, and the chain rejects the rest. |
| An `INPUT` rule                  | Drops the proxy port on the way in from the network that this container is on, so the proxy is not open to other containers. |

The feature **merges both JSON files and overwrites neither**. Registry logins in `config.json` and
a `log-driver` in `daemon.json` stay. The merge needs `python3`. Without `python3`, and when the
file exists, the feature prints the block to add and changes nothing.

```console
$ egress-status
egress-filter:
  proxy          listening on 127.0.0.1:3128 as egressfilter
  firewall       default deny, dns=true
  dns            port 53 to 1.1.1.1 only
  local          172.17.0.0/16 172.18.0.0/16 (direct, and through the proxy by address)
  docker         filtered via http://172.17.0.2:3128, deny out eth0
```

**The feature watches for Docker networks and applies the rules again.** Docker promises never to
rewrite the `DOCKER-USER` chain, and it reads that chain before its own rules. But the entrypoint of
this feature runs before the Docker daemon starts, so at that moment there is no daemon, no
`docker0`, and possibly not the right `iptables` backend. So the loop that watches the global list
also watches the set of interfaces and the `iptables` program, and applies the firewall again when
either one changes. That pass also adds the inner bridge subnet to `localNetworks`, which `auto`
cannot see at container start.

**The daemon reads `daemon.json` one time, when it starts.** So the order matters. The feature
writes the file three times for that reason: at build time into the image, at container start with
the real local subnets, and again after the firewall if the running daemon reports the wrong proxy.
In the last case the feature restarts the daemon, but only when no containers are running. When
containers run, it warns, changes nothing, and prints the command for you:

```
pkill dockerd; pkill containerd; /usr/local/share/docker-init.sh
```

**Every report asks the daemon, not the file.** `egress-status` runs `docker info` and prints a
second `docker` line when the two disagree. A correct `daemon.json` and an unproxied daemon look
the same in the file.

Two more things to expect. A container that you start is filtered by host name exactly like this
one, so an image build that fetches an unlisted host fails the same way. And the proxy variables
that reach such a container come from `config.json`, so `docker run -e HTTP_PROXY=` clears them. The
`DOCKER-USER` deny still holds after that.

## A dev container inside a dev container

**The inner filter has no way out.** The proxy that it starts is a container of the **outer**
daemon, so the outer `DOCKER-USER` chain rejects it like any other container. Every request in the
inner container fails, and the inner allowlist is not the reason.

**The `upstreamProxy` option gives it a way out, and `auto` is the default.** The inner proxy sends
what it cannot reach to the outer proxy, which sends it to the host.

```console
$ egress-status
egress-filter:
  proxy          listening on 127.0.0.1:3128 as egressfilter
  upstream       via 172.17.0.2:3128 -- both allowlists apply
```

**Nothing is widened.** A host must be on both lists. The inner proxy refuses first on its own
list, and the outer proxy refuses after on its own. Two containers deep means two allowlists, and
the outer one always wins.

**Peers on the local subnets do not go up the chain.** The generated proxy config sends a request
for a local address straight to the peer. Without that rule, it would go to the outer proxy, which
has no pattern for that address, and the 403 would read like a fault of the inner list.

`auto` reads `HTTP_PROXY` from PID 1 of the container, which is the environment that the runtime
gave the container. Nothing inside the container can change it. The script does not read its own
environment, because `/etc/environment` names this proxy, and the proxy would then chain to itself.
The feature detects a self-chain and drops it.

| What you want                                            | What to set                            |
| -------------------------------------------------------- | -------------------------------------- |
| Chain to the proxy that the runtime gave this container   | `"upstreamProxy": "auto"` (the default) |
| Never chain                                               | `"upstreamProxy": "off"`               |
| A company proxy that the environment does not name        | `"upstreamProxy": "proxy.corp:8080"`   |

**The outer proxy is also reachable directly, and the firewall stops that.** The address of the
outer proxy is on a local network, and `localNetworks: auto` opens local networks. Without a rule,
a program in the inner container could connect to the outer proxy itself, and get the outer list,
which is the wider of the two. So the chain rejects that address for every user except the proxy:

```
-A DEVCONTAINER_EGRESS -d 172.18.0.1/32 -p tcp --dport 3128 -m owner ! --uid-owner 995 -j REJECT
-A DEVCONTAINER_EGRESS -d 172.18.0.0/16 -j ACCEPT
```

A proxy on `127.0.0.1` is the one exception, because the loopback accept is above every rule in the
chain.

**One kind of client does not survive the extra hop.** The `wget` in busybox cannot do TLS through a
proxy, so for an `https://` URL it sends `GET https://host/...` instead of a `CONNECT` request. One
proxy answers that. A pair of chained proxies does not. Measured on a chain: plain HTTP and any
real `CONNECT` request both return 200. `curl`, `git`, `apt`, `npm` and the language toolchains all
send `CONNECT`. Run `apk add curl` when a busybox container two levels deep must fetch HTTPS.

## Processes started by `docker exec`

**A plain `docker exec` from outside VS Code gets no proxy unless your `devcontainer.json` has the
`containerEnv` block. Everything that VS Code starts works without it.** The feature writes the
proxy variables to two files, and a process must read one of them:

| Channel                                           | Who reads it                                   | Written              |
| ------------------------------------------------- | ---------------------------------------------- | -------------------- |
| `/etc/profile.d/00-devcontainer-egress-filter.sh` | A login shell, and the VS Code environment probe | At build time, into the image. |
| `/etc/environment`                                | PAM, so a `su` session too                     | At container start.  |
| `containerEnv` in your `devcontainer.json`        | Every process in the container, `docker exec` included | By you.      |

A terminal reads both files, so it works. The extension host works too: VS Code runs the probe one
time at server start and applies the result. Measured in a container of this feature, the extension
host has all six variables, and the server process that started it has none. A process from a plain
`docker exec` reads neither file:

```console
$ docker exec my-container sh -c 'env | grep -ci proxy'
0
```

**Expect connection failures in exactly those processes until you add the block.** A VS Code
extension, a language server, a task, or a CI step gets no proxy, and the firewall refuses every
connection that it makes. You see a timeout, a hang, a TLS error, or a registry that looks down.
You do not see a missing variable, and a terminal in the same container keeps working, which is what
makes this expensive to find.

**Why the profile file goes into the image.** VS Code starts its server in the container as soon as
the container runs, which can be seconds before the entrypoint of this feature runs:

```
19:05:56.0  container PID 1 starts
19:05:57.6  vscode-server starts
19:05:58.0  egress-filter entrypoint begins
19:05:58.4  writes /etc/profile.d/00-devcontainer-egress-filter.sh
```

The server runs its environment probe at start, and the result is what the extension host carries
for the life of the window. A probe that ran before the file existed finds no proxy, and nothing
corrects it later. So the file is in the image, and the order stops mattering. The feature writes
the file again at container start, with the real local subnets, and only when the content changed.

`/etc/environment` stays a container-start file on purpose. A build-time copy would point a later
feature at a proxy that does not exist yet.

**The CLI also writes to `/etc/environment`, and it writes last.** After the entrypoint runs, the
CLI appends the whole container environment to that file, `containerEnv` included. PAM takes the
last assignment, so a `containerEnv` with an incomplete `NO_PROXY` overrides the list that this
feature wrote a second earlier. Two rules follow:

- When the container environment already has the right values, the feature writes no block at all.
- When it does not, the watcher writes the block again every couple of seconds, until the block is
  last in the file. That fixes a login shell and a `su` session. It cannot fix a `docker exec`
  process, which never reads the file.

**Why the block has both spellings.** `curl` ignores an uppercase `HTTP_PROXY` on purpose, because a
CGI request header arrives under that name. Measured in a container of this feature, against a host
on no list:

| What is set           | Plain HTTP through the proxy                              |
| --------------------- | --------------------------------------------------------- |
| `HTTP_PROXY` only     | `000`. `curl` went direct and the firewall rejected it.   |
| `http_proxy` only     | `403`. `curl` used the proxy, which denied the host.      |

Uppercase is the spelling that most other clients document, and `python`, `go` and `git` read
either one. So the block has both.

**Why the feature cannot add the block.** The CLI writes the `containerEnv` of a feature into the
generated Dockerfile as an `ENV` line, directly before the install step of that feature:

```dockerfile
ENV HTTP_PROXY=http://127.0.0.1:3128
RUN ... ./devcontainer-features-install.sh   # egress-filter
RUN ... ./devcontainer-features-install.sh   # every feature after it
```

The proxy starts at container start, not during the build, so that address refuses every
connection. `apt-get` in the install script of this feature fails, and so does every feature after
it. A `containerEnv` in your project has no such problem: the CLI passes it as `docker run -e`, and
the build never sees it.

**What `egress-status` says about it.** One line, in one of four states:

```
container env  set -- a bare docker exec inherits the proxy
container env  not set -- fine for VS Code, not for a bare docker exec (see README)
container env  http://172.18.0.1:3128 -- another proxy, refused by the firewall (see README)
container env  set, but NO_PROXY misses: db redis (see README)
```

The third state is a container inside a filtered container. The outer feature writes a proxies block
into the Docker client config, and Docker puts it on PID 1 of everything that it starts. So
`HTTP_PROXY` already names the **outer** proxy. That proxy applies the outer list and not this one,
so the firewall refuses a direct connection to it. See
[A dev container inside a dev container](#a-dev-container-inside-a-dev-container).

## Why you add the mount

A feature can declare mounts, but it cannot make a mount read-only in every setup. In a Docker
Compose project, the CLI drops the `readonly` flag. A feature-declared mount would then give the
container write access to the global list, and a program in the container could add a host to it,
live, in 2 seconds. So the feature declares no mount, and you add it in the place where `readonly`
works.

The feature checks what it got. A missing mount and a read-write mount each get their own warning in
`/var/log/devcontainer/egress-filter.log`. `egress-status` reports a missing mount as
`global: NOT MOUNTED`.

## Rootless Docker and Podman

This feature works under rootless Docker and under Podman, but the host needs preparation.

**Load the kernel modules on the host.** A container cannot load a kernel module. A rootless
container cannot even ask, because its netfilter tables are in a user namespace, and a user
namespace never loads a module. With a normal `dockerd`, the modules are already loaded, because the
daemon writes its own rules on the host. A Podman host may never have used netfilter at all. Load
the modules one time, on the host:

```bash
printf '%s\n' ip_tables iptable_filter xt_conntrack xt_owner ipt_REJECT \
  | sudo tee /etc/modules-load.d/devcontainer-egress.conf
sudo systemctl restart systemd-modules-load
```

A missing module does not leave half a firewall. The feature removes the chain, and the container
starts with open egress and says so. Run `egress-status`, and read
`/var/log/devcontainer/egress-filter.log` for the full text.

**Set `localNetworks` yourself under Podman.** Podman 5 uses `pasta` by default, and `pasta` copies
the addresses and routes of your host into the container. So `auto` reads the routing table, sees
your LAN subnet, accepts it as private, and opens your whole home network. Name the setting instead:

```json
"features": {
    "ghcr.io/nshafer/devcontainer-features/egress-filter:2": { "localNetworks": "off" }
}
```

`slirp4netns` gives `10.0.2.0/24` and needs nothing. Under rootless Docker, the subnet is the usual
private bridge range, and `auto` is correct.

**Relabel the mount under SELinux.** On Fedora and RHEL, the read-only bind mount carries no SELinux
option, so the container cannot read the global list. Relabel the folder on the host:

```bash
chcon -Rt container_file_t ~/.config/egress-filter
```

One thing to confirm on your host: the user match in the firewall is the whole control, and it must
match the proxy user inside the user namespace. Recent kernels map the user ID through the owner of
the network namespace, so it holds. Run `egress-status` after the first build, and read the
`firewall` line before you trust it.

## Limits and risks

**The filter fails open.** If the firewall cannot be applied, the feature removes the chain, and the
container starts with open network access. It writes a warning to the log, and `egress-status` shows
it. A container that does not start is worse than a container that starts and says that it is open.
So check `egress-status` after a rebuild.

**`sudo` removes the filter.** A remote user with `sudo` runs `iptables -F`. Use
[`sandbox`](../sandbox) with the default `sudoMode` of `drop`. If you use `"sudoMode":
"restricted"`, do not allow a firewall tool in `sudoCommands`. The check in that feature rejects one
for this reason.

**Every allowed host is a place where data can go.** The filter stops an agent from reaching a
random server. It does not stop an agent from pushing your code to a repository on a host that you
allowed, such as `github.com`. Keep the lists small.

**The filter reads host names, not content.** An allowed host is allowed for every path and every
request. The proxy does not open your HTTPS traffic.

**DNS is a side channel.** With `allowDns` on, which is the default, names still resolve, so a
program can put data into the names that it asks for. `allowDns: false` closes that channel,
because the proxy resolves names itself for the allowed hosts. The cost is that anything which
resolves names for itself stops working: git, package managers and most clients.

**Only HTTP and HTTPS get out.** Everything else, such as `git+ssh` or any other TCP connection, is
rejected. Peers on the local subnets are the exception. See
[Other containers on the same network](#other-containers-on-the-same-network).

**The local subnets are open.** See the relaxation in
[Other containers on the same network](#other-containers-on-the-same-network).

**The image build is not filtered.** The proxy and the firewall start when the container starts. A
`RUN` line in your Dockerfile, and the install script of every feature, run before that with full
network access.

**There is a short window while the firewall is applied again.** The feature empties each chain
before it fills it, so the `OUTPUT` chain is empty for about a millisecond, and its policy is
`ACCEPT`. This happens at container start, and again on each `docker network create` or
`docker compose up` when an inner Docker daemon is installed. It needs a program that is already
running and already waiting for the window.

**The `NET_ADMIN` capability is always added.** A feature cannot add a capability for some option
values only. That is why this is a separate feature, and not an option on `sandbox`: only the
projects that ask for the filter get the capability.

**The baseline hosts keep VS Code working.** The VS Code server installs extensions from inside the
container, and it runs as the same user as the agent, so a user rule cannot separate them. Without
the baseline, the container never finishes configuring. Turn `baseline` off only if you list those
hosts yourself.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nshafer/devcontainer-features/blob/main/src/egress-filter/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
