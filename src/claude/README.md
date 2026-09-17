
# Claude Code (nshafer) (claude)

Installs the Claude Code CLI when the image builds.

## Example Usage

```json
"features": {
    "ghcr.io/nshafer/devcontainer-features/claude:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| version | The version to install: 'stable', 'latest', or an exact X.Y.Z. | string | stable |

## Customizations

### VS Code Extensions

- `anthropic.claude-code`

## Install

Add the feature to `.devcontainer/devcontainer.json`, then rebuild the container:

```jsonc
"features": {
  "ghcr.io/nshafer/devcontainer-features/claude:1": {}
}
```

You do not need to set up anything on the host. The feature does not read any host files.

The build needs network access. The Claude Code download is a few hundred megabytes.

The first time you run `claude` in a new container, sign in. If you also use `persist-homedir`, the
login stays after a rebuild.

## What it does

When the image builds, the feature does these steps:

1. It installs `curl` if the image does not have it (with `apt-get` or `apk`).
2. It runs the official native installer from `https://claude.ai/install.sh` as the remote user.
   The installer puts Claude Code in `~/.local/share/claude/versions/<version>`, with a link at
   `~/.local/bin/claude`.
3. It makes a second copy of the program at `/usr/local/share/devcontainer/claude/claude`. The copy
   is a hard link, so the image does not store the file twice.
4. It writes a small script at `/usr/local/bin/claude`. The script runs `~/.local/bin/claude` if it
   exists. If it does not exist, the script runs the second copy.
5. It adds the `anthropic.claude-code` VS Code extension to the container.

On Alpine images, the feature also installs `libgcc`, `libstdc++` and `ripgrep`. The Alpine path
has no tests.

### Why there are two copies

A Docker volume on `/home`, such as the one from `persist-homedir`, hides the home directory that
the image contains. After the first build, the volume keeps its old contents, and the new
`~/.local/bin/claude` from the image is not visible. The script in `/usr/local/bin` makes sure that
the `claude` command always runs:

- With a new volume or no volume, it runs the copy in your home directory.
- With an old volume, it runs the copy in your home directory. That copy updates itself.
- If the home copy is missing, it runs the copy from the image.

## What it does not do

- It does not share anything from the host `~/.claude` folder. Your host login, settings, history
  and plans stay on the host. Each container has its own login.
- It does not configure Claude Code. Claude Code reads `.claude/settings.json` in your repository.
  Put personal settings in `.claude/settings.local.json`, and add that file to `.gitignore`.
- It does not limit what Claude Code can do. Claude Code can do anything that the remote user can
  do in the container.

## Risks

- Claude Code can read every file in the container, and run any command as the remote user. Use
  the [`sandbox`](../sandbox) and [`egress-filter`](../egress-filter) features to limit what it can
  reach outside the container.
- Your Claude login token is in the home directory of the container. With `persist-homedir`, it
  stays in a Docker volume on your host until you delete the volume.
- With `egress-filter`, add the `claude` preset. Without it, Claude Code cannot connect.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nshafer/devcontainer-features/blob/main/src/claude/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
