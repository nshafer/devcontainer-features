
# Persistent home directory (nshafer) (persist-homedir)

Keeps /home and the VS Code server on separate named volumes, so both survive a rebuild but the server volume can be pruned on its own.

## Example Usage

```json
"features": {
    "ghcr.io/nshafer/devcontainer-features/persist-homedir:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|


## Host setup

None. This feature uses named volumes, and the container runtime creates those on first use. You
create no path before the first build.

## Notes

This feature keeps `/home` on one named volume and the VS Code server on a second named volume, so
shell history, caches, tool installs, and the server all survive a rebuild.

The server gets its own volume, separate from `/home`, for two reasons. First, the server tree is
large (about 1GB) and grows with every VS Code update, so keeping it off the homedir volume caps
what a normal rebuild carries forward. Second, a separate named volume can be pruned on its own —
`docker volume rm <workspace-folder-name>-vscode-server` — when you want a clean server install,
without touching anything else in `/home`.

Two mounts do the work:

| Volume                                       | Mount point                 | Lifetime            |
| --------------------------------------------- | --------------------------- | -------------------- |
| `<workspace-folder-name>-persistent-homedir` | `/home`                     | survives a rebuild  |
| `<workspace-folder-name>-vscode-server`      | `/var/local/vscode-server`  | survives a rebuild, prune by hand |

VS Code always installs its server to `$HOME/.vscode-server`, with no way to redirect it. So the
feature makes `$HOME/.vscode-server` a symlink into the second volume. It makes the symlink at
build time, so the symlink is part of the image. This is why the redirect never races the VS Code
server install.

Both volumes are named `<workspace-folder-name>-<suffix>`, one pair per project. Two projects whose
folders have the same basename share the same pair of volumes.

The remote user's home must be under `/home` for the volume to cover it. `install.sh` warns when it
is not, and carries on. The `~/.vscode-server` redirect still works either way.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nshafer/devcontainer-features/blob/main/src/persist-homedir/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
