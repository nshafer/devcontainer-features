# devcontainer-features

Personal [dev container features](https://containers.dev/implementors/features/), so the same
Claude setup, git config files, persisted home directory and Tidewave bridge don't have to be
copy-pasted into every project's `devcontainer.json`.

| Feature                                  | What it does                                                                                      |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------- |
| [`claude`](src/claude)                   | Installs the Claude Code CLI and copies the host's `~/.claude/settings.json` into the container.  |
| [`git-config`](src/git-config)           | Copies the host's git config and excludes file into the container.                                |
| [`persist-homedir`](src/persist-homedir) | Keeps `/home` on a per-project named volume across rebuilds, minus the VS Code server/extensions. |
| [`sandbox`](src/sandbox)                 | Seals the host sockets VS Code forwards in — SSH agent, GPG agent, X11, VS Code IPC.               |
| [`tidewave`](src/tidewave)               | Installs the Tidewave CLI and starts it on every container start.                                 |

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

`tidewave` is deliberately not in that list. It needs a published port, and a feature cannot
declare one — see its notes below — so it belongs in the projects that actually want it.

`sandbox` is not in it either, for the opposite reason: it works everywhere, but it is supposed to
break things. Signing commits, `git push` over SSH, `code .` from the container terminal and GUI
apps on your desktop all stop working inside any container that has it. That is the trade it
exists to make, and it belongs in the containers running an agent rather than in all of them.

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

| From (host)            | To (container)         |
| ---------------------- | ---------------------- |
| `~/.config/git/config` | `~/.config/git/config` |
| `~/.config/git/ignore` | `~/.config/git/ignore` |

One mount, `~/.config/git` → `/mnt/git-config`, so a global ignore file needs no `core.excludesfile`
at all: `~/.config/git/ignore` is where git looks by default. Copies rather than links, so the
container can adjust its own config without writing back to the host.

That mount is read-only, which the metadata has no field for: a feature's `mounts` are objects with
`source`, `target` and `type` only, `type` takes `bind` or `volume`, and the string form that would
carry `readonly` is not what the feature schema accepts. The CLI renders a mount as
`--mount type=<type>,src=<source>,dst=<target>`, so the flag rides along on the end of the target —
`"target": "/mnt/git-config,readonly"` — and docker parses it as an option of its own. Discipline
backs it up, since the trick depends on how the CLI builds that argument: the feature only ever
reads `/mnt/git-config`, the container's own git writes to `$HOME/.config/git`, and tests assert
both that the mount is read-only and that it is byte-identical after a run.

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

### sandbox

VS Code's Dev Containers extension forwards a set of host sockets into every container it starts,
and each one is a capability an agent running in there inherits. Measured from a live container,
not assumed — the extension writes the list into `REMOTE_CONTAINERS_SOCKETS` itself:

| Channel | Path | What it grants |
| --- | --- | --- |
| SSH agent | `/tmp/vscode-ssh-auth-<uuid>.sock` | signing with your host SSH keys |
| GPG agent | `~/.gnupg/S.gpg-agent` | signing with your host GPG keys |
| X11 | `/tmp/.X11-unix/X<n>` | your desktop: keystrokes, screenshots |
| GPG keyboxd | `~/.gnupg/S.keyboxd` | your keyring |
| git credentials | `$XDG_RUNTIME_DIR/vscode-git-<id>.sock` | your GitHub token, via `GIT_ASKPASS` |
| `code` CLI | `vscode-ipc-<uuid>.sock` | driving your editor |
| extension IPC | `vscode-remote-containers-ipc-<uuid>.sock` | the extension's own channel to the host |
| Wayland | `/tmp/vscode-wayland-<uuid>.sock` | your desktop — **a bind mount**, see below |

### What this actually buys you — read this first

**This is mitigation, not a boundary.** It makes the forwarded channels difficult to reach by
accident and awkward to reach on purpose. It does not make them unreachable, and nothing installed
*inside* the container can, because the hole is in how VS Code forwards them.

The reason is structural. VS Code's helper runs **as the remote user** and calls
`net.Server.listen()` on a socket inside the container; anything else running as that user may
`connect()` to it. The socket has to be allowed to exist, because a path the helper cannot write is
a container you cannot attach to — that is not a theory, it is what `1.0.0` did:

```
Container server: Error: listen EACCES: permission denied /tmp/.X11-unix/X0
    at async Promise.all (index 1)
```

So the socket appears, and this feature takes it. Between those two moments it is live and usable.
Measured against a socket forwarded exactly the way VS Code forwards one, with an attacker looping
on `connect()`:

| sealing driven by | usable connections before the seal | window |
| --- | --- | --- |
| the 1s poll alone | 15,299 | 993 ms |
| inotify (the default) | **7** | **5 ms** |

inotify is a ~2,000× reduction and it is why the feature installs `inotify-tools`. It is still not
zero, and **one connection is enough** to have your host's `ssh-agent` sign something. The window
reopens on every window you attach, not just the first.

What it *does* hold: once sealed, a UUID-named socket is closed for good — `/tmp` is sticky and a
root-owned file in it cannot be removed by the remote user at all. Recreating one gets you a socket
bound to your own process with nothing behind it, because the forwarding lives in the helper
process, not in the file. So opportunistic use, tools that stumble onto `SSH_AUTH_SOCK`, and an
agent that is not specifically racing the seal all fail.

**The only fixes that actually close it are outside this feature:**

- **Don't forward at all.** Unset `SSH_AUTH_SOCK` and `DISPLAY` in the environment VS Code is
  launched from, and set `"dev.containers.mountWaylandSocket": false`. Nothing is forwarded, so
  there is nothing to race.
- **Run the agent as a different Unix user** than the remote user. Forwarded sockets are
  `srwxrwxr-x`, and connecting to a Unix socket needs *write* permission, which `other` does not
  have — verified: a second user is refused even on a completely unsealed socket. No window, no
  race, nothing to seal.
- **Upstream.** Until the Dev Containers extension offers a way to decline forwarding per container
  — or forwards to something more restrictive than a world-reachable, same-uid socket — a feature
  installed inside the container is always acting after the fact.

Treat this as a seatbelt for a coding agent doing something careless, not armour against one that
has been told to go looking.

The feature closes them with three mechanisms, in descending order of how much they are worth.

**Sealing beats deleting.** The obvious move is to delete the sockets, but deleting frees the path
and VS Code puts a working one back — which is why approaches built on `find -delete` need a
background loop re-deleting every 30 seconds. This takes the socket instead, `chown root:root` plus
`chmod 000`, and that closes three doors at once:

| | after `rm` | after sealing |
| --- | --- | --- |
| agent connects | recreated, works | `EACCES` |
| agent deletes it | n/a | `EPERM` — `/tmp` is sticky and the file is root's |
| VS Code recreates it | yes | `EADDRINUSE` |

**Everything is sealed after the fact, never pre-empted.** The obvious refinement is to take the
directories these sockets live in — `/tmp/.X11-unix` and `~/.gnupg` root-owned and unwritable — so
the socket can never be created at all. That is a stronger boundary, it works, and it makes the
container impossible to open: VS Code's helper creates those sockets while attaching, fails, and
dies, leaving **"Configuring Dev Container" on screen forever** with no error and no timeout. So the
forwarding is allowed to succeed and the channel is taken a moment later. Blocking that starts a
second late beats blocking that never lets you open the editor. `1.0.0` had it the other way round;
`1.0.1` does not, and `test/sandbox/test.sh` now checks that the directories stay writable before it
checks anything else.

The cost is stated rather than hidden: with the directory writable, a tombstone inside it can be
unlinked by the user who owns that directory, so the fixed-name channels — X11 and GPG — are open
for at most one sweep interval rather than never. The UUID-named channels keep the stronger
guarantee, because `/tmp` is sticky and a root-owned file in it cannot be removed by the user at
all.

**If you ran `1.0.0`, it left damage that outlives the rebuild.** That version made
`/tmp/.X11-unix` and `~/.gnupg` root-owned, and `persist-homedir` keeps `/home` on a named volume —
so a sealed `~/.gnupg` survives every rebuild and keeps the container unattachable, with a new
symptom:

```
Container server: [Error: EACCES: permission denied, unlink '/home/<user>/.gnupg/S.gpg-agent']
```

`1.0.2` repairs it at container start: any directory it manages that is root-owned is handed back to
the remote user. Recreating the home volume works too, at the cost of everything else in it.

**The rest needs a daemon, not a bounded loop.** The remaining names carry a fresh UUID per window,
so every VS Code window you attach forwards a whole new set — hours after the first. A loop that
runs ten passes and stops has stopped covering you. The feature's `entrypoint` runs as root before
VS Code has attached and leaves a sweeper behind for the life of the container.

Some things worth knowing:

**Wayland cannot be blocked from inside, and must not be attempted.** It is not a socket VS Code
creates in the container — it is a bind mount of the host's `/run/user/<uid>/wayland-0`. It cannot be
removed (`EBUSY`) or unmounted (no `CAP_SYS_ADMIN`), and **permission changes on a bind mount are
written through to the source**, so sealing it would set mode `000` on the socket your own desktop
session is running on. Every mutation in the feature is gated on a `/proc/self/mountinfo` check for
exactly this reason, and `test/sandbox/wayland_bind_mount.sh` demonstrates the write-through
happening and then proves the guard stops it. The only real fix is host-side, in VS Code's user
settings:

```jsonc
"dev.containers.mountWaylandSocket": false
```

**Depth 3, not 2.** `XDG_RUNTIME_DIR` in a dev container is `/tmp/user/<uid>`, and the git
credential socket — the one that hands out your GitHub token — lives there. A sweep two levels deep
looks thorough and silently leaves it open.

**The manifest is reported on, never acted on.** `REMOTE_CONTAINERS_SOCKETS` is the authoritative
list of what was forwarded, so a channel these globs do not know about still gets surfaced. It is
checked by the unprivileged `postStart`/`postAttach` hooks rather than swept by root, for two
reasons: root cannot read another user's `/proc/<pid>/environ` without `CAP_SYS_PTRACE`, which
Docker does not grant — and a feature that granted it would hand the remote user the ability to
ptrace the very daemon doing the hardening. Nor should root `chmod 000` paths named by something the
remote user controls; that turns the feature into a denial-of-service primitive against
`/etc/passwd`. So a new channel gets you a warning, not silence, and not an exploit.

**The env scrub is the weakest layer and is not a control.** VS Code re-injects `SSH_AUTH_SOCK`,
`GIT_ASKPASS` and friends into everything it starts, and any program can read a path back out of
`/proc`. The sockets being unusable is the control. The scrub is wired in at `/etc/profile.d`,
`/etc/bash.bashrc`, `/etc/zsh/zshenv` and `BASH_ENV` — all in `/etc`, never in `$HOME`, because
`persist-homedir` puts `/home` on a volume that masks whatever the image wrote to `~/.bashrc`, so a
scrub installed there works exactly once and then quietly stops.

Check the result at any time — it exits non-zero if anything is still reachable:

```console
$ sandbox-report
sandbox: forwarded host channels in this container
  ssh agent        blocked
  gpg agent        blocked
  x11 display      blocked
  vscode ipc       blocked
  sweeper          running, every 1s
```

**`no-new-privileges` is not part of the feature**, though it pairs well with it. A feature's
`securityOpt` is static metadata and cannot be made conditional on an option, so shipping it would
force it on every container and break `sudo` everywhere. It is one line in `devcontainer.json` when
you want it — and note that `capDrop` has no equivalent at all, feature or otherwise:

```jsonc
"securityOpt": ["no-new-privileges"]
```

Finally, the feature is only as good as the container's user model: **it does nothing if
`remoteUser` is root**, since root can simply `chmod` any tombstone back. `install.sh` says so
loudly when it detects that.

### tidewave

Runs the [Tidewave](https://tidewave.ai) CLI inside the container so the Tidewave app on the host
can drive the project. Two halves: the binary is downloaded at **image build time** to
`/usr/local/bin/tidewave`, and a `postStartCommand` starts it on every container start.

```jsonc
"features": {
  "ghcr.io/nshafer/devcontainer-features/tidewave:1": {}
},
"appPort": ["127.0.0.1:9000:9000"],
"remoteEnv": { "TIDEWAVE_HOST_PATH": "${localEnv:TIDEWAVE_HOST_PATH}" }
```

Both of those lines are the project's job, because a feature cannot express either — see the
constraints section. The feature says so in the creation log when `TIDEWAVE_HOST_PATH` is missing;
without it the app hands the host's editor container paths it cannot open.

| Option              | Default  | |
| ------------------- | -------- | --- |
| `version`           | `latest` | Or an exact `X.Y.Z` matching a `tidewave_app` release tag. A tag that does not exist fails the build. |
| `port`              | `9000`   | |
| `allowRemoteAccess` | `true`   | |
| `autostart`         | `true`   | Off installs the binary and starts nothing. |

**The published port has to be the same number on both sides.** `9000:9000`, never `9411:9000`.
The CLI checks the `Origin` header and rejects one naming a port other than its own — measured, and
the reason upstream's containers guide says the app must be reachable "using the same host and port
inside and outside the container".

**`allowRemoteAccess` defaults on because nothing works without it.** Left off, the CLI binds
`127.0.0.1` only, and a published port cannot reach that: Docker forwards to the container's bridge
address, not to its loopback. (Upstream's own devcontainer snippet omits the flag; a container built
from it has a port nobody can connect to.) Binding `0.0.0.0` is less alarming than it reads — the
`Origin` check above still stands, so a request from anywhere but a `localhost` origin gets a 403,
and `appPort` binding `127.0.0.1` keeps the port off the machine's other interfaces.

**The libc build is detected, not chosen** — glibc unless the image is genuinely musl. The CLI
binary itself would not care: the musl asset is statically linked and runs fine on Debian. What
cares is the **Bun runtime the CLI downloads at first use** into `~/.cache/tidewave/downloads`. The
CLI picks which Bun to fetch from its own build triple, which it reports verbatim from
`POST /about` with no idea what the host libc actually is, so a musl CLI on Debian fetches
`bun-linux-x64-musl` and the image has no loader for it:

```
sh: 1: /home/node/.cache/tidewave/downloads/bun-linux-x64-musl-1-3-10: not found
```

Detection is `ldd --version` naming musl, or the `/lib/ld-musl-<arch>.so.1` loader existing for
images with no `ldd`; everything else gets gnu. Both branches are covered by tests — the default
suite asserts a gnu asset and a gnu target on `node`, and the `musl_image` scenario asserts a musl
one on `devcontainers/base:alpine`.

Switching an existing container between the two is self-healing, because the two Bun builds have
different filenames: the stale one is left in the cache and a correct one is downloaded beside it.
It is only wasted bytes, but it does survive a rebuild when `persist-homedir` is in play.

`postStart` rather than `postCreate` because the process dies with the container and has to come
back with it — and it runs on every start, so it first probes `POST /about` and leaves an instance
that is already answering alone. The CLI takes no project path and has no flag for one: it serves
its working directory, which for a lifecycle hook is the workspace folder. That is also why this is
not the feature's `entrypoint` — an entrypoint runs as root, from `/`, before the workspace matters.

Startup goes to `/tmp/tidewave.log`, stamped with the command and time because the CLI itself is
silent on a healthy run. Nothing in the start script exits non-zero: a bridge that failed to come up
is worth shouting about in the creation log, not worth failing the container over.

## Publishing

`.github/workflows/release.yaml` publishes on push to `main` when a feature's `version` in its
`devcontainer-feature.json` changes, and regenerates each `src/<feature>/README.md` from the
metadata. Bump the version in the same commit as the change.

The published packages start out **private**. After the first release, make each one public under
`github.com/users/nshafer/packages` — otherwise every machine pulling them needs to be logged in
to ghcr.io.

## Tests

```bash
make            # what is available
make sandbox    # one feature
make test       # all of them, as CI runs them
```

The `Makefile` exists because every run needs the same three things set correctly — the right CLI,
a base image the feature can actually be exercised on, and the host paths its mounts expect — and
none of them are the default. `QUICK=1` skips scenarios for an edit-run loop, `FILTER=<name>`
narrows to one scenario, `ARGS=` passes anything else through.

`make lint` runs shellcheck, `bash -n` and a JSON parse in a couple of seconds without starting a
container, and CI runs it as its own job. `src/` is linted with no exclusions — what ships is held
to the stricter standard, and the few deliberate patterns in there carry inline directives with a
reason next to each. The test scripts are linted with three checks off, all structural rather than
sloppiness: `SC2016` (the `bash -c '...$VAR...'` idiom, where deferring expansion to the inner
shell is the entire point), `SC1091` (the test lib only exists inside the container) and `SC2088`
(a literal `~` inside a check's description string, which is prose, not a path).

One trap it removes: on a machine with VS Code installed, the `devcontainer` on `PATH` is a wrapper
that appends `--workspace-folder`, which `features test` rejects outright. The Makefile calls the
npm CLI through `npx` instead. The underlying command is:

```bash
npx @devcontainers/cli features test -f claude -i node -u node .
```

`-i`/`-u` are not optional in spirit: `claude`, `git-config` and `persist-homedir` key off the
remote user's home directory, and the harness's default (`ubuntu:focal`, running as root) exercises
none of the interesting paths. The host paths from the one-time setup above have to exist, since
the harness applies each feature's mounts.

`sandbox` is the exception to `-i node`: its tests have to become root to check what the *remote
user* can no longer reach, and the plain `node` image has no `sudo`. CI gives it a devcontainers
base for that reason, and so should you:

```bash
npx @devcontainers/cli features test -f sandbox \
    -i mcr.microsoft.com/devcontainers/javascript-node:20 -u node .
```

Those two flags apply to the autogenerated test only. Each feature's `test/<feature>/scenarios.json`
names its own image, which is how `tidewave` gets tested on Alpine at all — and how `sandbox` gets a
container with `CAP_SYS_ADMIN`, the only way to build a real bind mount and prove the guard that
keeps it from writing through to the host. Add `--skip-scenarios`
for a faster edit-run loop; CI does not, because a scenario is where every non-default option is
covered.

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
the host's home path that way. That is what stops `tidewave` from setting `TIDEWAVE_HOST_PATH`
itself, and the reason its project has to pass one through with `remoteEnv`.

**A feature cannot open a port.** `forwardPorts`, `appPort` and `remoteEnv` are not in
[the feature schema](https://github.com/devcontainers/spec/blob/main/schemas/devContainerFeature.schema.json)
at all — the properties a feature gets are `containerEnv`, `mounts`, `entrypoint`, `init`,
`privileged`, `capAdd`, `securityOpt`, `customizations`, `installsAfter`/`dependsOn` and the five
lifecycle hooks. So `tidewave` can start a server but cannot publish it, and the project it is used
in has to say `appPort` itself.

**A lifecycle hook is a static string and gets no options.** Only `install.sh` ever sees an option
value, so anything the runtime needs is baked into a generated file at build time — `tidewave`
writes its flags to `/usr/local/share/nshafer-tidewave/config`, the way `persist-homedir` generates
its entrypoint with the username already substituted. It also means a hook cannot be conditional:
`autostart: false` cannot remove the `postStartCommand`, only make the script it names exit early.

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
