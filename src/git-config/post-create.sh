#!/usr/bin/env bash
# Copies the host's git configuration into the container, as the remote user, once the mount is up,
# then does the same cleanup pass the VS Code Dev Containers extension does. Copies rather than
# links: the container gets a normal writable file it can adjust without writing back to the host.
#
# Git has two global config locations and they are not additive: if ~/.gitconfig exists, the XDG
# directory at ~/.config/git is ignored outright. So this feature mounts that directory and never
# ~/.gitconfig — requiring an empty ~/.gitconfig to exist on the host, the way a bind mount would,
# silently switches off the entire git configuration of an XDG setup.
#
# The mount is read-write: a feature's mount objects take source, target and type only, and there is
# no readonly among them. Nothing below writes to $SRC, and nothing below should ever start to — the
# source is the host's own git directory, and a stray write there lands on the host.
#
# The files are copied whole, sections and all. Nothing is stripped on the way in: a filter driver
# whose command is missing here is worth the hard failure it causes, because that failure is the
# thing that tells you to install the tool in the container.
set -euo pipefail

# The default is the mount; the override exists so the test suite can drive this with a synthetic
# source directory instead of the host's real one.
SRC="${GIT_CONFIG_SOURCE_DIR:-/mnt/git-config}"
MARKER="# Written by the git-config devcontainer feature. Edits here are overwritten on rebuild."

write_file() {
    local src="$1" dst="$2"

    [ -s "$src" ] || return 0

    # Anything without the marker belongs to someone else — a file edited inside the container, or
    # the copy VS Code makes when it connects. Refreshing our own is fine; clobbering theirs is not.
    if [ -e "$dst" ] && ! head -n1 "$dst" 2>/dev/null | grep -qF "$MARKER"; then
        echo "!!! git-config: $dst was not written by this feature; leaving it alone" >&2
        return 0
    fi

    mkdir -p "$(dirname "$dst")"
    { echo "$MARKER"; cat "$src"; } > "$dst"
    echo "==> git-config: $src -> $dst"
}

write_file "$SRC/config" "$HOME/.config/git/config"
write_file "$SRC/ignore" "$HOME/.config/git/ignore"

# The cleanup the VS Code extension runs after its own copy: keys naming a program the host has and
# the container does not are worse than useless, since git fails on them instead of falling back.
# http.sslBackend goes unconditionally — it names a TLS stack that is a property of the host build
# of git, not something to carry between machines.
for key in core.editor core.sshCommand gpg.program gpg.openpgp.program gpg.x509.program gpg.ssh.program; do
    value="$(git config --global --get "$key" 2>/dev/null || true)"
    executable="${value%% *}"
    [ -n "$executable" ] || continue
    if ! command -v "$executable" >/dev/null 2>&1; then
        git config --global --unset "$key" || true
        echo "==> git-config: unset $key = $value ($executable is not installed here)"
    fi
done
git config --global --unset http.sslBackend 2>/dev/null || true

echo "==> git-config: done"
