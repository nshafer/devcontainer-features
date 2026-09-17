
# Git config (nshafer) (git-config)

Copies your git config and global ignore file from the host into the container when the container is created. Works in a container from the devcontainer CLI too, which copies nothing by itself.

## Example Usage

```json
"features": {
    "ghcr.io/nshafer/devcontainer-features/git-config:2": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|


## Install

### 1. Put your git config in `~/.config/git` on the host

Do this one time on each machine. Git can read its global config from two places:
`~/.gitconfig` and `~/.config/git/config`. This feature reads `~/.config/git` only.

```bash
mkdir -p ~/.config/git
```

If you have a `~/.gitconfig` file, move it:

```bash
mv ~/.gitconfig ~/.config/git/config
```

> **Note:** Git ignores `~/.config/git/config` when `~/.gitconfig` exists, even an empty one. Do
> not create an empty `~/.gitconfig`.

### 2. Add the feature and a mount to your project

The feature reads your git folder at `/mnt/git-config` in the container. You must add the mount
that puts it there. The feature does not add it for you.
[Why you add the mount](#why-you-add-the-mount) tells why.

For a single container, add this to `.devcontainer/devcontainer.json`:

```jsonc
"features": {
  "ghcr.io/nshafer/devcontainer-features/git-config:2": {}
},
"mounts": [
  "type=bind,src=${localEnv:HOME}/.config/git,dst=/mnt/git-config,readonly"
]
```

For a Docker Compose project, add the feature to `devcontainer.json`, and add the mount to your
service in `docker-compose.yml`:

```yaml
services:
  app:
    volumes:
      - ${HOME}/.config/git:/mnt/git-config:ro
```

> **Caution:** The container does not start if `~/.config/git` does not exist on the host. Do
> step 1 first.

### 3. Rebuild the container

The feature copies the files when the container is created. The creation log shows each file that
it copied. If the mount is missing, the log shows a warning and the container starts without your
git config.

## What it does

When the container is created, the feature copies these files as the remote user:

| From the host          | To the container       |
| ---------------------- | ---------------------- |
| `~/.config/git/config` | `~/.config/git/config` |
| `~/.config/git/ignore` | `~/.config/git/ignore` |

Git reads `~/.config/git/ignore` as the global ignore file by default. You do not need to set
`core.excludesfile`.

The feature copies the files. It does not link them. Changes in the container do not go back to
the host, and changes on the host reach the container at the next rebuild.

### What it removes from the copy

The feature copies your config as it is, with two exceptions.

**It removes all credential settings.** It deletes the `[credential]` section and every
`[credential "<url>"]` section. There are three reasons:

- A credential helper names a program on your host, such as `osxkeychain` or `manager`. The
  container does not have that program, so git shows an error for each request.
- The VS Code extension adds a helper to your host config that points to a temporary file of an old
  container. That helper does not work in a new container.
- A credential helper gives the container your host credentials. The [`sandbox`](../sandbox)
  feature blocks the same access.

**It removes settings that name a missing program.** It deletes `core.editor`, `core.sshCommand`,
`gpg.program`, `gpg.openpgp.program`, `gpg.x509.program` and `gpg.ssh.program` if the program is not
installed in the container. It always deletes `http.sslBackend`, because that setting depends on
how git was built on the host. VS Code does the same cleanup when it copies a git config.

Filter drivers, such as Git LFS, stay in the copy. If the filter program is not in the container,
git fails with an error. That error tells you to install the program.

### Files it does not overwrite

The feature adds a marker comment to the first line of each file that it writes. On the next
container create, it replaces only files that have that marker. It does not change a file that you
edited in the container without the marker, or a file that VS Code copied.

## How git credentials work in the container

The feature copies no credentials. What you get depends on how you start the container:

- **VS Code:** The Dev Containers extension adds its own credential helper to `/etc/gitconfig` each
  time it connects. `git push` over HTTPS uses your host login. The `sandbox` feature blocks this
  by default.
- **The `devcontainer` CLI or CI:** There is no credential helper. Run `gh auth login` in the
  container, or use an SSH remote.

## Why use this when VS Code already copies git config

VS Code copies your git config when it starts a container, if `dev.containers.copyGitConfig` is on.
The `devcontainer` CLI does not. A container from `devcontainer up`, or from CI, has no git name
and email without this feature.

## Why you add the mount

A feature can declare mounts, but it cannot make a mount read-only in every setup. In a Docker
Compose project, the CLI drops the `readonly` flag, and the container could write to your host git
folder. So the feature declares no mount. You add the mount in the place where `readonly` works.

## What it does not do

- It does not copy `~/.gitconfig`. Move that file to `~/.config/git/config`.
- It does not copy files outside `~/.config/git`. If `core.excludesfile` or
  `gpg.ssh.allowedSignersFile` names a file somewhere else, the container does not have that file.
- It does not update the copy while the container runs. Rebuild the container to copy again.
- It does not write to the host.

## Risks

- **The container can read everything in `~/.config/git`.** The mount gives the container the whole
  folder, not only the two files. Do not keep secrets in that folder.
- **Your git config is visible to every program in the container.** That includes your name,
  email, aliases and include paths.
- **A section that the feature removes loses its comments.** A comment above the section header
  stays.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nshafer/devcontainer-features/blob/main/src/git-config/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
