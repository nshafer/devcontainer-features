# devcontainer-features

Personal [dev container features](https://containers.dev/implementors/features/). They hold my
Claude setup, git config files, persisted home directory, egress filter, sandbox and Tidewave
bridge, so I do not copy-paste them into every project's `devcontainer.json`.

Each feature has its own generated README with the full notes and options. This file covers the
features as a whole, the host setup, and the ways to use them. For a feature's own detail, follow
its link:

| Feature                                  | What it does                                                                                      |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------- |
| [`persist-homedir`](src/persist-homedir) | Keeps `/home` on a per-project named volume across rebuilds, minus the VS Code server/extensions. |
| [`git-config`](src/git-config)           | Copies the host's git config and excludes file into the container.                                |
| [`sandbox`](src/sandbox)                 | Seals the host sockets VS Code forwards in — SSH agent, GPG agent, X11, extension IPC.             |
| [`egress-filter`](src/egress-filter)     | Default-deny outbound networking with a hostname allowlist, enforced in-container.                 |
| [`claude`](src/claude)                   | Installs the Claude Code CLI at build time.                                                        |
| [`tidewave`](src/tidewave)               | Installs the Tidewave CLI and starts it on every container start.                                 |

## Quick Setup

Add to your `.devcontainer/devcontainer.json` (or `.devcontainer/devcontainer.local.json` if you use [local overrides](#use-with-local-overrides)):

```jsonc
{
  "features": {
    // Optional. Every feature here declares installsAfter common-utils, so if you use it, it runs
    // first and they see the user it created. Give it the same username the container runs as.
    "ghcr.io/devcontainers/features/common-utils:2": { "username": "devc" },

    "ghcr.io/nshafer/devcontainer-features/persist-homedir:1": {},
    "ghcr.io/nshafer/devcontainer-features/git-config:2": {},
    "ghcr.io/nshafer/devcontainer-features/sandbox:2": {},
    "ghcr.io/nshafer/devcontainer-features/egress-filter:2": { "presets": "debian,github,claude" },
    "ghcr.io/nshafer/devcontainer-features/claude:1": {},
    "ghcr.io/nshafer/devcontainer-features/tidewave:1": {}
  },

  // git-config and egress-filter read a mount that you declare and they do not. See step 2
  "mounts": [
    "type=bind,src=${localEnv:HOME}/.config/git,dst=/mnt/git-config,readonly",
    "type=bind,src=${localEnv:HOME}/.config/egress-filter,dst=/mnt/egress-filter,readonly"
  ],

  // Optional. VS Code gets the proxy from the environment probe without this. It is here for
  // processes started with a bare `docker exec` from outside VS Code, such as `devc exec sh`.
  "containerEnv": {
    "HTTP_PROXY": "http://127.0.0.1:3128",
    "HTTPS_PROXY": "http://127.0.0.1:3128",
    "http_proxy": "http://127.0.0.1:3128",
    "https_proxy": "http://127.0.0.1:3128",
    "NO_PROXY": "localhost,127.0.0.1,::1",
    "no_proxy": "localhost,127.0.0.1,::1"
  }
}
```

If using a compose project, put the mounts in the compose file instead of `devcontainer.json`. See [Add a local compose file](#add-a-local-compose-file) below.

```yaml
services:
  app:
    volumes:
      - ${HOME}/.config/git:/mnt/git-config:ro
      - ${HOME}/.config/egress-filter:/mnt/egress-filter:ro
```

## Host setup

Two features read a directory from your host home directory, and **neither one declares the mount**.
You do, in your own config. So the setup has two parts: a directory to create once per machine, and
a mount to add to every project that uses the feature.

The mount is yours because a feature cannot declare a read-only one. A feature's mount metadata is
an object with `source`, `target` and `type`, and that object has no field for the flag. Every way
around it depends on how the container is built: the `docker run` path takes an option on the end of
a mount string, and a compose project renders each mount as `<source>:<target>` and drops it. A
feature-declared mount would promise read-only and hand half its users a writable mount of their own
config directory. Both features warn at container start when the mount is not there.

**A bind mount whose source does not exist stops the container from starting.** Docker does not
create it; that is `-v` behaviour, not `--mount`. So create the directory before you add the mount.

### git-config

Create the directory, once per machine:

```bash
mkdir -p ~/.config/git
```

Git has two global config locations, and they are not additive. **If `~/.gitconfig` exists,
`~/.config/git/config` is ignored entirely**, so an empty `~/.gitconfig` created to satisfy a mount
would silently switch off the whole configuration of an XDG setup. Measured, not assumed. This
feature reads the XDG location only. If your global config lives in `~/.gitconfig`, move it:

```bash
mkdir -p ~/.config/git && mv ~/.gitconfig ~/.config/git/config
```

Then add the mount to the project. In `.devcontainer/devcontainer.json`:

```jsonc
"mounts": [
  "type=bind,src=${localEnv:HOME}/.config/git,dst=/mnt/git-config,readonly"
]
```

In a compose project, in the service in `docker-compose.yml`:

```yaml
services:
  app:
    volumes:
      - ${HOME}/.config/git:/mnt/git-config:ro
```

### egress-filter

Create the directory and the global list, once per machine:

```bash
mkdir -p ~/.config/egress-filter
touch ~/.config/egress-filter/allowlist.txt
```

The directory is the mount source, so only the directory has to exist. The file is the global
allowlist, and an empty one is fine.

Then add the mount to the project, the same two ways:

```jsonc
"mounts": [
  "type=bind,src=${localEnv:HOME}/.config/egress-filter,dst=/mnt/egress-filter,readonly"
]
```

```yaml
services:
  app:
    volumes:
      - ${HOME}/.config/egress-filter:/mnt/egress-filter:ro
```

**Keep this one read-only.** The global list is re-read while the container runs, and that is safe
only because nothing inside the container can write it. `egress-filter` warns when the mount is
read-write, and `egress-status` says `global: NOT MOUNTED` when it is missing.

One optional block remains, and VS Code does not need it: the feature writes the proxy variables
to `/etc/profile.d`, the VS Code environment probe reads them, and VS Code applies the probe to the
extension host. Add the block when something starts a process with a bare `docker exec` from
outside VS Code — a CI step, a script, `devc exec sh` — because such a process inherits the container
environment and nothing else. It works in a compose project as well, where the CLI renders it into
its override file as `environment`:

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

The feature cannot add the block itself — a feature's `containerEnv` becomes a Dockerfile `ENV`
placed before its own install step, and the proxy does not exist during the build.

The block is the same on every machine. No subnet is in `NO_PROXY`: the proxy forwards to the
container's local subnets by address itself. Only two things follow an option — the port follows
`proxyPort`, and `NO_PROXY` repeats the names from `noProxy` — and `egress-status` prints the block
with both filled in. See
[Processes started by `docker exec`](src/egress-filter/README.md#processes-started-by-docker-exec).

**In a compose project, put the mount in the compose file** Not in `devcontainer.json`. The CLI renders every
`devcontainer.json` mount into its compose override file as `<source>:<target>`, the short volume syntax, which has no
place for `readonly`. A `:ro` entry of your own in `devcontainer.json` does not survive either: compose merges volumes
by target path and the override file comes last, so the override wins.

### tidewave

`tidewave` mounts nothing, but a feature cannot open a port or read the host's home path. So set
`TIDEWAVE_HOST_PATH` on the host, and add `appPort` and `remoteEnv` to the project config. See [its
notes](src/tidewave).

### claude, persist-homedir, sandbox

These need no host filesystem setup. `sandbox` has recommended host *settings* that fully close the
forwarded channels — unforwarding the sockets and turning off the Wayland mount. See [its
notes](src/sandbox).

### Rootless Docker and Podman

`egress-filter` needs the host to load five kernel modules. A rootless container cannot load one
itself, and a Podman host often never used netfilter at all:

```bash
printf '%s\n' ip_tables iptable_filter xt_conntrack xt_owner ipt_REJECT \
  | sudo tee /etc/modules-load.d/devcontainer-egress.conf
sudo systemctl restart systemd-modules-load
```

Under Podman, also set `localNetworks` yourself. `pasta` copies the host routes into the container,
so `auto` would open your LAN. Under SELinux, relabel the two mounted directories.

Both steps are in [the egress-filter notes](src/egress-filter#rootless-docker-and-podman), with what
a missing module looks like. `sandbox` holds unchanged. [Its notes](src/sandbox#rootless-docker-and-podman)
say why, and what to check under `--userns=keep-id`.

## Use per-project

Name the features in the project's own `.devcontainer/devcontainer.json`. This form works
everywhere. The standalone `devcontainer` CLI reads the config and nothing else, so a container that
`devcontainer up` creates — on your machine or in CI — gets none of the VS Code defaults below.

```jsonc
{
  "name": "my-project",
  "image": "elixir:latest",
  "remoteUser": "devc",
  "features": {
    // Optional. Every feature here declares installsAfter common-utils, so if you use it, it runs
    // first and they see the user it created. Give it the same username the container runs as.
    "ghcr.io/devcontainers/features/common-utils:2": { "username": "devc" },

    "ghcr.io/nshafer/devcontainer-features/persist-homedir:1": {},
    "ghcr.io/nshafer/devcontainer-features/git-config:2": {},
    "ghcr.io/nshafer/devcontainer-features/sandbox:2": {},
    "ghcr.io/nshafer/devcontainer-features/egress-filter:2": { "presets": "debian,github,claude" },
    "ghcr.io/nshafer/devcontainer-features/claude:1": {},
    "ghcr.io/nshafer/devcontainer-features/tidewave:1": {}
  },

  // git-config and egress-filter read a mount that you declare and they do not. See Host setup
  // above, and put these in docker-compose.yml instead if the project is a compose project.
  "mounts": [
    "type=bind,src=${localEnv:HOME}/.config/git,dst=/mnt/git-config,readonly",
    "type=bind,src=${localEnv:HOME}/.config/egress-filter,dst=/mnt/egress-filter,readonly"
  ]
}
```

## Use with local overrides

A committed `devcontainer.json` describes the project, and your local tools do not belong in the project. Nobody else on
the repo asked to have their `sudo` removed or most of the internet blocked. This can be solved with [Repository
configuration
folders](https://code.visualstudio.com/docs/devcontainers/create-dev-container#_alternative-repository-configuration-folders)
but those require copying the whole devcontainer.json to customize it. What would be nice is a way to merge just a few
local override settings into the committed config. That is what `devc` does.

The spec has no inheritance between configs. The CLI reads exactly one file with `--config`. So [`bin/devc`](bin/devc)
does the inheritance instead: it merges a gitignored override file over the committed config, writes the result, and
passes `--config` for you, before calling the real CLI.

```
.devcontainer/
├── devcontainer.json          # committed -- the project, no personal features
├── devcontainer-lock.json     # committed
├── Dockerfile                 # committed, shared by both configs
├── devcontainer.local.json    # gitignored -- your changes, and nothing else
└── local/                     # generated, ignores itself
    ├── devcontainer.json      # the merge of the two files above
    └── devcontainer-lock.json
```

### Install it

`devc` wraps the CLI the "Dev Containers: Install devcontainer CLI" command puts on `PATH`. Put
`devc` on `PATH` beside it:

```bash
mkdir -p ~/bin
curl -fsSL -o ~/bin/devc https://raw.githubusercontent.com/nshafer/devcontainer-features/main/bin/devc
chmod +x ~/bin/devc
```

It is one file, and it needs python3 and nothing else. Run those three lines again for a new
version. If you cloned this repo, a symlink follows every `git pull` instead:

```bash
ln -s ~/src/devcontainer-features/bin/devc ~/bin/devc
```

`devc` looks for the real CLI in three places, in order: `devcontainer` on `PATH`, then
`~/bin/devcontainer`, then `npx @devcontainers/cli`. Set `DEVCONTAINER_CLI` to name a different
one, as a path or as a whole command line. The npx fallback covers `up`, `build` and `exec`, but
not `open`. The npm package carries no `open` subcommand, and `devc` says so before it runs.

Add the override file to the repo's `.gitignore`, to a local workspace-only `.git/info/exclude`,
or to your global `~/.config/git/ignore`:

```gitignore
.devcontainer/*.local.json
.devcontainer/*.local.yml
```

The second line covers the local compose file below. `devc` warns on every run while the override
file is still committable, and it checks the override file only. The generated `local/` directory
needs no entry, because `devc` writes a `.gitignore` of `*` inside it.

### Write the override file

`.devcontainer/devcontainer.local.json` holds only what you change. Comments and trailing commas
are allowed, as in any `devcontainer.json`:

The merge follows five rules:

| Written in the override file | Result in the generated config |
| --- | --- |
| `"remoteUser": "devc"` | Replaces the base value. |
| `"features": { ... }` | Two objects merge key by key, at every depth. |
| `"extensions+": ["a.b"]` | Appends to the base list. A `+` suffix needs a list on both sides. |
| `"extensions": ["a.b"]` | Replaces the base list. |
| `"features": { "./src/sandbox": null }` | Removes the key. |

Rows three and four are the pair to keep straight. `features` is an object, so a feature you add
lands beside the project's features. A list is not an object, so `"extensions"` throws the base
list away and `"extensions+"` keeps it.

### Add a local compose file

A compose project takes the same treatment one level down. `dockerComposeFile` accepts a list,
compose merges the files in order, and the last file wins. So the override file names a second
compose file, and that file holds your mounts. This is the pattern VS Code documents in [Extend
your Docker Compose file for
development](https://code.visualstudio.com/docs/devcontainers/create-dev-container#_extend-your-docker-compose-file-for-development),
with the extra file kept out of the repository.

The committed config names one file:

```jsonc
// .devcontainer/devcontainer.json -- committed
{
  "name": "my-project",
  "dockerComposeFile": "docker-compose.yml",
  "service": "app",
  "workspaceFolder": "/workspace"
}
```

The override file names both, in order:

```jsonc
// .devcontainer/devcontainer.local.json -- gitignored
{
  "dockerComposeFile": ["docker-compose.yml", "docker-compose.local.yml"],
}
```

Write the whole list. `"dockerComposeFile+"` fails here, because the base value is a string and the
`+` suffix needs a list on both sides. Where the base config already holds a list, `+` appends to
it.

Then write the local compose file beside the two configs. The service name has to match the
`service` in the config, and every other key merges into the committed service:

Three things to know:

- **Both paths stay relative to `.devcontainer/`**, the same as in the committed config. `devc`
  rewrites them for the generated config, which sits one directory deeper. A compose file at the
  repository root is `../docker-compose.yml` in both files.
- **Compose reads `${HOME}` from your shell, not from the devcontainer variables.** Compose
  resolves the variable itself, so `${localEnv:HOME}` means nothing in this file. An unset
  variable becomes an empty string, and the source turns into `/.config/git`.
- **This is the only way to get a read-only mount into a compose project.** A `mounts` entry in
  `devcontainer.json` renders as `<source>:<target>` and loses the flag, and the CLI's own override
  file comes last, so it wins on any target path you name twice. See [In a compose project, put the
  mount in the compose file](#in-a-compose-project-put-the-mount-in-the-compose-file) above.

`devc` does not warn about the compose file, so keep the `*.local.yml` line in `.gitignore`. With
`--local-config gpu`, name the file yourself and match it: `docker-compose.gpu.yml` beside
`devcontainer.gpu.json`.

### What devc rewrites

Paths in a `devcontainer.json` are relative to that file. The generated config sits one directory
deeper than the two files it comes from, so `devc` rewrites these to name the same place:

- `build.dockerfile` and `build.context`
- `dockerComposeFile`, and the older top-level `dockerFile` and `context`
- every feature named by a path, such as `./src/sandbox`

It also writes `build.context` out in full where the base config leaves it out. The context
defaults to the directory of the config file, and that directory changes, so the default alone
would build inside `local/` and `COPY` nothing from the repo.

One thing it does not rewrite: a relative `source=` in a `mounts` entry. Name those with
`${localWorkspaceFolder}`.

### Keep more than one override

`--local-config NAME` swaps `local` for a name of your own. The flag belongs to `devc`, and the
real CLI never sees it:

```bash
devc --local-config gpu up     # .devcontainer/devcontainer.gpu.json -> .devcontainer/gpu/
devc --local-config ci build   # .devcontainer/devcontainer.ci.json  -> .devcontainer/ci/
```

The name has to stay a single directory name. A `/` in it, or a leading `.`, stops the run.
Everything else works the same, the git warning included, which then names `*.gpu.json`.

### Stop and remove the container

The CLI has no `stop` and no `down`. The [pull request that adds
them](https://github.com/devcontainers/cli/pull/1041) is still open, so `devc` does it instead:

```bash
devc stop     # stop the container, and keep it
devc down     # stop it and remove it
```

Neither one starts the real CLI. `devc` asks the engine directly, because the engine already knows
which container belongs to this folder. `devcontainer up` stamps every container it creates with
`devcontainer.local_folder` and `devcontainer.config_file`, and the compose path writes the same
pair into the override file it generates. One lookup therefore covers an `image` config, a
Dockerfile config and a compose config alike.

What it runs depends on the container it finds:

| Config | `devc stop` | `devc down` |
| --- | --- | --- |
| `image` or `build` | `docker stop` | `docker rm -f` |
| `dockerComposeFile` | `docker compose -p NAME stop` | `docker compose -p NAME down` |

The project name comes from the container's own `com.docker.compose.project` label, so `devc` never
guesses it, and `docker compose -p NAME down` needs no compose file on disk. `down` takes the whole
project and not the one service, because the other services in it exist to serve the dev container.
It keeps the named volumes unless you ask for `devc down --volumes`.

The match is exact, and the config file is part of it, so `devc --local-config gpu down` removes the
`gpu` container and leaves the `local` one alone. Where the match is empty and the folder does have
containers from another config, `devc` names those and removes nothing. `--all-configs` widens the
match to every container of the workspace folder.

`DEVC_DOCKER` names the engine, in the way `DEVCONTAINER_CLI` names the CLI. Without it, `devc`
takes `docker`, then `podman`, from `PATH`.

### What devc passes straight through

`devc` runs the real CLI unchanged, with no merge, in three cases: no override file exists, you
passed your own `--config`, or the subcommand takes no `--config` at all. So `devc features test`
and `devc --version` behave as before, and a repo with no override file needs no second alias.

Four more notes:

- `devc merge` writes the generated config and reports what it did. It starts no container, and
  it needs no devcontainer CLI at all. VS Code watches the generated file, so a change makes it
  ask to rebuild. Where the content matches, `devc` leaves the file alone and prints
  `No changes detected`, so no rebuild prompt appears for nothing.
- `devc merged` prints the merge result to stdout and writes nothing. It creates no `local/`
  directory, and it leaves an existing one alone, so `devc merged | jq .features` is safe.
- VS Code looks one level down for `.devcontainer/*/devcontainer.json`, so "Reopen in Container"
  finds the generated config and offers a picker. `devc open` names it without the prompt.
- The lock file follows the config, so `devc upgrade` pins the feature digests in the gitignored
  `local/devcontainer-lock.json`. They never show in the project's diff. Run plain `devcontainer
  upgrade` to move the committed lock file instead.


## Use them everywhere

Another option with VS Code is to use the "Default Features" setting to use features in every project without having to add them to the `devcontainer.json` at all:

```jsonc
"dev.containers.defaultFeatures": {
  "ghcr.io/nshafer/devcontainer-features/claude:1": {},
  "ghcr.io/nshafer/devcontainer-features/git-config:2": {},
  "ghcr.io/nshafer/devcontainer-features/persist-homedir:1": {}
}
```

`tidewave` is deliberately not in that list. It needs a published port, and a feature cannot declare
one — see [its notes](src/tidewave) — so it belongs in the projects that actually want it.

`egress-filter` is not in it either. It adds the `NET_ADMIN` capability and needs `sandbox`'s sudo
drop, so it belongs in the containers that run an agent. Note that `sandbox`'s `restricted` sudo mode
undermines it if the allowlist names a firewall tool: root `iptables` flushes the whole filter. The
lint warns about exactly that.

`sandbox` is not in it either, for the opposite reason: it works everywhere, but it is supposed to
break things. Signing commits, `git push` over SSH, `code .` from the container terminal, GUI apps on
your desktop and **`sudo`** all stop working inside any container that has it. That is the trade it
exists to make, and it belongs in the containers that run an agent rather than in all of them.

`git-config` is in that list, and it still needs its mount in each project. The setting adds
features and cannot add a mount, so in a project without one the feature installs, warns on
`postCreate` that it copied nothing, and changes nothing else. Add the mount to the projects where
you want your git config.

Two things to know about that setting. The Dev Containers VS Code extension contributes it, so the
standalone `devcontainer` CLI ignores it — containers created with `devcontainer up` need the
features listed in the config. And a project that declares the same feature id itself wins, which is
how a project opts out or pins options.

## Publishing

`.github/workflows/release.yaml` publishes on a push to `main` when a feature's `version` in its
`devcontainer-feature.json` changes. It also regenerates each `src/<feature>/README.md` from the
metadata and the feature's `NOTES.md`. Bump the version in the same commit as the change.

## Develop on the features

This repo has its own `.devcontainer/`, and it runs the features it develops. Open the folder in a
container and `make lint`, `make test` and `make sandbox` all work from the terminal inside it.

The features come from the working tree, not from `ghcr.io`, so **"Rebuild Container" is how a
change is tried**. The published copies would exercise the last release instead. The price is that a
feature whose `install.sh` fails hard also fails the build of this container. Recover with "Reopen
Folder Locally", fix it, rebuild.

Five things in there are not obvious.

**The feature sources sit behind a symlink.** The CLI refuses a local feature path that resolves
outside `.devcontainer/`, so `"../src/claude"` fails with *"Resolved path must be a child of the
.devcontainer/ folder"*. `.devcontainer/src` is a symlink to `../src` and the config names
`"./src/claude"`. `.devcontainer/.dockerignore` keeps the link out of the build context, where it
has no job to do: the CLI copies each feature from a temp directory of its own.

**The Docker daemon is inside the container, not on the host.** `devcontainer features test` needs
Docker, and it needs Docker to see *this* container's filesystem. The mounted scenarios name paths
under the home directory of whoever runs the test, and docker-outside-of-docker would resolve them
against the host home directory instead. So the config adds `docker-in-docker`, and
`postCreateCommand` runs `make setup` to create the paths those mounts expect — the same host setup
as on a machine, for the same reason. It carries one option:
`"moby": false`. The base image is on Debian trixie, which has no `moby-cli` package, and the
feature stops the build rather than falling back to Docker CE on its own.

**dockerd reads the proxy from `/etc/docker/daemon.json`.** It never reads the `/etc/environment`
that `egress-filter` writes, because the docker-in-docker entrypoint starts it from the container
environment. `egress-filter` 2.1 writes that file itself, so nothing is needed here for dockerd.
Before it did, every image pull the harness made was rejected and the failure read as a registry
timeout. Hostnames are configured in two places — the presets on the feature, and
`.devcontainer/egress-allow.txt` for the rest. A container restart applies an edit to that file.

**The `containerEnv` block is for everything else.** `/etc/environment` and `/etc/profile.d/` reach
a login shell and the VS Code environment probe, and nothing else. A process started by a plain
`docker exec` — which is how some VS Code extensions start theirs — inherits only what Docker
stored when the container was created, so without that block it gets no proxy and every request it
makes is refused. A feature cannot supply it: the CLI emits a feature's `containerEnv` as a
Dockerfile `ENV` before that feature's install step, and the proxy does not exist during the build.
See [Processes started by `docker exec`](src/egress-filter/README.md#processes-started-by-docker-exec).

**`docker-in-docker` is pinned to `:4` for the iptables backend.** Version 2 moves Debian to the
legacy iptables backend with no check at all, and that backend needs `ip_tables` kernel modules. The
kernel belongs to the host, and a host running nftables only — Arch, Fedora, a recent Ubuntu — never
loads them. Two things then break at once, both quietly: dockerd stops at *"can not initialize
iptables table nat"* and retries forever, and `egress-filter` gets the same refusal on every rule,
logs each one, and still reports `firewall applied`. Version 4 moved the choice into
`docker-init.sh`, which reads `/proc/modules` at container start and takes nft when the legacy
modules are absent. That is the `iptablesSwitchAtRuntime` option, and it is on by default. A pin back
to `:2` brings the whole failure back, and needs a local feature to set the alternative to nft after
`docker-in-docker` has had its turn.

One order to keep in mind if that option is ever turned off. The entrypoints run as `egress-filter`,
`persist-homedir`, `sandbox`, `docker-init.sh`, so `egress-filter` applies its rules before
`docker-init.sh` chooses the backend. Both land on nft on a host without the legacy modules. On a
host that has them, dockerd would move to legacy after `egress-filter` had already written its chain
to nft, and `egress-status` as root would then read the empty backend.

**`sudo` is gone, so the tools ship in the image.** `sandbox` removes the remote user's blanket sudo
grant at container start, so `make`, `python3`, `shellcheck` and `iptables` are installed in
`.devcontainer/Dockerfile` rather than added later from a terminal. The same feature blocks the VS
Code git credential helper, so a push authenticates through `gh auth login`, which is what the
`github-cli` feature is there for.

**`sudo` is gone from the test containers too, which is why some scenarios run as root.**
`.devcontainer/devcontainer.json` sets `no-new-privileges` on this container. It used to arrive with
the `sandbox` feature, and cannot any more — the flag blocks every setuid path, `sudo` included, so a
feature that ships it unconditionally cannot also offer `sandbox`'s restricted sudo mode. The kernel passes `no_new_privs` to every
child process and never clears it, so the inner dockerd carries it, and so does every container the
test harness starts. A setuid binary cannot run there, and `sudo` is setuid. The `egress-filter`
tests are the only ones that wanted root — to read the iptables chain, and to rebuild the allowlist
the way a restart would. Those checks live in scenarios whose `remoteUser` is `root`: `strict`,
`presets`, `pinned-dns`, `privileged`, and `mounted-global`. `test/egress-filter/test.sh` keeps every check a non-root
process can prove, which is the half that says what the person and the agent can actually see. Root
is not exempt from the filter — only the proxy uid is — so a root scenario still measures the
filter. The whole suite passes here and on a host.

`tidewave` is the one feature this container leaves out. It needs a published port and it drives an
application, and this repo is shell scripts. Its own tests cover it.

## Tests

```bash
make            # what is available
make sandbox    # one feature
make test       # all of them, as CI runs them
```

The `Makefile` exists because every run needs the same three things set right — the right CLI, a base
image the feature can run on, and the host paths the mounted scenarios expect — and none of them are
the default. `QUICK=1` skips scenarios for an edit-run loop, `FILTER=<name>` narrows to one scenario, and
`ARGS=` passes anything else through.

`make lint` runs shellcheck, `bash -n` and a JSON parse in a couple of seconds without starting a
container, and CI runs it as its own job. It lints `src/` with no exclusions — what ships is held to
the stricter standard, and the few deliberate patterns there carry inline directives with a reason
next to each. It lints the test scripts with three checks off, all structural rather than
sloppiness: `SC2016` (the `bash -c '...$VAR...'` idiom, where deferring expansion to the inner shell
is the entire point), `SC1091` (the test lib only exists inside the container) and `SC2088` (a
literal `~` inside a check's description string, which is prose, not a path).

One trap it removes: on a machine with VS Code installed, the `devcontainer` on `PATH` is a wrapper
that appends `--workspace-folder`, which `features test` rejects outright. The Makefile calls the npm
CLI through `npx` instead. The underlying command is:

```bash
npx @devcontainers/cli features test -f claude -i node -u node .
```

`-i`/`-u` are not optional in spirit: `claude`, `git-config` and `persist-homedir` key off the remote
user's home directory, and the harness default (`ubuntu:focal`, running as root) exercises none of
the interesting paths. The host paths from [Host setup](#host-setup) have to exist too, because two
scenarios mount them: `git-config`'s `mounted` and `egress-filter`'s `mounted-global`. No feature
declares a mount of its own, so those two scenarios are where a real mount is tested, and they
declare it the way you do in a project.

`sandbox` is the exception to `-i node`: its tests have to become root to check what the *remote
user* can no longer reach, and the plain `node` image has no `sudo`. CI gives it a devcontainers base
for that reason, and so should you:

```bash
npx @devcontainers/cli features test -f sandbox \
    -i mcr.microsoft.com/devcontainers/javascript-node:20 -u node .
```

Those two flags apply to the autogenerated test only. Each feature's `test/<feature>/scenarios.json`
names its own image, which is how `tidewave` gets tested on Alpine at all — and how `sandbox` gets a
container with `CAP_SYS_ADMIN`, the only way to build a real bind mount and prove the guard that
keeps it from writing through to the host. A scenario also names its own `remoteUser`, which is how
the four `egress-filter` scenarios get root without `sudo`. Add `--skip-scenarios` for a faster
edit-run loop; CI does not, because a scenario is where every non-default option is covered.

## The constraints everything here is shaped by

A feature's `mounts` are static metadata. The CLI substitutes them for `${localEnv:*}`,
`${localWorkspaceFolderBasename}` and `${devcontainerId}`, but **not** for the feature's own options,
and **not** for `${containerEnv:HOME}` — that one passes to `docker run` verbatim and fails the
container. Two things follow.

**Nothing can be mounted at the remote user's home directory**, because a feature cannot know the
username: projects use `node`, `vscode`, `devc` and per-project names. Each feature uses a fixed path
instead, then reaches it from the home directory by a mechanism that _is_ username-aware, because
`install.sh` runs with `_REMOTE_USER` and `_REMOTE_USER_HOME` set.

| Feature           | Fixed path                               | How `$HOME` reaches it                                      |
| ----------------- | ---------------------------------------- | ----------------------------------------------------------- |
| `git-config`      | `/mnt/git-config`                        | files copied into `$HOME` at postCreate                     |
| `egress-filter`   | `/mnt/egress-filter`                     | read at container start; nothing is copied into `$HOME`     |
| `persist-homedir` | `/home` (the parent, not the user's dir) | nothing needed — mounting the parent sidesteps the username |

**A feature's mount cannot be read-only.** The `mounts` metadata is an object with `source`, `target`
and `type`, and it has no field for the flag. Every way around it depends on how the container is
built: the `docker run` path renders a mount as `--mount type=<type>,src=<source>,dst=<target>`, so
an option on the end of a mount string reaches docker, while a compose project renders each mount as
`<source>:<target>` into an override file and drops it. No single mount value is read-only in both
modes. So from version 2 on, `git-config` and `egress-filter` declare no mounts at all. They read
the fixed path above, and you declare the mount that fills it — see [Host setup](#host-setup).
`persist-homedir` is unaffected, because its volume is meant to be writable.

**A mount cannot depend on an option.** Options cannot add or remove a mount, so every path a feature
does mount must exist on every machine that uses it — which is why `persist-homedir` names a volume
rather than offering a configurable list of paths.

`containerEnv` is more limited still. The CLI emits it as a Dockerfile `ENV`, where it does not
substitute `${localEnv:HOME}` at all — Docker rejects it as an unsupported modifier — so a feature
cannot learn the host's home path that way. That is what stops `tidewave` from setting
`TIDEWAVE_HOST_PATH` itself, and the reason its project has to pass one through with `remoteEnv`.

**A feature cannot open a port.** `forwardPorts`, `appPort` and `remoteEnv` are not in
[the feature schema](https://github.com/devcontainers/spec/blob/main/schemas/devContainerFeature.schema.json)
at all — the properties a feature gets are `containerEnv`, `mounts`, `entrypoint`, `init`,
`privileged`, `capAdd`, `securityOpt`, `customizations`, `installsAfter`/`dependsOn` and the five
lifecycle hooks. So `tidewave` can start a server but cannot publish it, and the project it is used
in has to say `appPort` itself.

**A lifecycle hook is a static string and gets no options.** Only `install.sh` ever sees an option
value, so the feature bakes anything the runtime needs into a generated file at build time —
`tidewave` writes its flags to `/usr/local/share/devcontainer/tidewave/config`, the way
`persist-homedir` generates its entrypoint with the username already substituted. It also means a
hook cannot be conditional: `autostart: false` cannot remove the `postStartCommand`, only make the
script it names exit early.

Beyond that, the ordering rules. `git-config` copies at `postCreateCommand`, because the host's files
arrive as mounts and mounts do not exist during the build — which also means it re-runs on every
create, and refreshes a persisted home volume when the host config changes. `persist-homedir` makes
its `~/.vscode-server` symlink at build time instead, so it is part of the image and cannot race the
VS Code server install.

`claude` installs at build time, running the native installer as the remote user (`su -l`) so the
result is the layout the CLI's own updater expects: `~/.local/share/claude/versions/<version>` with a
`~/.local/bin/claude` symlink. A home volume that already has content masks whatever the image put in
`$HOME`, so the resolved binary is also **hard-linked** to
`/usr/local/share/devcontainer/claude/claude` — one inode, two names, so the layer stores the ~300MB
binary once rather than twice — and `/usr/local/bin/claude` is a wrapper preferring
`$HOME/.local/bin/claude` with the system copy as fallback. Fresh volume, stale volume or no volume,
`claude` resolves and runs, and a self-update in the home directory wins rather than being shadowed by
a copy frozen at image-build time.
