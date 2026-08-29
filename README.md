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
| [`claude`](src/claude)                   | Installs the Claude Code CLI and seeds `~/.claude/settings.json` at build time.                   |
| [`tidewave`](src/tidewave)               | Installs the Tidewave CLI and starts it on every container start.                                 |

## Use per-project

Name the features in the project's own `.devcontainer/devcontainer.json`. This form works
everywhere. The standalone `devcontainer` CLI reads the config and nothing else, so a container that
`devcontainer up` creates — on your machine or in CI — gets none of the VS Code defaults below.

```jsonc
{
  "name": "my-project",
  "build": { "dockerfile": "Dockerfile" },
  "remoteUser": "devc",
  "features": {
    // Optional. Every feature here declares installsAfter common-utils, so if you use it, it runs
    // first and they see the user it created. Give it the same username the container runs as.
    "ghcr.io/devcontainers/features/common-utils:2": { "username": "devc" },

    "ghcr.io/nshafer/devcontainer-features/claude:1": {},
    "ghcr.io/nshafer/devcontainer-features/git-config:1": {},
    "ghcr.io/nshafer/devcontainer-features/persist-homedir:1": {},
    "ghcr.io/nshafer/devcontainer-features/sandbox:1": {}
  }
}
```

`{}` takes every default, and the defaults are the configuration I want. Spelled out, they are:

```jsonc
"features": {
  "ghcr.io/nshafer/devcontainer-features/claude:1": {
    "version": "stable",          // or "latest", or an exact X.Y.Z
    "settings": ""                // "{'includeCoAuthoredBy': false}" — single quotes, see the claude notes
  },

  // No options at all.
  "ghcr.io/nshafer/devcontainer-features/git-config:1": {},
  "ghcr.io/nshafer/devcontainer-features/persist-homedir:1": {},

  "ghcr.io/nshafer/devcontainer-features/sandbox:1": {
    "blockSshAgent": true,
    "blockGpgAgent": true,
    "blockX11": true,
    "blockVscodeIpc": true,
    "dropSudo": true,             // turning this off makes the rest decorative
    "scrubEnv": true,
    "sweepInterval": "1"          // seconds; only the backstop, sealing is inotify-driven
  },

  // Needs sandbox and its dropSudo, and adds the NET_ADMIN capability. See the egress-filter notes.
  "ghcr.io/nshafer/devcontainer-features/egress-filter:1": {
    "presets": "",                // e.g. "debian,npm,go,github,claude"
    "allow": "",
    "deny": "",
    "baseline": true,             // hosts VS Code needs to attach and install extensions
    "allowDns": true,             // a side channel; false closes it, and breaks self-resolving tools
    "proxyPort": "3128"
  },

  "ghcr.io/nshafer/devcontainer-features/tidewave:1": {
    "version": "latest",          // or an exact X.Y.Z matching a tidewave_app release tag
    "port": "9000",
    "allowRemoteAccess": true,    // nothing reaches the CLI without it
    "autostart": true
  }
},

// tidewave only, and not optional: a feature cannot open a port or read the host's home path.
"appPort": ["127.0.0.1:9000:9000"],
"remoteEnv": { "TIDEWAVE_HOST_PATH": "${localEnv:TIDEWAVE_HOST_PATH}" }
```

Do two things before the first build. First, run the [one-time host setup](#one-time-host-setup).
`git-config` and `egress-filter` bind-mount host paths, and a missing source stops the container from
starting. Second, decide about `sandbox` on purpose. It is the one feature here that takes things
away, `sudo` included, and everything in [its notes](src/sandbox) applies to everyone who builds this
config.

`:1` is a major-version tag, and the build resolves it to the newest `1.x`. `devcontainer up` writes
the digest it resolved into a `devcontainer-lock.json` beside the config. Commit that file to hold
every machine to the same feature build, and run `devcontainer upgrade` to move it forward.

## Use with local overrides

A committed `devcontainer.json` describes the project, and your agent setup is not the project.
Nobody else on the repo asked to have their `sudo` removed. The VS Code user setting below solves
that for containers VS Code starts, but the CLI ignores it, so a `devcontainer up` container gets a
bare project again. The fix is two configs: the committed one, and a gitignored copy beside it that
adds these features.

```
.devcontainer/
├── devcontainer.json          # committed — the project, no personal features
├── devcontainer-lock.json     # committed
├── Dockerfile                 # committed, shared by both configs
└── local/                     # gitignored
    ├── devcontainer.json      # yours — the same thing plus these features
    └── devcontainer-lock.json
```

The repo's `.gitignore`:

```gitignore
# Per-developer local files.
local/
*.local
*.local.*
```

`local/devcontainer.json` is the committed config with the features added:

```jsonc
{
  "name": "my-project",
  "build": {
    "dockerfile": "../Dockerfile",
    "context": ".."
  },
  "remoteUser": "devc",
  "features": {
    "ghcr.io/devcontainers/features/common-utils:2": { "username": "devc" },
    "ghcr.io/nshafer/devcontainer-features/sandbox:1": {},
    "ghcr.io/nshafer/devcontainer-features/claude:1": {},
    "ghcr.io/nshafer/devcontainer-features/git-config:1": {},
    "ghcr.io/nshafer/devcontainer-features/persist-homedir:1": {}
  },
  "postCreateCommand": "go mod download"
}
```

**Two paths have to climb a directory.** Paths in a `devcontainer.json` are relative to that file,
not to `.devcontainer/`, so a config one level deeper needs `"dockerfile": "../Dockerfile"` — and an
explicit `"context": ".."`, because the build context defaults to the directory that holds the
config. Leave the context out and the build runs inside `local/`, where the Dockerfile can `COPY`
nothing from the repo.

**It is a copy, not an overlay.** The spec has no inheritance between configs. The CLI reads exactly
one, so you copy across by hand whatever the committed config gains later. That is the cost of the
arrangement, and the reason to keep the difference in the `features` block.

The lock file follows the config it belongs to, so `local/devcontainer-lock.json` is gitignored with
the rest, and pinning your feature digests never shows in the project's diff.

### Pointing things at it

Nothing discovers that file on its own. Every command needs `--config`:

```bash
devcontainer open --config .devcontainer/local/devcontainer.json
devcontainer up   --config .devcontainer/local/devcontainer.json
devcontainer exec --config .devcontainer/local/devcontainer.json bash
```

`--workspace-folder` defaults to the current directory, so run them from the repo root and there is
nothing else to pass. (`devcontainer open` belongs to the CLI the Dev Containers extension installs
with the "Dev Containers: Install devcontainer CLI" command and puts on `PATH`, not to the npm
`@devcontainers/cli`.) VS Code finds the file too — it looks one level down for
`.devcontainer/*/devcontainer.json` and offers a picker when there is more than one — but
`open --config` names the one you want without the prompt.

That is enough repetition to be worth aliasing. From `~/.bash_aliases`:

```bash
alias devc="devcontainer"
alias dco="devcontainer open"
alias dcol="devcontainer open --config .devcontainer/local/devcontainer.json"
alias dcu="devcontainer up"
alias dcul="devcontainer up --config .devcontainer/local/devcontainer.json"
alias dce="devcontainer exec"
alias dcel="devcontainer exec --config .devcontainer/local/devcontainer.json"
alias dcb="devcontainer exec bash"
alias dcbl="devcontainer exec --config .devcontainer/local/devcontainer.json bash"
```

The trailing `l` is "local", and the pairs are the point. `dcu`/`dcul` build the project as everyone
else gets it or as you want it, `dcb`/`dcbl` open a shell in either, `dco`/`dcol` open one in VS
Code. Being one letter apart keeps the local config from being the one you forget.

## Use them everywhere

Add them once to the VS Code user `settings.json`, and every dev container gets them, without the
project's `devcontainer.json` naming them:

```jsonc
"dev.containers.defaultFeatures": {
  "ghcr.io/nshafer/devcontainer-features/claude:1": {},
  "ghcr.io/nshafer/devcontainer-features/git-config:1": {},
  "ghcr.io/nshafer/devcontainer-features/persist-homedir:1": {}
}
```

`tidewave` is deliberately not in that list. It needs a published port, and a feature cannot declare
one — see [its notes](src/tidewave) — so it belongs in the projects that actually want it.

`egress-filter` is not in it either. It adds the `NET_ADMIN` capability and needs `sandbox`'s
`dropSudo`, so it belongs in the containers that run an agent.

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
keeps it from writing through to the host. Add `--skip-scenarios` for a faster edit-run loop; CI does
not, because a scenario is where every non-default option is covered.

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
