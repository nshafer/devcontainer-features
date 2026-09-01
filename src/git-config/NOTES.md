## Host setup

Two steps. Step 1 is once per machine, step 2 is once per project.

### 1. Create the directory on the host

```bash
mkdir -p ~/.config/git
```

Git has two global config locations, and they are not additive. **If `~/.gitconfig` exists,
`~/.config/git/config` is ignored.** This feature reads the XDG location only. So move a
`~/.gitconfig` into place:

```bash
mkdir -p ~/.config/git && mv ~/.gitconfig ~/.config/git/config
```

Do not create an empty `~/.gitconfig` to satisfy the mount. On an XDG setup that empty file turns
off the whole configuration. This is measured, not assumed.

### 2. Add the mount to your own config

This feature reads `/mnt/git-config` and does not mount anything there. You declare the mount, and
the form depends on how the container is built. [The mount is yours](#the-mount-is-yours) says why.

A single-container devcontainer, in `.devcontainer/devcontainer.json`:

```jsonc
"mounts": [
  "type=bind,src=${localEnv:HOME}/.config/git,dst=/mnt/git-config,readonly"
]
```

A compose project, in the service in your `docker-compose.yml`:

```yaml
services:
  app:
    volumes:
      - ${HOME}/.config/git:/mnt/git-config:ro
```

**Put it in the compose file there, not in `devcontainer.json`.** The CLI renders a
`devcontainer.json` mount into its compose override file as `<source>:<target>`, which has no place
for `readonly`, so that mount comes up read-write.

**A bind mount whose source does not exist stops the container from starting.** Docker does not
create it, so do step 1 before step 2. With no mount at all the container starts as usual, and the
feature says on `postCreate` that it copied nothing, and names both forms above.

## Notes

This feature has no options. On container create it copies these files, as the remote user:

| From (host)            | To (container)         |
| ---------------------- | ---------------------- |
| `~/.config/git/config` | `~/.config/git/config` |
| `~/.config/git/ignore` | `~/.config/git/ignore` |

One path: your `~/.config/git` reaches the container at `/mnt/git-config`. So a global ignore file
needs no `core.excludesfile` at all: `~/.config/git/ignore` is where git looks by default. The
feature copies rather than links, so the container adjusts its own config and never writes back to
the host.

### The mount is yours

**This feature declares no mount of its own, and version 1 did.** A feature's mount metadata is an
object with `source`, `target` and `type`, and that object has no field for the read-only flag.
Every way around it depends on how the container is built.

The `docker run` path renders a mount as `--mount type=<type>,src=<source>,dst=<target>`, so an
option on the end of a mount string reaches docker and `readonly` holds. A compose project does not:
the CLI writes an override file and renders each mount with the short volume syntax,
`<source>:<target>`, which has no place for an option. No single mount value is read-only in both
modes.

So a feature-declared mount promises a read-only mount of your git directory and hands half its
users a writable one. Version 1 did worse than that. It carried the flag on the end of the target,
`"target": "/mnt/git-config,readonly"`, which docker reads as an option under `docker run` only:
under compose it mounted the host directory at a path literally named `git-config,readonly`,
read-write, and the feature then found nothing to copy.

The mount belongs to whoever knows which mode the container is in, and that is you. The feature
warns when it is not there and names both forms.

The feature only reads `/mnt/git-config`. The container's own git writes to `$HOME/.config/git`. The
`mounted` test scenario declares the mount the way you do, and asserts both that it is read-only and
that it stays byte-identical after a run.

The files go in **whole**, every section, filters included, with one exception below. The feature
leaves a filter driver whose command is not installed to fail, because with `required = true` that
failure is a hard one. A hard failure is the thing that tells you to install the tool.

### Credentials do not travel

The exception is `credential.*`. The feature removes `[credential]` and every
`[credential "<url>"]` subsection from the copy, for three reasons:

- A helper names a program of the host — `gh`, `osxkeychain`, `manager`. A container without that
  program gets an error on every credential request.
- The VS Code extension writes a helper of its own into the host's global config. That helper holds
  a `/tmp/vscode-remote-containers-<uuid>.js` path belonging to a container session that is over.
  Copied forward, it is dead on arrival.
- A helper is an authority, not a preference. It hands the container whatever the host credential
  store holds, and `sandbox` treats the same channel as a grant to control.

This costs a VS Code container nothing. The extension installs a live helper on every connect, and
`dev.containers.gitCredentialHelperConfigLocation` chooses where that line goes: `system`, the
default, means `/etc/gitconfig`, which the copy never touches. The other values are `global` — the
one that leaves the stale line in the host config — and `none`.

A container from `devcontainer up` or CI now has no credential helper at all. That is the honest
result of a config the host cannot reach into. Run `gh auth login` inside it, or use an SSH remote.

One side effect: `git config --remove-section` takes the comment lines inside a section with it. A
comment above the section header stays.

### Keys that name a missing program

The feature removes afterward what the VS Code extension removes: any of `core.editor`,
`core.sshCommand`, `gpg.program`, `gpg.openpgp.program`, `gpg.x509.program` or `gpg.ssh.program`
whose executable is not installed here, plus `http.sslBackend` always, because it names a TLS stack
that belongs to the host's build of git. Those keys make git fail rather than fall back, and unlike
a filter there is nothing useful to learn from the failure.

### Ownership, and the overlap with VS Code

Files the feature wrote carry a marker comment on the first line. On the next create it refreshes
those files, and it leaves anything without the marker alone. So it never overwrites a config you
edited inside the container, or one VS Code copied in.

This overlaps with VS Code's `dev.containers.copyGitConfig`, which copies both `~/.gitconfig` and
the XDG config and then runs the same cleanup. The difference is the CLI. `devContainersSpecCLI.js`
holds no reference to `.gitconfig` at all, so a container from `devcontainer up` or CI has no git
identity without this feature.

One thing VS Code does that this feature does not: it also copies the file named by
`gpg.ssh.allowedSignersFile`. That file can live anywhere on the host, and a feature can mount fixed
paths only. Keep `core.excludesfile` in mind for the same reason. Point it outside `~/.config/git`
and the container does not have the file.
