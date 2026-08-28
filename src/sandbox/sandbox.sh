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

CONFIG=/usr/local/share/nshafer-sandbox/config
# The defaults matter: the test suite drives this script directly, without the generated config.
BLOCK_SSH=true
BLOCK_GPG=true
BLOCK_X11=true
BLOCK_IPC=true
SWEEP_INTERVAL=1
USERNAME=root
USER_HOME=/root
USER_UID=0
[ -r "$CONFIG" ] && . "$CONFIG"

# Overridable so the tests can point all of this at a scratch tree instead of the real /tmp.
ROOTS="${SANDBOX_ROOTS:-/tmp /run}"
X11_DIR="${SANDBOX_X11_DIR:-/tmp/.X11-unix}"
GNUPG_DIR="${SANDBOX_GNUPG_DIR:-$USER_HOME/.gnupg}"

log() { echo "==> sandbox: $*"; }
warn() { echo "!!! sandbox: $*" >&2; }

# A forwarded Wayland socket is not a file VS Code created in here -- it is a bind mount of the
# host's /run/user/<uid>/wayland-0. It cannot be removed (EBUSY) and cannot be unmounted (no
# CAP_SYS_ADMIN in a stock container), and it must never be chmod'ed: permission changes on a bind
# mount are written through to the source, so a chmod here lands on the socket the host's own
# desktop session is using. Every mutation below is gated on this returning false.
is_mount() {
    awk -v p="$1" '$5 == p { found = 1 } END { exit !found }' /proc/self/mountinfo 2>/dev/null
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

# The two paths that need no daemon at all, because they are not random. A directory the remote
# user owns is a directory the remote user can have a socket created in; taking the directory
# instead means the forwarded socket cannot be created in the first place. There is no window
# between creation and sweep, because there is no creation.
#
# Re-run at every container start rather than only at build time. Build-time state lives in the
# image, and the image is masked wherever the path is a volume -- persist-homedir puts /home on
# one, so a home directory carried over from an older container arrives with whatever it had.
block_fixed() {
    if [ "$BLOCK_X11" = true ]; then
        if is_mount "$X11_DIR"; then
            warn "$X11_DIR is mounted from the host; cannot seal it from in here"
        else
            mkdir -p "$X11_DIR" 2>/dev/null
            # Sockets already inside survive a chmod of the directory, so clear them out first.
            for sock in "$X11_DIR"/X*; do
                [ -e "$sock" ] && tombstone "$sock" "display socket"
            done
            if chown root:root "$X11_DIR" 2>/dev/null && chmod 0555 "$X11_DIR" 2>/dev/null; then
                log "sealed display directory $X11_DIR (root:root 0555)"
            fi
        fi
    fi

    # Same trick, and here is why it is the directory rather than just the S.gpg-agent file: the
    # owner of a directory may unlink anything inside it however that thing is owned, and ~/.gnupg
    # belongs to the remote user. A root-owned tombstone in a user-owned directory is removable; a
    # root-owned directory is not. gpg inside the container stops working, which is the ask.
    if [ "$BLOCK_GPG" = true ]; then
        if is_mount "$GNUPG_DIR"; then
            warn "$GNUPG_DIR is mounted from the host; cannot seal it from in here"
        elif [ ! -d "$(dirname "$GNUPG_DIR")" ]; then
            # mkdir -p would create the home directory itself, owned by root, and a remote user who
            # cannot write their own $HOME is a broken container. Wait for a start where it exists.
            warn "$(dirname "$GNUPG_DIR") does not exist yet; leaving the gpg block to a later start"
        else
            mkdir -p "$GNUPG_DIR" 2>/dev/null
            chmod 0700 "$GNUPG_DIR" 2>/dev/null
            [ -e "$GNUPG_DIR/S.gpg-agent" ] && tombstone "$GNUPG_DIR/S.gpg-agent" "gpg agent socket"
            # Placed as well as sealed: the forwarder finds the path taken rather than free.
            [ -e "$GNUPG_DIR/S.gpg-agent" ] || : > "$GNUPG_DIR/S.gpg-agent" 2>/dev/null
            chown root:root "$GNUPG_DIR/S.gpg-agent" 2>/dev/null
            chmod 000 "$GNUPG_DIR/S.gpg-agent" 2>/dev/null
            if chown root:root "$GNUPG_DIR" 2>/dev/null && chmod 0555 "$GNUPG_DIR" 2>/dev/null; then
                log "sealed gpg directory $GNUPG_DIR (root:root 0555)"
            fi
        fi
    fi
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
report() {
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

    # shellcheck disable=SC2086
    channel "ssh agent" "$BLOCK_SSH" \
        $(find $ROOTS -maxdepth 3 -type s -name 'vscode-ssh-auth-*.sock' 2>/dev/null)
    channel "gpg agent" "$BLOCK_GPG" "$GNUPG_DIR/S.gpg-agent"
    channel "x11 display" "$BLOCK_X11" "$X11_DIR"/X*
    # shellcheck disable=SC2086
    channel "vscode ipc" "$BLOCK_IPC" \
        $(find $ROOTS -maxdepth 3 -type s \
            \( -name 'vscode-ipc-*.sock' -o -name 'vscode-git-*.sock' \
               -o -name 'vscode-remote-containers-ipc-*.sock' \) 2>/dev/null)

    # Reported rather than acted on: it is a bind mount, and the only lever for it is on the host.
    local wayland
    wayland="$(awk '$5 ~ /wayland/ { print $5 }' /proc/self/mountinfo 2>/dev/null | tr '\n' ' ')"
    if [ -n "${wayland// /}" ]; then
        printf '  %-16s REACHABLE: %s\n' "wayland display" "$wayland"
        printf '  %-16s (bind mount; set "dev.containers.mountWaylandSocket": false on the host)\n' ""
        open=$((open + 1))
    fi

    if pgrep -f 'sandbox\.sh daemon' >/dev/null 2>&1; then
        printf '  %-16s running, every %ss\n' "sweeper" "$SWEEP_INTERVAL"
    else
        printf '  %-16s NOT RUNNING\n' "sweeper"
        open=$((open + 1))
    fi

    [ "$open" -eq 0 ]
}

daemon() {
    log "sweeper started as $(whoami), sweeping every ${SWEEP_INTERVAL}s"
    while true; do
        sweep >/dev/null 2>&1
        sleep "$SWEEP_INTERVAL"
    done
}

case "${1:-sweep}" in
    block-fixed)    block_fixed ;;
    sweep)          block_fixed; sweep ;;
    daemon)         daemon ;;
    report)         report ;;
    check-manifest) check_manifest "${2:-$$}" ;;
    *)              echo "usage: sandbox.sh {block-fixed|sweep|daemon|report|check-manifest}" >&2; exit 2 ;;
esac
