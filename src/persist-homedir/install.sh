#!/usr/bin/env bash
# Two mounts do the work, both declared in devcontainer-feature.json:
#
#   <workspace>-homedir  -> /home                    named volume, survives rebuilds
#   (anonymous volume)   -> /var/local/vscode-server  new every time the container is created
#
# /home rather than /home/<user> is deliberate. A feature's mount targets are static strings and
# cannot be told the remote user's name, and the username differs per project (node, vscode, ...).
# Mounting the parent sidesteps that: Docker seeds an empty named volume from the image, so the
# user's home is copied in on first use and preserved from then on.
#
# This script's job is the second mount: VS Code always installs its server to $HOME/.vscode-server
# with no way to redirect it, so $HOME/.vscode-server is made a symlink into the anonymous volume.
# That keeps a ~1GB server + extension tree off the persisted volume and gets it rebuilt with the
# container, which is the point of excluding it.
set -euo pipefail

SERVER_DIR=/var/local/vscode-server

USERNAME="${_REMOTE_USER:-root}"
USER_HOME="${_REMOTE_USER_HOME:-}"
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
    USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
fi
: "${USER_HOME:=/home/$USERNAME}"

echo "==> persist-homedir: user=$USERNAME home=$USER_HOME"

case "$USER_HOME" in
    /home/*) ;;
    *)
        echo "!!! persist-homedir: $USER_HOME is not under /home, so nothing will be persisted." >&2
        echo "!!! Set remoteUser to a user with a home under /home." >&2
        ;;
esac

USER_GROUP="$(id -gn "$USERNAME")"

install -d -o "$USERNAME" -g "$USER_GROUP" "$SERVER_DIR"

# Done at build time on purpose: the symlink is part of the image, so it is copied into the home
# volume when Docker seeds it, and a lifecycle hook can't race the server install.
if [ -d "$USER_HOME/.vscode-server" ] && [ ! -L "$USER_HOME/.vscode-server" ]; then
    rm -rf "$USER_HOME/.vscode-server"
fi
ln -sfn "$SERVER_DIR" "$USER_HOME/.vscode-server"
chown -h "$USERNAME:$USER_GROUP" "$USER_HOME/.vscode-server"

echo "==> persist-homedir: $USER_HOME/.vscode-server -> $SERVER_DIR"
