## Install

Add the feature to `.devcontainer/devcontainer.json`, then rebuild the container:

```jsonc
"features": {
  "ghcr.io/nshafer/devcontainer-features/persist-homedir:1": {}
}
```

You do not need to set up anything on the host. Docker creates the volumes the first time the
container starts.

The home directory of the remote user must be under `/home`. Most dev container images use
`/home/vscode` or `/home/node`, so this is usually true. If the home directory is somewhere else,
the build shows a warning and nothing in the home directory persists.

## What it does

A rebuild deletes the container. Every file outside your project folder goes with it: shell
history, tool logins, caches, and tools that you installed by hand. This feature keeps those files.

It puts two Docker named volumes on the container. A named volume is storage that Docker keeps on
your host. It stays when the container is deleted.

| Volume                                  | Mounted at                 | Holds                                    |
| --------------------------------------- | -------------------------- | ---------------------------------------- |
| `<folder-name>-persistent-homedir`      | `/home`                    | The home directory of every user.        |
| `<folder-name>-vscode-server`           | `/var/local/vscode-server` | The VS Code server and its extensions.   |

`<folder-name>` is the name of your project folder on the host. For `~/src/my-app`, the volumes are
`my-app-persistent-homedir` and `my-app-vscode-server`.

## How it works

**The volume goes on `/home`, not on your home directory.** A feature cannot know the name of the
remote user, so it cannot name `/home/vscode` in advance. When a named volume is empty, Docker
fills it with the files that the image has at that path. So the first start copies the home
directory from the image into the volume. After that, the volume keeps its contents.

**The VS Code server has its own volume.** VS Code always installs its server in
`~/.vscode-server`. At build time, the feature replaces that folder with a link to
`/var/local/vscode-server`. The link is part of the image, so it exists before VS Code starts. The
server is about 1 GB, and it grows with each VS Code update. On its own volume, you can delete it
without a change to your home directory.

**The feature fixes the owner of the server volume at each start.** Some Docker setups create a
volume that root owns. The feature runs a small script as root when the container starts. The
script gives `/var/local/vscode-server` to the remote user.

## Things to know

**Changes to the home directory in the image do not appear after a rebuild.** Docker copies the
image into a volume only when the volume is empty. For example, if you change the Dockerfile to
add a line to `~/.bashrc`, the volume keeps the old `~/.bashrc`. To get the new files, delete the
home volume. That also deletes everything in it.

**Two projects with the same folder name share volumes.** `~/work/api` and `~/personal/api` both use
`api-persistent-homedir`. Rename one folder if you do not want that.

**Delete a volume to start clean.** Docker does not delete a volume that a container uses, even a
stopped container. Close the VS Code window, then run these commands on the host:

```bash
docker ps -a                                    # find the container of the project
docker rm -f <container>                        # delete the container
docker volume ls | grep my-app                  # find the volumes
docker volume rm my-app-vscode-server           # reinstall the VS Code server on the next start
docker volume rm my-app-persistent-homedir      # delete everything in /home
```

Then open the project in VS Code again. It builds a new container.

## Risks

- Logins and tokens stay. A `gh auth login`, a Claude login, or an API key in a dotfile stays in
  the volume after a rebuild. It stays on your host until you delete the volume.
- Changes stay. If a program in the container changes a file in the home directory, such as
  `~/.bashrc`, a rebuild does not undo the change. Delete the volume to undo it.
- Two projects with the same folder name can read each other's home directory files.
