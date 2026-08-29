
# Git config (nshafer) (git-config)

Copies the host's git configuration and excludes file into the container, from git's XDG config directory, in every container - including the ones the CLI creates, which copy nothing.

## Example Usage

```json
"features": {
    "ghcr.io/nshafer/devcontainer-features/git-config:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|


## Host setup

This feature bind-mounts `~/.config/git` from the host, read-only. A bind mount whose source does
not exist stops the container from starting. Docker does not create it. So create the directory on
every machine that uses this feature:

```bash
mkdir -p ~/.config/git
```

Git has two global config locations, and they are not additive. **If `~/.gitconfig` exists,
`~/.config/git/config` is ignored.** This feature reads the XDG location only. So move a
`~/.gitconfig` into place:

```bash
mkdir -p ~/.config/git && mv ~/.gitconfig ~/.config/git/config
```

Do not create an empty `~/.gitconfig` to satisfy a mount. On an XDG setup that empty file turns off
the whole configuration. This is measured, not assumed.

## Notes

This feature has no options. On container create it copies these files, as the remote user:

| From (host)            | To (container)         |
| ---------------------- | ---------------------- |
| `~/.config/git/config` | `~/.config/git/config` |
| `~/.config/git/ignore` | `~/.config/git/ignore` |

One mount, `~/.config/git` maps to `/mnt/git-config`. So a global ignore file needs no
`core.excludesfile` at all: `~/.config/git/ignore` is where git looks by default. The feature copies
rather than links, so the container adjusts its own config and never writes back to the host.

That mount is read-only. The metadata has no field for it: a feature's `mounts` are objects with
`source`, `target` and `type` only, `type` takes `bind` or `volume`, and the schema does not accept
the string form that carries `readonly`. The CLI renders a mount as
`--mount type=<type>,src=<source>,dst=<target>`, so the flag rides on the end of the target —
`"target": "/mnt/git-config,readonly"` — and docker reads it as an option of its own. Discipline
backs the trick up, because it depends on how the CLI builds that argument. The feature only reads
`/mnt/git-config`. The container's own git writes to `$HOME/.config/git`. The tests assert both that
the mount is read-only and that it stays byte-identical after a run.

The files go in **whole**, every section, filters included. The feature leaves a filter driver whose
command is not installed to fail, because with `required = true` that failure is a hard one. A hard
failure is the thing that tells you to install the tool.

The feature removes afterward what the VS Code extension removes: any of `core.editor`,
`core.sshCommand`, `gpg.program`, `gpg.openpgp.program`, `gpg.x509.program` or `gpg.ssh.program`
whose executable is not installed here, plus `http.sslBackend` always, because it names a TLS stack
that belongs to the host's build of git. Those keys make git fail rather than fall back, and unlike
a filter there is nothing useful to learn from the failure.

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


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nshafer/devcontainer-features/blob/main/src/git-config/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
