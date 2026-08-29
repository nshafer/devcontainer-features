## Host setup

None. This feature uses named volumes, and the container runtime creates those on first use. You
create no path before the first build.

## Notes

This feature keeps `/home` on a named volume, so shell history, caches and tool installs survive a
rebuild. It keeps the VS Code server out of that volume, so extensions reinstall fresh on each
create.

Two mounts do the work:

| Volume                                     | Mount point               | Lifetime                    |
| ------------------------------------------ | ------------------------- | --------------------------- |
| `<workspace-folder-name>-persistent-homedir` | `/home`                 | survives a rebuild          |
| anonymous                                  | `/var/local/vscode-server` | new on every create        |

VS Code always installs its server to `$HOME/.vscode-server`, with no way to redirect it. So the
feature makes `$HOME/.vscode-server` a symlink into the anonymous volume. It makes the symlink at
build time, so the symlink is part of the image. This is why the redirect never races the VS Code
server install.

The volume is named `<workspace-folder-name>-persistent-homedir`, one per project. Two projects
whose folders have the same basename share one volume.

The remote user's home must be under `/home` for the volume to cover it. `install.sh` warns when it
is not, and carries on. The `~/.vscode-server` redirect still works either way.
