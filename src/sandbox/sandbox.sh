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
SUDO_MODE=drop
SUDO_ALLOW_UNSAFE=false
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
# Overridable for the same reason. The sudoers fragment is named to sort after anything a distro
# or another feature drops in there, and with no dot or tilde in it -- sudo silently ignores a
# file in sudoers.d whose name has either.
SUDOERS_FILE="${SANDBOX_SUDOERS_FILE:-/etc/sudoers.d/900-sandbox-restricted}"
SUDO_COMMANDS_FILE="${SANDBOX_SUDO_COMMANDS_FILE:-/usr/local/share/devcontainer/sandbox/sudo-commands}"

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
# Three modes, because a project that genuinely needs a root command should not have to choose
# between that command and the whole feature:
#
#   drop        the blanket grant goes and nothing replaces it. The default, and the only mode
#               where the setuid bit comes off sudo as a last resort.
#   restricted  the blanket grant goes and a linted allowlist replaces it. The allowlist is then
#               the trust boundary -- see lint_sudo_entry for what that costs.
#   keep        nothing is touched. Every seal in this feature is one command from being undone.
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

# `sudo -n true` is the probe for "a blanket grant exists", and it only works while nothing can
# allowlist `true`. That is why lint_sudo_entry refuses it by name rather than as a style rule.

# The container-wide setuid lock. The feature used to declare it in securityOpt and no longer can:
# the flag blocks every setuid path, sudo included, so a feature that ships it unconditionally
# cannot also offer restricted sudo. It moved to the README as a line the user adds. Reported here
# so neither half of that trade is silent.
no_new_privs_set() {
    grep -qE '^NoNewPrivs:[[:space:]]*1$' /proc/self/status 2>/dev/null
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# One entry per line, written by install.sh. A separate file rather than a line in `config`
# because config is sourced: a command list is the one value here a human writes by hand, and it
# carries spaces and punctuation that have no business being evaluated by a shell.
read_sudo_commands() {
    local line
    [ -r "$SUDO_COMMANDS_FILE" ] || return 0
    while IFS= read -r line; do
        line="$(trim "$line")"
        case "$line" in '' | '#'*) continue ;; esac
        printf '%s\n' "$line"
    done < "$SUDO_COMMANDS_FILE"
}

sudo_command_count() { read_sudo_commands | grep -c . || true; }

# --------------------------------------------------------------------------------------------
# The allowlist lint.
#
# A restricted sudoers file is only ever as good as the commands in it, and the failure mode is
# not that it looks dangerous -- it is that it looks careful. A real-world file that allowlisted
# exactly seven commands, every one of them a plausible operational need, handed out root twice
# over: once through an unpinned `iptables` and once through `needrestart`. Nothing about either
# line reads as a shell.
#
# So the lint is not a style check. Every rule below is a route to root that a reviewer misses.
# It runs at build time, where it fails the build, and again at every container start, where a
# failure falls back to dropping sudo entirely rather than installing a list it cannot vouch for.

# Basenames that give away root whatever arguments follow, so pinning the arguments does not help.
sudo_deny_reason() {
    case "$1" in
        sh | bash | dash | zsh | ksh | csh | tcsh | fish | ash | rbash | busybox | toybox)
            echo "it is a shell, so it runs anything as root" ;;
        perl | perl5 | python | python2 | python3 | ruby | node | nodejs | php | lua | luajit | tclsh | expect | awk | gawk | mawk | nawk)
            echo "it is an interpreter, so it runs anything as root" ;;
        su | sudo | sudoedit | doas | pkexec | runuser | chroot | unshare | nsenter | capsh | setpriv | newgrp)
            echo "it starts a process as another user, which is a root shell" ;;
        setcap | setfacl | visudo | passwd | chpasswd | useradd | usermod | adduser | groupmod | groupadd | mount | umount)
            echo "it edits the privilege model itself" ;;
        env | xargs | find | nohup | setsid | timeout | stdbuf | script | watch | nice | ionice | flock | systemd-run | at | batch | crontab)
            echo "it runs a command you name, so it runs anything as root" ;;
        vi | vim | nvim | view | ex | ed | nano | pico | emacs | less | more | most | pg | man | info)
            echo "it has a shell escape, so it gives a root shell" ;;
        docker | podman | nerdctl | ctr | crictl | runc | lxc-attach | machinectl)
            echo "it starts a container, and a container can mount the host filesystem as root" ;;
        gdb | strace | ltrace | perf)
            echo "it attaches to and drives another process as root" ;;
        needrestart)
            echo "it is a known local root escalation (CVE-2024-48990 and siblings)" ;;
        true | false | :)
            echo "the feature runs 'sudo -n true' to prove the blanket grant is gone" ;;
        *) return 1 ;;
    esac
}

# Basenames that are root with free arguments and merely risky with pinned ones. An entry with no
# arguments allows every argument, so for these that is an error; with the arguments pinned it is
# a warning, because the entry is then only as safe as what those arguments point at.
sudo_pin_reason() {
    case "$1" in
        cp | mv | dd | tee | install | ln | link | truncate | touch | rm | rmdir | shred | chmod | chown | chgrp)
            echo "it writes or re-owns any file you name" ;;
        tar | cpio | unzip | zip | 7z | 7za | rsync | scp | sftp)
            echo "it writes any path the archive or the far side names" ;;
        sed | patch | tac | diff3 | tail | head | cat)
            echo "it reads or edits any file you name, and sed -i writes one" ;;
        systemctl | service | initctl | rc-service | openrc | telinit)
            echo "with free arguments it starts, stops or masks any unit" ;;
        apt | apt-get | apt-key | aptitude | dpkg | dpkg-reconfigure | yum | dnf | rpm | apk | pacman | zypper | snap | flatpak | pip | pip3 | npm | npx | yarn | pnpm | gem | cargo | composer)
            echo "installing a package runs its maintainer scripts as root" ;;
        git | ssh | curl | wget | nc | ncat | netcat | socat | nmap | tcpdump)
            echo "it fetches or runs what the far side chooses" ;;
        journalctl | dmesg)
            echo "it pipes to a pager, and the pager has a shell escape -- pin --no-pager" ;;
        iptables | ip6tables | iptables-save | iptables-restore | ip6tables-save | ip6tables-restore | iptables-legacy | iptables-nft | nft | ipset | ip | tc | ebtables | arptables | conntrack | firewall-cmd | ufw)
            echo "it rewrites the firewall, which switches off the egress-filter feature entirely" ;;
        *) return 1 ;;
    esac
}

# Prints every finding on stdout, one per line, prefixed error: or warn:. Returns 2 for an error,
# 1 for warnings only, 0 for clean.
lint_sudo_entry() {
    local entry bin base reason mode owner dir rc=0 has_args=no

    entry="$(trim "$1")"
    [ -n "$entry" ] || return 0

    _err() { echo "error: $*"; rc=2; }
    _warn() { echo "warn:  $*"; [ "$rc" -ge 1 ] || rc=1; }

    # A control character means the entry came from somewhere it should not have.
    if [ "$entry" != "$(printf '%s' "$entry" | tr -d '\000-\037')" ]; then
        _err "the entry contains a control character"
    fi

    # sudo execs the command directly. It never runs a shell, so every one of these is a author
    # who expects semantics they will not get -- and `sudo /bin/foo; rm -rf /` reads as one entry.
    case "$entry" in
        *[\;\&\|\`\$\<\>\"\'\\]*)
            _err "shell syntax does not work here: sudo execs the command, it never runs a shell" ;;
    esac

    # The classic sudoers escape. A sudoers wildcard is a glob, and a glob matches / and matches
    # across argument boundaries: `apt-get install *` permits `apt-get install --option=...`,
    # and `chmod 666 /tmp/*` permits `chmod 666 /tmp/../etc/shadow`.
    case "$entry" in
        *[\*\?\[\]]*)
            _err "a wildcard matches / and matches across arguments, so it permits far more than it reads as" ;;
    esac

    # Command negation in sudoers is bypassable by definition: it denies a path, and the same
    # binary reached by another path or a copy is a different path.
    case "$entry" in
        *'!'*) _err "sudoers command negation is bypassable -- allow what is needed instead of denying what is not" ;;
    esac

    # Characters that are special to sudoers itself, not to a shell. The entry is interpolated into
    # a sudoers line verbatim (see write_restricted_sudoers), and visudo checks that the result
    # parses, not that it means one grant. A ':' starts a second host-spec, '=' and '(' start a
    # second privilege spec, and '#' begins a comment that silently drops every argument after it --
    # so any of them smuggles a second grant out of a line that reads as one pinned command.
    case "$entry" in
        *[:=\(\)\#]*)
            _err "the characters : = ( ) # are special to sudoers and can smuggle a second grant past the lint" ;;
    esac

    bin="${entry%% *}"
    base="${bin##*/}"
    [ "$entry" = "$bin" ] || has_args=yes

    case "$bin" in
        /*) ;;
        *) _err "$bin is not an absolute path, so PATH decides what runs -- and the caller owns PATH" ;;
    esac
    case "$bin" in
        */../* | */..) _err "$bin walks through .., so the path checked is not the path run" ;;
    esac

    if reason="$(sudo_deny_reason "$base")"; then
        _err "$base is never safe to allow, pinned or not: $reason"
    elif reason="$(sudo_pin_reason "$base")"; then
        if [ "$has_args" = no ]; then
            _err "$base with no arguments permits every argument, and $reason"
        else
            _warn "$base is only as safe as these exact arguments: $reason"
        fi
    elif [ "$has_args" = no ]; then
        _warn "$bin has no arguments, so every argument is permitted. Pin the arguments."
    fi

    # Who owns the binary owns what sudo runs. -L throughout, and every ancestor directory, not
    # just the last one: a symlink's own mode is always 777 and says nothing, and a writable
    # directory anywhere along the path lets the whole subtree below it be replaced. /usr/local/bin
    # group-writable, or a tool under an /opt the remote user owns, is the grant handed straight
    # back with nothing in the entry itself looking wrong.
    #
    # Only for an absolute path. A relative one is already an error above, and running the ancestor
    # walk on it would resolve against the current directory and never terminate: dirname of a bare
    # name walks down to ".", whose dirname is "." forever, and the "$dir" = / break never fires.
    if [ "${bin#/}" != "$bin" ] && [ -e "$bin" ]; then
        if [ ! -f "$bin" ]; then
            _err "$bin is not a regular file"
        else
            owner="$(stat -L -c %u "$bin" 2>/dev/null || echo -1)"
            mode="$(stat -L -c %a "$bin" 2>/dev/null || echo 777)"
            [ "$owner" = 0 ] || _err "$bin is owned by uid $owner, not root, so its owner chooses what sudo runs"
            [ "$(( 8#$mode & 8#022 ))" -eq 0 ] || _err "$bin is mode $mode, so group or other can rewrite what sudo runs"

            # Only the first bad ancestor is reported. Every directory above it is bad for the
            # same reason, and eight copies of one finding buries the seven other entries.
            dir="$bin"
            while dir="$(dirname "$dir")"; do
                owner="$(stat -L -c %u "$dir" 2>/dev/null || echo -1)"
                mode="$(stat -L -c %a "$dir" 2>/dev/null || echo 777)"
                if [ "$owner" != 0 ]; then
                    _err "$dir is owned by uid $owner, not root, so what is under it can be swapped"
                    break
                fi
                if [ "$(( 8#$mode & 8#022 ))" -ne 0 ]; then
                    _err "$dir is mode $mode, so what is under it can be swapped"
                    break
                fi
                [ "$dir" = / ] && break
            done
        fi
    else
        _warn "$bin does not exist yet, so its owner and mode could not be checked"
    fi

    unset -f _err _warn
    return "$rc"
}

# Lints the whole list. Prints each entry with its findings underneath. Returns 1 if any entry
# raised an error.
lint_sudo_commands() {
    local entry out rc errors=0 warnings=0 total=0

    while IFS= read -r entry; do
        total=$((total + 1))
        out="$(lint_sudo_entry "$entry")"
        rc=$?
        case "$rc" in
            2) errors=$((errors + 1)) ;;
            1) warnings=$((warnings + 1)) ;;
        esac
        if [ -n "$out" ]; then
            echo "  $entry"
            # SC2001: the parameter-expansion form cannot indent every line of a multi-line
            # string, only substitute within it. sed is the right tool here.
            # shellcheck disable=SC2001
            echo "$out" | sed 's/^/      /'
        else
            echo "  $entry"
            echo "      ok"
        fi
    done < <(read_sudo_commands)

    if [ "$total" -eq 0 ]; then
        warn "sudoMode is restricted but sudoCommands is empty, so this behaves exactly like drop"
        return 0
    fi

    log "sudo allowlist: $total entries, $errors with an error, $warnings with a warning"
    [ "$errors" -eq 0 ]
}

# --------------------------------------------------------------------------------------------

# Takes away every blanket route to root. Shared by drop and restricted, and idempotent, because
# it runs again at every container start.
remove_blanket_sudo() {
    local f grp

    # The grant common-utils writes is /etc/sudoers.d/<username>; drop any file that names the
    # user. Skipping this feature's own file matters more than it looks: it names the user on
    # every line, so without the guard restricted mode would delete its own allowlist.
    for f in /etc/sudoers.d/*; do
        [ -f "$f" ] || continue
        [ "$f" = "$SUDOERS_FILE" ] && continue
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
}

# One command per line and root as the only target. Not (ALL:ALL): letting the caller pick the
# target user buys nothing here and costs the whole class of runas bugs, CVE-2019-14287 included.
#
# Nothing is escaped on the way in, and it does not need to be. sudoers wants a backslash before
# a comma, a colon, an equals or a backslash -- and the lint has already refused all of those: the
# backslash and the colon, equals, parenthesis and hash as sudoers metacharacters, and the comma
# is the option separator so it cannot reach here. visudo below is the last check, not the only
# one: it confirms the fragment parses, but a smuggled second grant parses too, so the metacharacter
# refusal above is what stops it. A fragment that will not parse is never installed.
write_restricted_sudoers() {
    local tmp entry n=0

    tmp="$(mktemp)" || { warn "could not create a temporary file for the sudoers fragment"; return 1; }

    {
        echo "# Generated by the sandbox devcontainer feature. Rewritten at every container start."
        echo "# Do not edit: set sudoCommands on the feature instead."
        echo "#"
        echo "# The blanket grant is gone. Only these commands run as root, with these exact"
        echo "# arguments. This list is now the trust boundary of the whole feature: any command"
        echo "# here that can write a file or start a program undoes every seal the sandbox makes."
        echo ""
    } > "$tmp"

    while IFS= read -r entry; do
        printf '%s ALL=(root) NOPASSWD: %s\n' "$USERNAME" "$entry" >> "$tmp"
        n=$((n + 1))
    done < <(read_sudo_commands)

    if [ "$n" -eq 0 ]; then
        rm -f "$tmp"
        return 1
    fi

    # A syntax error in a sudoers.d fragment does not fail that fragment. It makes sudo refuse to
    # run at all, for everyone, root included. So it is checked before it is installed, never
    # after.
    if command -v visudo >/dev/null 2>&1; then
        if ! visudo -cqf "$tmp" >/dev/null 2>&1; then
            warn "the generated sudoers fragment does not parse, so it was not installed:"
            visudo -cf "$tmp" 2>&1 | sed 's/^/!!!   /' >&2
            rm -f "$tmp"
            return 1
        fi
    else
        warn "visudo is not installed, so the generated sudoers fragment could not be checked"
    fi

    if install -o root -g root -m 0440 "$tmp" "$SUDOERS_FILE" 2>/dev/null; then
        rm -f "$tmp"
        log "wrote $n allowed command(s) to $SUDOERS_FILE"
        return 0
    fi
    rm -f "$tmp"
    warn "could not install $SUDOERS_FILE"
    return 1
}

apply_sudo_policy() {
    case "$SUDO_MODE" in
        drop | restricted | keep) ;;
        *)
            warn "unknown sudoMode '$SUDO_MODE'; treating it as drop"
            SUDO_MODE=drop
            ;;
    esac

    # Clear this feature's own previous allowlist before anything else, so every mode transition is
    # handled in one place rather than only restricted->drop. A prior build's fragment must not
    # survive a switch to keep, to drop, or to a root remote user -- restricted rewrites it below.
    rm -f "$SUDOERS_FILE"

    if [ "$SUDO_MODE" = keep ]; then
        warn "sudoMode=keep: $USERNAME keeps sudo, so every seal in this feature is one command"
        warn "  from being undone. This feature is decoration in this configuration."
        return 0
    fi

    if [ "$USERNAME" = root ]; then
        warn "the remote user is root, so there is no sudo grant to drop and nothing here binds"
        return 0
    fi

    remove_blanket_sudo

    # Fails closed, and all the way: a list that does not lint clean is not installed, and the mode
    # degrades to a full drop rather than to "restricted, minus the part that was rejected". The
    # user asked for a smaller grant than drop, so the safe direction to miss in is a smaller one
    # still.
    if [ "$SUDO_MODE" = restricted ]; then
        if lint_sudo_commands; then
            write_restricted_sudoers || { warn "falling back to a full sudo drop"; SUDO_MODE=drop; }
        elif [ "$SUDO_ALLOW_UNSAFE" = true ]; then
            warn "sudoAllowUnsafe=true, so the allowlist above is installed with its errors."
            warn "  Root in this container is now whatever those entries permit."
            write_restricted_sudoers || { warn "falling back to a full sudo drop"; SUDO_MODE=drop; }
        else
            warn "the sudo allowlist has errors, so it was NOT installed. Sudo is fully dropped."
            warn "  Fix the entries above, or set sudoAllowUnsafe to accept them."
            SUDO_MODE=drop
        fi
    fi

    if [ "$SUDO_MODE" = restricted ]; then
        # The whole allowlist is dead weight under this flag, and nothing about the failure says
        # so: sudo reports it, but only to whoever runs a command and reads the error.
        if no_new_privs_set; then
            warn "no_new_privs is set on this container, so sudo cannot run at all -- it is setuid."
            warn "  Remove \"securityOpt\": [\"no-new-privileges\"] from devcontainer.json, or this"
            warn "  allowlist has no effect. The flag is also inherited, so a parent container's"
            warn "  copy of it lands here too and cannot be cleared from inside."
        fi

        if sudo_works; then
            warn "$USERNAME can still run any command with sudo, so the allowlist is not the"
            warn "  boundary. Something outside this feature grants it. Use sudoMode=drop."
        else
            log "restricted sudo in place for $USERNAME"
        fi
        return 0
    fi

    # drop. The stale allowlist was already cleared at the top of this function.
    # Verified by outcome, not by the steps above: sudo is configurable in more ways than are worth
    # enumerating, and a grant this missed would silently hand back everything. If it still works,
    # take the setuid bit off the binary, which no amount of sudoers configuration can restore.
    # Only ever in this mode -- in restricted mode it would break the allowlist along with the rest.
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
    # The mode as it actually came out, not as it was asked for. apply_sudo_policy degrades
    # restricted to drop whenever the allowlist does not lint clean, and a status line that still
    # said "restricted" would be reporting the request rather than the result.
    local entry eff_mode="$SUDO_MODE"
    if [ "$eff_mode" = restricted ] && [ ! -f "$SUDOERS_FILE" ]; then
        eff_mode=drop-after-rejected-allowlist
    fi

    if [ "$eff_mode" = keep ]; then
        printf '  %-16s KEPT for %s -- every block above is undoable (sudoMode=keep)\n' "sudo" "$USERNAME"
        open=$((open + 1))
    elif sudo_works; then
        printf '  %-16s STILL AVAILABLE to %s -- every block above is undoable\n' "sudo" "$USERNAME"
        open=$((open + 1))
    elif [ "$eff_mode" = restricted ]; then
        printf '  %-16s restricted -- blanket grant gone, %s command(s) allowed\n' \
            "sudo" "$(sudo_command_count)"
        # Listed rather than counted, because in this mode the list is the boundary and a reader
        # cannot check a number.
        while IFS= read -r entry; do
            printf '  %-16s   %s\n' "" "$entry"
        done < <(read_sudo_commands)
    elif [ "$eff_mode" = drop-after-rejected-allowlist ]; then
        printf '  %-16s dropped -- sudoMode is restricted, but that allowlist was rejected\n' "sudo"
    else
        printf '  %-16s dropped\n' "sudo"
    fi

    # Advisory, never counted as an open channel: the feature cannot set this flag itself any more
    # (see no_new_privs_set), so a container without it is the normal case and not a fault.
    if no_new_privs_set; then
        if [ "$eff_mode" = restricted ]; then
            printf '  %-16s SET -- sudo is setuid, so no allowed command can run\n' "no-new-privs"
        else
            printf '  %-16s set\n' "no-new-privs"
        fi
    elif [ "$eff_mode" = restricted ] || [ "$eff_mode" = keep ]; then
        printf '  %-16s not set (sudoMode=%s needs it unset)\n' "no-new-privs" "$SUDO_MODE"
    else
        printf '  %-16s not set -- add "securityOpt": ["no-new-privileges"] in devcontainer.json\n' \
            "no-new-privs"
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
    apply-sudo)     apply_sudo_policy ;;
    # Kept as a synonym: an image built by an older version of this feature still has that
    # version's entrypoint baked in, and it calls this name.
    drop-sudo)      apply_sudo_policy ;;
    # With an argument it lints that one entry, for a test. With none it lints the configured
    # list, which is what install.sh calls to fail a build.
    lint-sudo)      if [ -n "${2:-}" ]; then lint_sudo_entry "$2"; else lint_sudo_commands; fi ;;
    sweep)          block_fixed; sweep ;;
    daemon)         daemon ;;
    status)         status ;;
    check-manifest) check_manifest "${2:-$$}" ;;
    *)              echo "usage: sandbox.sh {repair|apply-sudo|lint-sudo [entry]|block-fixed|sweep|daemon|status|check-manifest}" >&2; exit 2 ;;
esac
