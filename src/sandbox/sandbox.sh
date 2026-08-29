#!/usr/bin/env bash
# The whole runtime of the feature: block the fixed paths, sweep the unpredictable ones, report.
# Runs as root -- everything here depends on being able to take a file away from the remote user,
# and none of it does anything useful otherwise.
#
# The mechanism is "tombstone", not "delete", and that difference is the point of this feature.
# Deleting a forwarded socket frees the path, and VS Code puts a working one back. Taking it
# instead closes all three doors at once:
#
#   chown root:root + chmod 000   the remote user cannot connect   (EACCES)
#                                 the remote user cannot remove it (EPERM -- /tmp is sticky and the
#                                                                   file now belongs to root)
#                                 nothing can bind the path again  (EADDRINUSE)
#
# So a tombstone is permanent where a delete is a suggestion. That is why the blog post this is
# drawn from needs a background loop re-deleting every 30s for five minutes, and this does not.
#
# What it does still need a daemon for is that the paths carry a fresh UUID per window: attaching a
# second VS Code window forwards an entirely new set, hours after the first. A loop that gives up
# after five minutes stops covering you; this one runs as long as the container does.
set -uo pipefail

CONFIG=/usr/local/share/devcontainer/sandbox/config
# The defaults matter: the test suite drives this script directly, without the generated config.
# USERNAME and USER_UID are read by nothing in here, but they are part of the config's contract --
# install.sh writes them and the tests assert on them -- so they are declared with the rest rather
# than leaving this block a partial picture of the file it mirrors.
BLOCK_SSH=true
BLOCK_GPG=true
BLOCK_X11=true
BLOCK_IPC=true
SWEEP_INTERVAL=1
DROP_SUDO=true
# shellcheck disable=SC2034
USERNAME=root
USER_HOME=/root
# shellcheck disable=SC2034
USER_UID=0
# Generated at build time, so there is nothing for the linter to follow here.
# shellcheck source=/dev/null
[ -r "$CONFIG" ] && . "$CONFIG"

# Overridable so the tests can point all of this at a scratch tree instead of the real /tmp.
ROOTS="${SANDBOX_ROOTS:-/tmp /run}"
X11_DIR="${SANDBOX_X11_DIR:-/tmp/.X11-unix}"
GNUPG_DIR="${SANDBOX_GNUPG_DIR:-$USER_HOME/.gnupg}"
# Overridable for the same reason, and it buys something the others do not: the bind-mount guard
# below can then be tested with a synthetic mount table, on any kernel, without the privileges a
# real `mount --bind` needs. Creating one requires CAP_SYS_ADMIN *and* an unconfined AppArmor
# profile, and CI runners have the second of those locked down -- so without this the single most
# safety-critical branch in this file would go untested exactly where it matters most.
MOUNTINFO="${SANDBOX_MOUNTINFO:-/proc/self/mountinfo}"

log() { echo "==> sandbox: $*"; }
warn() { echo "!!! sandbox: $*" >&2; }

# A forwarded Wayland socket is not a file VS Code created in here -- it is a bind mount of the
# host's /run/user/<uid>/wayland-0. It cannot be removed (EBUSY) and cannot be unmounted (no
# CAP_SYS_ADMIN in a stock container), and it must never be chmod'ed: permission changes on a bind
# mount are written through to the source, so a chmod here lands on the socket the host's own
# desktop session is using. Every mutation below is gated on this returning false.
is_mount() {
    awk -v p="$1" '$5 == p { found = 1 } END { exit !found }' "$MOUNTINFO" 2>/dev/null
}

# Returns 0 only if it actually sealed something, so callers can count.
tombstone() {
    local path="$1" what="${2:-socket}"

    [ -e "$path" ] || return 1

    if is_mount "$path"; then
        warn "$path is a bind mount from the host; leaving it alone."
        warn "  A forwarded Wayland socket can only be switched off host-side, in VS Code's"
        warn "  user settings: \"dev.containers.mountWaylandSocket\": false"
        return 1
    fi

    # Already ours from an earlier pass. Judged by owner and mode together, so that a tombstone
    # someone has chmod'ed back cannot be silently counted as still enforced.
    if [ "$(stat -c %u "$path" 2>/dev/null)" = "0" ] && [ "$(stat -c %a "$path" 2>/dev/null)" = "0" ]; then
        return 1
    fi

    chown root:root "$path" 2>/dev/null || { warn "could not take $path"; return 1; }
    chmod 000 "$path" 2>/dev/null || { warn "could not seal $path"; return 1; }
    log "sealed $what $path"
    return 0
}

# Everything else in this file rests on one assumption: that the remote user cannot become root.
# A stock dev container breaks that assumption on purpose -- common-utils grants passwordless sudo --
# and with it every tombstone here is one command from being undone:
#
#     sudo chmod 666 /tmp/vscode-ssh-auth-*.sock
#
# So the grant goes. This is the single change that turns the rest of the feature from theatre into
# something an agent has to work around rather than simply switch off.
#
# Re-asserted at every container start, not just at build time, because a later feature or a
# project's own postCreate can put the grant back.
sudo_works() {
    command -v sudo >/dev/null 2>&1 || return 1
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$USERNAME" -- sudo -n true >/dev/null 2>&1
    else
        su -s /bin/sh -c 'sudo -n true' "$USERNAME" >/dev/null 2>&1
    fi
}

drop_sudo() {
    [ "$DROP_SUDO" = true ] || return 0
    if [ "$USERNAME" = root ]; then
        warn "the remote user is root, so there is no sudo grant to drop and nothing here binds"
        return 0
    fi
    sudo_works || return 0

    # The grant common-utils writes is /etc/sudoers.d/<username>; drop any file that names the user.
    for f in /etc/sudoers.d/*; do
        [ -f "$f" ] || continue
        if grep -qE "^[[:space:]]*${USERNAME}[[:space:]]" "$f" 2>/dev/null; then
            rm -f "$f" && log "removed sudo grant $f"
        fi
    done

    # And the group-based route, which no per-user file mentions.
    for grp in sudo wheel admin; do
        if id -nG "$USERNAME" 2>/dev/null | tr ' ' '\n' | grep -qx "$grp"; then
            if deluser "$USERNAME" "$grp" >/dev/null 2>&1 || gpasswd -d "$USERNAME" "$grp" >/dev/null 2>&1; then
                log "removed $USERNAME from group $grp"
            fi
        fi
    done

    # Verified by outcome, not by the steps above: sudo is configurable in more ways than are worth
    # enumerating, and a grant this missed would silently hand back everything. If it still works,
    # take the setuid bit off the binary, which no amount of sudoers configuration can restore.
    if sudo_works; then
        local bin
        bin="$(command -v sudo 2>/dev/null)"
        warn "$USERNAME can still sudo after removing the grants; stripping setuid from $bin"
        chmod u-s "$bin" 2>/dev/null || true
    fi

    if sudo_works; then
        warn "$USERNAME CAN STILL BECOME ROOT. Every block in this feature is undoable."
    else
        log "dropped sudo for $USERNAME"
    fi
}

# Undo what version 1.0.0 of this feature did, because it does not go away on its own.
#
# 1.0.0 sealed /tmp/.X11-unix and ~/.gnupg by making the *directories* root-owned and mode 0555.
# That stops VS Code attaching (see block_fixed below), and 1.0.1 stopped doing it -- but stopping
# is not enough. persist-homedir puts /home on a named volume, so a ~/.gnupg that 1.0.0 sealed
# survives every rebuild, and the container it breaks stays broken no matter how new the feature
# is. The symptom is the helper failing where it must be able to write:
#
#   Container server: [Error: EACCES: permission denied, unlink '/home/<user>/.gnupg/S.gpg-agent']
#
# Only ever hands a directory back to the remote user, and only one this feature could have taken:
# root-owned, at a path this feature manages. A ~/.gnupg owned by root is never something the user
# set up deliberately.
repair_dir() {
    local dir="$1" mode="$2"

    [ -d "$dir" ] || return 0
    is_mount "$dir" && return 0
    [ "$USERNAME" != root ] || return 0
    [ "$(stat -c %u "$dir" 2>/dev/null)" = "0" ] || return 0

    chown "$USERNAME:" "$dir" 2>/dev/null || return 0
    chmod "$mode" "$dir" 2>/dev/null || return 0
    log "repaired $dir -- it was root-owned, which stops VS Code attaching (1.0.0 left it that way)"
}

# The sockets inside are left sealed on purpose: with the directory handed back, the remote user can
# unlink them, which is exactly what VS Code's helper does before it re-binds. The sweeper takes the
# new ones a moment later.
repair() {
    repair_dir "$X11_DIR" 0755
    repair_dir "$GNUPG_DIR" 0700
}

# The fixed-name channels: /tmp/.X11-unix/X<n> and ~/.gnupg/S.gpg-agent.
#
# An earlier version of this took the *directories* instead -- root-owned, mode 0555 -- so the
# socket could never be created in the first place. That is a stronger boundary and it cannot be
# used, because it breaks the container outright. VS Code's own helper creates these sockets while
# it is attaching, and a directory it cannot write makes that step fail:
#
#   Start: Run in container: mkdir -p '/tmp/.X11-unix'
#   X11 forwarding: DISPLAY in container (:0) forwarded to local host (:0).
#   ...
#   Port forwarding ... stderr: Remote close
#
# The helper dies, the connection closes, and VS Code sits on "Configuring Dev Container" forever.
# There is no timeout and no error shown to the user. So the socket has to be allowed to appear and
# then be taken, rather than being pre-empted: the forwarding gets set up, the channel is sealed a
# moment later, and the attach completes. Blocking that starts a second too late beats blocking
# that never lets you open the editor.
#
# The cost is honest: because the directory stays writable by the remote user, a tombstone in it
# can be unlinked -- the owner of a directory may remove anything inside it. The sweeper puts it
# straight back -- on the kernel's create event, so within about a millisecond rather than on the
# next poll -- so the channel is open briefly rather than never. The
# UUID-named channels below keep the stronger guarantee, because /tmp is sticky and root's file in
# it cannot be removed by the user at all.
block_fixed() {
    if [ "$BLOCK_X11" = true ]; then
        for sock in "$X11_DIR"/X*; do
            [ -e "$sock" ] && tombstone "$sock" "display socket"
        done
    fi

    if [ "$BLOCK_GPG" = true ]; then
        [ -e "$GNUPG_DIR/S.gpg-agent" ] && tombstone "$GNUPG_DIR/S.gpg-agent" "gpg agent socket"
        [ -e "$GNUPG_DIR/S.gpg-agent.extra" ] && tombstone "$GNUPG_DIR/S.gpg-agent.extra" "gpg agent socket"
        [ -e "$GNUPG_DIR/S.keyboxd" ] && tombstone "$GNUPG_DIR/S.keyboxd" "gpg keyboxd socket"
    fi

    return 0
}

# Every forwarded socket path whose name carries a UUID, and so cannot be pre-empted the way the
# directories above can -- these have to be found after the fact.
#
# maxdepth 3, not 2. XDG_RUNTIME_DIR in a dev container is /tmp/user/<uid>, and the git credential
# socket -- the one that hands out the host's GitHub token -- lives there, at depth 3. A sweep two
# levels deep looks thorough and silently leaves that one open.
sweep_globs() {
    local -a names=()
    [ "$BLOCK_SSH" = true ] && names+=(-o -name 'vscode-ssh-auth-*.sock')
    if [ "$BLOCK_IPC" = true ]; then
        names+=(-o -name 'vscode-ipc-*.sock')
        names+=(-o -name 'vscode-git-*.sock')
        names+=(-o -name 'vscode-remote-containers-ipc-*.sock')
    fi

    if [ ${#names[@]} -gt 0 ]; then
        # ${names[@]:1} drops the leading -o. ROOTS is a deliberate word-split list of directories.
        # shellcheck disable=SC2086
        find $ROOTS -maxdepth 3 -type s \( "${names[@]:1}" \) -print 2>/dev/null | while read -r sock; do
            tombstone "$sock"
        done
    fi

    # X sockets, for the case where the directory seal did not take: a host mount over it, or a
    # tmpfs mounted on /tmp after the image was built.
    if [ "$BLOCK_X11" = true ]; then
        for sock in "$X11_DIR"/X*; do
            [ -e "$sock" ] && tombstone "$sock" "display socket"
        done
    fi
}

sweep() {
    sweep_globs
    # The fixed-name sockets are re-created by every attach, so they are swept on every pass too,
    # not merely once at container start.
    block_fixed
}

# The globs above are guesses that happen to be right today. This is the authoritative list: the
# extension writes what it forwarded into the environment of the processes it starts, and
# REMOTE_CONTAINERS_SOCKETS is literally
#   ["/tmp/vscode-ssh-auth-<uuid>.sock","/tmp/.X11-unix/X2","/home/<user>/.gnupg/S.gpg-agent"]
#
# It is only ever *reported* on, never acted on, and that is deliberate on two counts.
#
# It cannot be read by the sweeper. Reading another user's /proc/<pid>/environ needs
# CAP_SYS_PTRACE, which is not in Docker's default capability set -- so root in a stock container
# gets EACCES on exactly the processes that hold this. The fix is not to add the capability: a
# feature that grants SYS_PTRACE to harden a container has handed the remote user the ability to
# ptrace the root daemon doing the hardening, which is worse than the gap it closes.
#
# And it must not be acted on. This runs unprivileged, so the paths come from somewhere the remote
# user controls; having root chmod 000 an arbitrary path on their say-so is a way to turn this
# feature into a denial-of-service primitive against /etc/passwd. Reporting costs nothing and
# gives up nothing: if a future VS Code forwards a channel these globs do not know, you are told,
# rather than it passing silently.
#
# Read from /proc/$$/environ rather than from the live environment, because scrub-env.sh has
# usually unset all of this by the time the script body runs (BASH_ENV reaches every
# non-interactive bash, this script included) -- the procfs copy keeps the values the process was
# exec'd with, and reading one's own needs no capability at all.
#
# $$ and not self: as a *redirection*, "< /proc/self/environ" is opened in a context whose notion
# of self is not this script, and it comes back without the variables. $$ is this script's pid in
# a subshell as well as out of it, which is what makes it correct inside the substitution below.
#
# The pid is an argument because the caller is usually the one holding the manifest, not this
# script. post-start.sh and post-attach.sh are bash scripts too, so BASH_ENV has scrubbed the
# variables out of their shells before they get to call this -- and having scrubbed them, they
# exec this without them. They pass their own $$ instead, whose procfs copy is still intact.
# Same user, so no capability is needed to read it.
check_manifest() {
    local pid="${1:-$$}" declared unsealed=0

    declared="$(
        tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
            | grep -E '^(SSH_AUTH_SOCK|REMOTE_CONTAINERS_IPC|REMOTE_CONTAINERS_DISPLAY_SOCK|REMOTE_CONTAINERS_SOCKETS|VSCODE_IPC_HOOK_CLI|VSCODE_GIT_IPC_HANDLE)=' \
            | sed 's/^[A-Z_]*=//' \
            | tr ',' '\n' | tr -d '[]"' \
            | grep '^/' | sort -u
    )"
    [ -n "$declared" ] || return 0

    while read -r path; do
        [ -n "$path" ] || continue
        [ -e "$path" ] || continue
        is_mount "$path" && continue
        if [ "$(stat -c %u "$path" 2>/dev/null)" = "0" ] && [ "$(stat -c %a "$path" 2>/dev/null)" = "0" ]; then
            continue
        fi
        warn "VS Code declared $path and it is still reachable."
        unsealed=$((unsealed + 1))
    done <<EOF
$declared
EOF

    if [ "$unsealed" -gt 0 ]; then
        warn "  $unsealed declared channel(s) are not covered. If the name is new, this feature's"
        warn "  globs need updating: $0"
        return 1
    fi
    log "every channel VS Code declared is sealed"
    return 0
}

# Phrased as "what is still reachable" rather than "what did I do", because the second question is
# the one that can lie: a channel is only blocked if the path is unusable right now.
status() {
    local open=0

    channel() {
        local label="$1" enabled="$2"
        shift 2
        if [ "$enabled" != true ]; then
            printf '  %-16s not blocked (option is off)\n' "$label"
            return
        fi
        local found=""
        for path in "$@"; do
            [ -e "$path" ] || continue
            if [ "$(stat -c %u "$path" 2>/dev/null)" = "0" ] && [ "$(stat -c %a "$path" 2>/dev/null)" = "0" ]; then
                continue
            fi
            found="$found $path"
        done
        if [ -n "$found" ]; then
            printf '  %-16s REACHABLE:%s\n' "$label" "$found"
            open=$((open + 1))
        else
            printf '  %-16s blocked\n' "$label"
        fi
    }

    echo "sandbox: forwarded host channels in this container"

    # Word splitting is the point: each path has to arrive as a separate argument. SC2046 is the
    # unquoted command substitution, SC2086 the unquoted $ROOTS inside it.
    # shellcheck disable=SC2046,SC2086
    channel "ssh agent" "$BLOCK_SSH" \
        $(find $ROOTS -maxdepth 3 -type s -name 'vscode-ssh-auth-*.sock' 2>/dev/null)
    channel "gpg agent" "$BLOCK_GPG" "$GNUPG_DIR/S.gpg-agent"
    channel "x11 display" "$BLOCK_X11" "$X11_DIR"/X*
    # shellcheck disable=SC2046,SC2086
    channel "vscode ipc" "$BLOCK_IPC" \
        $(find $ROOTS -maxdepth 3 -type s \
            \( -name 'vscode-ipc-*.sock' -o -name 'vscode-git-*.sock' \
               -o -name 'vscode-remote-containers-ipc-*.sock' \) 2>/dev/null)

    # Reported rather than acted on: it is a bind mount, and the only lever for it is on the host.
    local wayland
    wayland="$(awk '$5 ~ /wayland/ { print $5 }' "$MOUNTINFO" 2>/dev/null | tr '\n' ' ')"
    if [ -n "${wayland// /}" ]; then
        printf '  %-16s REACHABLE: %s\n' "wayland display" "$wayland"
        printf '  %-16s (bind mount; set "dev.containers.mountWaylandSocket": false on the host)\n' ""
        open=$((open + 1))
    fi

    # Reported first among the mechanisms, because it is the one the others depend on: with sudo
    # in hand every seal above is one command from being undone.
    if [ "$DROP_SUDO" != true ]; then
        printf '  %-16s not dropped (option is off) -- every block above is undoable\n' "sudo"
    elif sudo_works; then
        printf '  %-16s STILL AVAILABLE to %s -- every block above is undoable\n' "sudo" "$USERNAME"
        open=$((open + 1))
    else
        printf '  %-16s dropped\n' "sudo"
    fi

    if pgrep -f 'sandbox\.sh daemon' >/dev/null 2>&1; then
        if [ -n "$INOTIFY" ]; then
            printf '  %-16s running (inotify, %ss poll backstop)\n' "sweeper" "$SWEEP_INTERVAL"
        else
            printf '  %-16s running (POLL ONLY, every %ss -- inotifywait is not installed)\n' \
                "sweeper" "$SWEEP_INTERVAL"
        fi
    else
        printf '  %-16s NOT RUNNING\n' "sweeper"
        open=$((open + 1))
    fi

    [ "$open" -eq 0 ]
}

# The sweeper.
#
# Polling alone leaves a window that is far too wide to call a boundary. Measured against a socket
# forwarded exactly the way VS Code forwards one, with a one-second interval, an attacker looping on
# connect() got 13,959 successful connections over 935ms before the seal landed. One is enough to
# have the host's ssh-agent sign something. So the poll is the backstop, not the mechanism:
# inotify is what closes most of that gap, sealing on the kernel's create event rather than up to a
# whole interval later.
#
# It does not close the gap completely and nothing available in here can -- see the README. The
# socket has to be allowed to exist or the container cannot be attached to, and between the helper's
# bind() and this seal there is always some window. inotify makes it roughly a millisecond instead
# of a second; it does not make it zero.
INOTIFY="$(command -v inotifywait 2>/dev/null || true)"
WATCH_DIRS=""

# Only the directories that exist: inotifywait fails on a missing one, and ~/.gnupg and
# /tmp/.X11-unix are both created by VS Code partway through attaching.
watch_dirs_now() {
    local dir out=""
    for dir in /tmp "$X11_DIR" "$GNUPG_DIR" "/tmp/user/$USER_UID" "/run/user/$USER_UID"; do
        [ -d "$dir" ] && out="$out $dir"
    done
    echo "$out"
}

start_watcher() {
    [ -n "$INOTIFY" ] || return 0
    WATCH_DIRS="$1"
    [ -n "${WATCH_DIRS// /}" ] || return 0

    # Matched on its own command line rather than tracked by pid, because killing the subshell that
    # reads from it would otherwise leave inotifywait orphaned on a dead pipe.
    pkill -f 'inotifywait -m -q -e create' 2>/dev/null || true

    # shellcheck disable=SC2086
    (
        "$INOTIFY" -m -q -e create -e moved_to $WATCH_DIRS 2>/dev/null | while read -r _; do
            sweep >/dev/null 2>&1
        done
    ) &
}

daemon() {
    if [ -n "$INOTIFY" ]; then
        log "sweeper started as $(whoami): inotify, with a ${SWEEP_INTERVAL}s poll as backstop"
    else
        warn "inotifywait is not installed, so sealing waits for the next poll -- up to"
        warn "  ${SWEEP_INTERVAL}s during which a forwarded socket is usable. Install inotify-tools."
    fi

    trap 'pkill -f "inotifywait -m -q -e create" 2>/dev/null; exit 0' TERM INT

    while true; do
        # VS Code creates ~/.gnupg and /tmp/.X11-unix while attaching, so the set of watchable
        # directories grows after this loop starts. Re-arm whenever it changes.
        local now
        now="$(watch_dirs_now)"
        if [ "$now" != "$WATCH_DIRS" ]; then
            start_watcher "$now"
        fi

        sweep >/dev/null 2>&1
        sleep "$SWEEP_INTERVAL"
    done
}

case "${1:-sweep}" in
    block-fixed)    block_fixed ;;
    repair)         repair ;;
    drop-sudo)      drop_sudo ;;
    sweep)          block_fixed; sweep ;;
    daemon)         daemon ;;
    status)         status ;;
    check-manifest) check_manifest "${2:-$$}" ;;
    *)              echo "usage: sandbox.sh {repair|drop-sudo|block-fixed|sweep|daemon|status|check-manifest}" >&2; exit 2 ;;
esac
