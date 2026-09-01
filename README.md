# devcontainer-features

Personal [dev container features](https://containers.dev/implementors/features/). They hold my
Claude setup, git config files, persisted home directory, egress filter, sandbox and Tidewave
bridge, so I do not copy-paste them into every project's `devcontainer.json`.

Each feature has its own generated README with the full notes and options. This file covers the
features as a whole, the setup, and the one-time host setup. For a feature's own detail, follow its
link:

| Feature                                  | What it does                                                                                      |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------- |
| [`persist-homedir`](src/persist-homedir) | Keeps `/home` on a per-project named volume across rebuilds, minus the VS Code server/extensions. |
| [`git-config`](src/git-config)           | Copies the host's git config and excludes file into the container.                                |
| [`sandbox`](src/sandbox)                 | Seals the host sockets VS Code forwards in — SSH agent, GPG agent, X11, VS Code IPC.               |
| [`egress-filter`](src/egress-filter)     | Default-deny outbound networking with a hostname allowlist, enforced in-container.                 |
| [`claude`](src/claude)                   | Installs the Claude Code CLI at build time.                                                        |
| [`tidewave`](src/tidewave)               | Installs the Tidewave CLI and starts it on every container start.                                 |

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

    "ghcr.io/nshafer/devcontainer-features/claude:1": {},
    "ghcr.io/nshafer/devcontainer-features/git-config:1": {},
    "ghcr.io/nshafer/devcontainer-features/persist-homedir:1": {},
    "ghcr.io/nshafer/devcontainer-features/sandbox:1": {},
    "ghcr.io/nshafer/devcontainer-features/egress-filter:1": {},
  }
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

Add the override file to the repo's `.gitignore`, or to your global one:

```gitignore
*.local.json
```

`devc` warns on every run while that file is still committable. The generated `local/` directory
needs no entry, because `devc` writes a `.gitignore` of `*` inside it.

### Write the override file

`.devcontainer/devcontainer.local.json` holds only what you change. Comments and trailing commas
are allowed, as in any `devcontainer.json`:

```jsonc
{
  // A different user, because common-utils below creates it.
  "remoteUser": "devc",

  "features": {
    "ghcr.io/devcontainers/features/common-utils:2": { "username": "devc" },
    "ghcr.io/nshafer/devcontainer-features/sandbox:1": {},
    "ghcr.io/nshafer/devcontainer-features/claude:1": {},
    "ghcr.io/nshafer/devcontainer-features/git-config:1": {},
    "ghcr.io/nshafer/devcontainer-features/persist-homedir:1": {}
  },

  "customizations": {
    "vscode": { "extensions+": ["anthropic.claude-code"] }
  }
}
```

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
  "ghcr.io/nshafer/devcontainer-features/git-config:1": {},
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

Two things to know about that setting. The Dev Containers VS Code extension contributes it, so the
standalone `devcontainer` CLI ignores it — containers created with `devcontainer up` need the
features listed in the config. And a project that declares the same feature id itself wins, which is
how a project opts out or pins options.

## One-time host setup

Two features bind-mount paths from the host home directory, and **a bind mount whose source does not
exist stops the container from starting**. Docker does not create it; that is `-v` behaviour, not
`--mount`. So set up each feature you use, once per machine. The steps are split by feature, so you
run only the ones you need.

### git-config

`git-config` mounts `~/.config/git`, read-only. Create the directory:

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

### egress-filter

`egress-filter` mounts `~/.config/egress-filter`, read-only. Create the directory and the global
list:

```bash
mkdir -p ~/.config/egress-filter
touch ~/.config/egress-filter/allowlist.txt
```

The directory is the mount source, so only the directory has to exist. The file is the global
allowlist, and an empty one is fine.

### tidewave

`tidewave` mounts nothing, but a feature cannot open a port or read the host's home path. So set
`TIDEWAVE_HOST_PATH` on the host, and add `appPort` and `remoteEnv` to the project config. See [its
notes](src/tidewave).

### claude, persist-homedir, sandbox

These need no host filesystem setup. `sandbox` has recommended host *settings* that fully close the
forwarded channels — unforwarding the sockets and turning off the Wayland mount. See [its
notes](src/sandbox).

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
Docker, and it needs Docker to see *this* container's filesystem. The harness applies every feature's
mounts, and those name paths under the home directory of whoever runs the test.
Docker-outside-of-docker would resolve them against the host home directory instead. So the config
adds `docker-in-docker`, and `postCreateCommand` runs `make setup` to create the paths the mounts
expect — the same one-time setup as on a host, for the same reason. It carries one option:
`"moby": false`. The base image is on Debian trixie, which has no `moby-cli` package, and the
feature stops the build rather than falling back to Docker CE on its own.

**dockerd has to be told about the proxy.** `egress-filter` writes `HTTP_PROXY` to
`/etc/environment`, which dockerd never reads: it is started by the docker-in-docker entrypoint,
from the container environment. Without the three variables in `containerEnv`, the firewall rejects
every image pull the harness makes, and the failure reads as a registry timeout. Drop them if you
drop `egress-filter`. Hostnames are configured in two places — the presets on the feature, and
`.devcontainer/egress-allow.txt` for the rest. A container restart applies an edit to that file.

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
`presets`, `pinned-dns`, and `privileged`. `test/egress-filter/test.sh` keeps every check a non-root
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
image the feature can run on, and the host paths its mounts expect — and none of them are the
default. `QUICK=1` skips scenarios for an edit-run loop, `FILTER=<name>` narrows to one scenario, and
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
the interesting paths. The host paths from the one-time setup above have to exist, since the harness
applies each feature's mounts.

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

**A feature cannot mount anything at the remote user's home directory**, because it cannot know the
username: projects use `node`, `vscode`, `devc` and per-project names. Each feature mounts at a fixed
path instead, then reaches it from the home directory by a mechanism that _is_ username-aware,
because `install.sh` runs with `_REMOTE_USER` and `_REMOTE_USER_HOME` set.

| Feature           | Fixed mount point                        | How `$HOME` reaches it                                      |
| ----------------- | ---------------------------------------- | ----------------------------------------------------------- |
| `git-config`      | `/mnt/git-config`                        | files copied into `$HOME` at postCreate                     |
| `egress-filter`   | `/mnt/egress-filter`                     | read at container start; nothing is copied into `$HOME`     |
| `persist-homedir` | `/home` (the parent, not the user's dir) | nothing needed — mounting the parent sidesteps the username |

**A mount cannot depend on an option.** Options cannot add or remove a mount, so every path a feature
mounts must exist on every machine that uses it — which is why `git-config` mounts a small fixed set
of git paths and asks you to create them once, rather than offering a configurable list.

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
