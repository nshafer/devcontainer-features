# devcontainer-features

Personal [dev container features](https://containers.dev/implementors/features/), so the same
Claude setup, git config files and persisted home directory don't have to be copy-pasted into
every project's `devcontainer.json`.

| Feature                                  | What it does                                                                                      |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------- |
| [`claude`](src/claude)                   | Installs the Claude Code CLI and copies the host's `~/.claude/settings.json` into the container.  |
| [`git-config`](src/git-config)           | Copies the host's git config and excludes file into the container.                                |
| [`persist-homedir`](src/persist-homedir) | Keeps `/home` on a per-project named volume across rebuilds, minus the VS Code server/extensions. |

## Use them everywhere

Add them once to VS Code's user `settings.json` and every dev container gets them, without the
project's `devcontainer.json` mentioning them:

```jsonc
"dev.containers.defaultFeatures": {
  "ghcr.io/nshafer/devcontainer-features/claude:1": {},
  "ghcr.io/nshafer/devcontainer-features/git-config:1": {},
  "ghcr.io/nshafer/devcontainer-features/persist-homedir:1": {}
}
```

Two things to know about that setting: it is contributed by the Dev Containers VS Code extension, so the
standalone `devcontainer` CLI ignores it — containers created with `devcontainer up` need the
features listed in the config — and a project that declares the same feature id itself wins, which
is how a project opts out or pins options.

## One-time host setup

`claude` and `git-config` bind-mount paths from the host home directory, and **a bind mount whose
source does not exist stops the container from starting**. Docker does not create it; that is `-v`
behaviour, not `--mount`. So on every machine that uses these features:

```bash
mkdir -p ~/.claude ~/.config/git
touch ~/.claude/settings.json
```

`claude` mounts that one file rather than the directory around it, so the file itself has to exist.
An empty one is fine — the feature copies nothing and says so.

Note what is _not_ in that list: `~/.gitconfig`. Git's two global config locations are not additive
— **if `~/.gitconfig` exists, `~/.config/git/config` is ignored entirely**, so creating an empty one
to satisfy a mount would silently switch off the whole configuration of an XDG setup. Measured, not
assumed. `git-config` therefore reads the XDG location only; if your global config lives in
`~/.gitconfig`, move it:

```bash
mkdir -p ~/.config/git && mv ~/.gitconfig ~/.config/git/config
```

## Per-feature notes

### claude

Installs at **image build time**, so the build needs network access and pulls ~300MB. The native
installer runs as the remote user, so the result is the layout the CLI's own updater expects, and
the resolved binary is also hard-linked to a system path with `/usr/local/bin/claude` as a wrapper
preferring the home copy — fresh volume, stale volume or no volume, `claude` resolves and runs.

Nothing from the host's `~/.claude` is mounted. Credentials, transcripts, file history and plans
stay on the host; each container authenticates for itself and holds nothing belonging to another
project.

`version` takes `stable` (default), `latest`, or an exact `X.Y.Z`. `settings` seeds
`~/.claude/settings.json` before the installer runs:

```jsonc
"ghcr.io/nshafer/devcontainer-features/claude:1": {
  "settings": "{'includeCoAuthoredBy': false, 'model': 'opus'}"
}
```

**Write that object with single quotes.** The devcontainer CLI emits option values into the
generated Dockerfile without escaping them, so a value containing double quotes arrives with the
quotes collapsed and the JSON destroyed; the feature translates `'` to `"` on the way in. The cost
is that a value containing an apostrophe cannot be expressed. An unparseable value fails the build
with the received text, rather than producing a container whose CLI errors on startup.

Seeding runs _before_ the installer on purpose: the installer writes `autoUpdatesChannel` into the
same file and merges rather than replaces, so both survive. It is also the last time the feature
touches the file — from first run the CLI owns it, writing theme, model and update channel back.
Expect the CLI to normalise what it finds: `'model': 'opus'` becomes `"opus[1m]"`.

A persisted home volume with existing content masks the image's copy, so a container whose volume
predates a settings change will not see it until that volume is recreated.

### git-config

No options. On container create it copies, as the remote user:

| From (host, read-only) | To (container, writable) |
| ---------------------- | ------------------------ |
| `~/.config/git/config` | `~/.config/git/config`   |
| `~/.config/git/ignore` | `~/.config/git/ignore`   |

One mount, `~/.config/git` → `/mnt/git-config`, so a global ignore file needs no `core.excludesfile`
at all: `~/.config/git/ignore` is where git looks by default. Copies rather than links, so the
container can adjust its own config without writing back to the host.

The files go in **whole** — every section, filters included. A filter driver whose command is not
installed in the container is left to fail, because with `required = true` that failure is a hard
one, and a hard failure is the thing that tells you to install the tool.

What does get removed afterwards is what the VS Code extension removes: any of `core.editor`,
`core.sshCommand`, `gpg.program`, `gpg.openpgp.program`, `gpg.x509.program` or `gpg.ssh.program`
whose executable is not installed here, plus `http.sslBackend` unconditionally, since it names a TLS
stack belonging to the host's build of git. Those keys make git fail rather than fall back, and
unlike a filter there is nothing useful to learn from the failure.

Files it wrote carry a marker comment on the first line. On the next create it refreshes those, and
leaves anything without the marker alone — so a config you edited inside the container, or one VS
Code copied in, is never clobbered.

This overlaps with VS Code's `dev.containers.copyGitConfig`, which copies both `~/.gitconfig` and
the XDG config and then runs the same cleanup. The difference is the CLI: `devContainersSpecCLI.js`
contains no reference to `.gitconfig` at all, so a container from `devcontainer up` or CI has no git
identity without this feature.

One thing VS Code does that this does not: it also copies the file named by
`gpg.ssh.allowedSignersFile`. That can live anywhere on the host, and a feature can only mount fixed
paths. Keep `core.excludesfile` in mind for the same reason — point it outside `~/.config/git` and
the container will not have the file.

### persist-homedir

The volume is named `<workspace-folder-name>-persistent-homedir` — one per project, though two
projects whose folders have the same basename will share one.

The remote user's home must be under `/home` for the volume to cover it. `install.sh` warns when it
is not, and carries on — the `~/.vscode-server` redirect still works either way.

## Publishing

`.github/workflows/release.yaml` publishes on push to `main` when a feature's `version` in its
`devcontainer-feature.json` changes, and regenerates each `src/<feature>/README.md` from the
metadata. Bump the version in the same commit as the change.

The published packages start out **private**. After the first release, make each one public under
`github.com/users/nshafer/packages` — otherwise every machine pulling them needs to be logged in
to ghcr.io.

## Tests

```bash
npx @devcontainers/cli features test -f claude -i node -u node --skip-scenarios .
```

`-i`/`-u` are not optional in spirit: all three features key off the remote user's home directory,
and the harness's default (`ubuntu:focal`, running as root) exercises none of the interesting paths.
The host paths from the one-time setup above have to exist, since the harness applies each
feature's mounts.

## The constraint everything here is shaped by

A feature's `mounts` are static metadata. They are substituted for `${localEnv:*}`,
`${localWorkspaceFolderBasename}` and `${devcontainerId}`, but **not** for the feature's own
options, and **not** for `${containerEnv:HOME}` — that one is passed to `docker run` verbatim and
fails the container. Two things follow.

**A feature cannot mount anything at the remote user's home directory**, because it cannot know the
username: projects can variously use `node`, `vscode`, `devc` and per-project names. Each feature
mounts at a fixed path instead, then reaches it from the home directory by a mechanism that _is_
username-aware, because `install.sh` runs with `_REMOTE_USER` and `_REMOTE_USER_HOME` set.

| Feature           | Fixed mount point                        | How `$HOME` reaches it                                      |
| ----------------- | ---------------------------------------- | ----------------------------------------------------------- |
| `git-config`      | `/mnt/git-config`                        | files copied into `$HOME` at postCreate                     |
| `persist-homedir` | `/home` (the parent, not the user's dir) | nothing needed — mounting the parent sidesteps the username |

**A mount cannot be conditional on an option.** Options cannot add or remove a mount, so every path
a feature mounts must exist on every machine that uses it — which is why `git-config` mounts a small
fixed set of git paths and asks you to create them once, rather than offering a configurable list.

`containerEnv` is more limited still: it is emitted as a Dockerfile `ENV`, where `${localEnv:HOME}`
is not substituted at all — Docker rejects it as an unsupported modifier — so a feature cannot learn
the host's home path that way.

Beyond that, the ordering rules. `git-config` copies at `postCreateCommand`, because the host's
files arrive as mounts and mounts do not exist during the build — which also means it re-runs on
every create, refreshing a persisted home volume when the host config changes. `persist-homedir` makes its `~/.vscode-server`
symlink at build time instead, so it is part of the image and cannot race the VS Code server
install.

`claude` installs at build time, running the native installer as the remote user (`su -l`) so the
result is the layout the CLI's own updater expects: `~/.local/share/claude/versions/<version>` with
a `~/.local/bin/claude` symlink. Because a home volume that already has content masks whatever the
image put in `$HOME`, the resolved binary is also **hard-linked** to
`/usr/local/share/nshafer-claude/claude` — one inode, two names, so the ~300MB binary is stored once
in the layer rather than twice — and `/usr/local/bin/claude` is a wrapper preferring
`$HOME/.local/bin/claude` with the system copy as fallback. Fresh volume, stale volume or no volume,
`claude` resolves and runs, and a self-update in the home directory is picked up rather than being
shadowed by a copy frozen at image-build time.
