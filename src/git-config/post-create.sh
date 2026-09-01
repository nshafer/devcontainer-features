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
# The mount is read-only, which a feature's mount metadata cannot say on its own: its schema takes
# source, target and type only, and type is limited to "bind" or "volume". The CLI renders a mount
# as `--mount type=<type>,src=<source>,dst=<target>`, so the flag rides along on the end of the
# target ("/mnt/git-config,readonly") and docker parses it as its own option. Nothing below writes
# to $SRC anyway, and nothing below should ever start to — the source is the host's own git
# directory, and a stray write there would land on the host.
#
# The files are copied whole, sections and all. A filter driver whose command is missing here is
# worth the hard failure it causes, because that failure is the thing that tells you to install the
# tool in the container. The one exception is credential.*, which never travels — see
# strip_credentials below.
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

# credential.* never travels. A helper names a program of the host (gh, osxkeychain, manager) that
# this container does not have, and git errors on each credential request. Worse, the VS Code
# extension writes its own helper into the host's global config -- a path to
# /tmp/vscode-remote-containers-<uuid>.js from a session that is over. Copied forward, that helper
# is dead on arrival. The extension installs a live helper of its own in /etc/gitconfig on every
# connect (dev.containers.gitCredentialHelperConfigLocation, "system" by default), so the copy is
# not what makes credentials work in a VS Code container. A container from the CLI gets no helper
# at all now, which is the honest result: authenticate with `gh auth login` or use an SSH remote.
strip_credentials() {
    local dst="$1" sections section
    [ -e "$dst" ] || return 0

    # Same rule as write_file: a file without the marker belongs to someone else. Leave it alone.
    head -n1 "$dst" 2>/dev/null | grep -qF "$MARKER" || return 0

    # Sections, not keys, so no empty header is left behind. A listed name minus its last component
    # is the section to remove: credential.https://github.com.helper -> credential.https://github.com,
    # credential.helper -> credential. Collect the list before the loop rewrites the file.
    sections="$(git config --file "$dst" --name-only --list 2>/dev/null \
        | sed -n 's/^\(credential\..*\)\.[^.]*$/\1/p; s/^credential\.[^.]*$/credential/p' \
        | sort -u || true)"

    while IFS= read -r section; do
        [ -n "$section" ] || continue
        git config --file "$dst" --remove-section "$section" || true
        echo "==> git-config: dropped [$section] (credential config does not travel)"
    done <<< "$sections"
}

write_file "$SRC/config" "$HOME/.config/git/config"
strip_credentials "$HOME/.config/git/config"
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
