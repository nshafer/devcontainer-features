#!/usr/bin/env bash
# The feature with its defaults, which now include dropSudo -- so this runs as a user who cannot
# become root. That is the right vantage point rather than a limitation: every claim below is a
# claim about what the *remote user* can no longer do, and a test that could sudo would not be
# testing it.
#
# Anything that genuinely needs root to set up lives in the sudo_kept scenario instead, which turns
# dropSudo off precisely so it can drive the privileged paths.
#
# The harness runs this feature's entrypoint and lifecycle hooks, so the sweeper and the sudo drop
# are already in place when the first check runs. These test the container as it actually comes up.
set -e
source dev-container-features-test-lib
source ./_helpers.sh

check "the scripts and config landed" bash -c '
    test -x /usr/local/share/nshafer-sandbox/sandbox.sh
    test -x /usr/local/share/nshafer-sandbox/entrypoint.sh
    test -x /usr/local/share/nshafer-sandbox/post-start.sh
    test -x /usr/local/share/nshafer-sandbox/post-attach.sh
    test -x /usr/local/bin/sandbox-status
    test -r /usr/local/share/nshafer-sandbox/config'

check "defaults were baked in" bash -c '
    . /usr/local/share/nshafer-sandbox/config
    [ "$BLOCK_SSH" = true ] || { echo "ssh: $BLOCK_SSH"; exit 1; }
    [ "$BLOCK_GPG" = true ] || { echo "gpg: $BLOCK_GPG"; exit 1; }
    [ "$BLOCK_X11" = true ] || { echo "x11: $BLOCK_X11"; exit 1; }
    [ "$BLOCK_IPC" = true ] || { echo "ipc: $BLOCK_IPC"; exit 1; }
    [ "$DROP_SUDO" = true ] || { echo "dropSudo: $DROP_SUDO"; exit 1; }
    [ "$USERNAME" = "$(whoami)" ] || { echo "user: $USERNAME vs $(whoami)"; exit 1; }'

# ---------------------------------------------------------------------------------------------
# The sudo drop, which everything else rests on. Every seal in this feature is a root-owned file,
# and a remote user who can become root undoes all of them with one chmod. A stock dev container
# grants exactly that, so without this the rest is decoration.
# ---------------------------------------------------------------------------------------------

check "the remote user cannot sudo" bash -c '
    out=$(sudo -n true 2>&1) && { echo "SUDO STILL WORKS -- every block here is undoable"; exit 1; }
    echo "  refused: $out"'

check "the grant is gone from both places it can live" bash -c '
    ! grep -rqE "^[[:space:]]*$(whoami)[[:space:]]" /etc/sudoers.d/ 2>/dev/null \
        || { echo "a sudoers.d file still names $(whoami)"; exit 1; }
    groups=$(id -nG); echo "  groups: $groups"
    for g in sudo wheel admin; do
        case " $groups " in *" $g "*) echo "still in group $g"; exit 1;; esac
    done'

# The attack this exists to stop, run for real against a socket the sweeper has sealed.
check "the documented undo does not work" bash -c '
    sock-bind /tmp/vscode-ssh-auth-undo.sock
    wait-sealed /tmp/vscode-ssh-auth-undo.sock || { echo "never sealed"; exit 1; }
    sudo -n chmod 666 /tmp/vscode-ssh-auth-undo.sock 2>&1 | sed "s/^/  /" || true
    ls -l /tmp/vscode-ssh-auth-undo.sock
    [ "$(stat -c %a /tmp/vscode-ssh-auth-undo.sock)" = 0 ] || { echo "the seal was undone"; exit 1; }'

# ---------------------------------------------------------------------------------------------
# The fixed-name channels, and the regression test for the bug that made 1.0.0 unusable.
#
# 1.0.0 pre-empted these by making /tmp/.X11-unix and ~/.gnupg root-owned and unwritable, so the
# socket could never be created. That is a stronger boundary, and it stopped VS Code attaching at
# all: the extension's helper creates these sockets while connecting, could not, and died --
# leaving "Configuring Dev Container" on screen indefinitely with no error and no timeout.
#
# So the first thing checked is not that the channel is blocked. It is that VS Code can still do
# the thing it needs to do.
# ---------------------------------------------------------------------------------------------

check "the display directory stays writable, so VS Code can set up forwarding" bash -c '
    # Exactly what the extension does, from its own log:
    #   Start: Run in container: mkdir -p '"'"'/tmp/.X11-unix'"'"'
    #   X11 forwarding: DISPLAY in container (:0) forwarded to local host (:0).
    mkdir -p /tmp/.X11-unix || { echo "mkdir refused"; exit 1; }
    sock-bind /tmp/.X11-unix/X0 || { echo "REGRESSION: the display socket cannot be created."; \
        echo "  This is what made 1.0.0 hang on Configuring Dev Container."; exit 1; }'

check "the gpg directory stays writable, so VS Code can set up forwarding" bash -c '
    mkdir -p -m 700 "$HOME/.gnupg" || { echo "mkdir refused"; exit 1; }
    sock-bind "$HOME/.gnupg/S.gpg-agent" || { echo "REGRESSION: the gpg socket cannot be created"; exit 1; }
    sock-bind "$HOME/.gnupg/S.keyboxd"   || { echo "REGRESSION: the keyboxd socket cannot be created"; exit 1; }'

check "the display socket is sealed once it exists" bash -c '
    wait-sealed /tmp/.X11-unix/X0 || { echo "never sealed"; exit 1; }
    ls -l /tmp/.X11-unix/X0'

check "the gpg sockets are sealed once they exist" bash -c '
    wait-sealed "$HOME/.gnupg/S.gpg-agent" || { echo "S.gpg-agent never sealed"; exit 1; }
    wait-sealed "$HOME/.gnupg/S.keyboxd"   || { echo "S.keyboxd never sealed"; exit 1; }
    ls -l "$HOME/.gnupg/"'

check "the sealed display socket is unreachable" bash -c '
    out=$(sock-connect /tmp/.X11-unix/X0 2>&1) && { echo "CONNECTED: $out"; exit 1; }
    echo "$out" | grep -qi "permission denied"'

# ---------------------------------------------------------------------------------------------
# Tombstoning, the reason this feature seals rather than deletes. Three separate properties, each
# checked from the user, because deleting gives you only the first and not for long.
# ---------------------------------------------------------------------------------------------

check "a forwarded ssh socket is sealed, not deleted" bash -c '
    sock-bind /tmp/vscode-ssh-auth-test-uuid.sock
    wait-sealed /tmp/vscode-ssh-auth-test-uuid.sock || { echo "never sealed"; exit 1; }
    # Still on disk. That is the difference from -delete, and it is what blocks the rebind below.
    test -e /tmp/vscode-ssh-auth-test-uuid.sock || { echo "deleted, not sealed"; exit 1; }
    ls -l /tmp/vscode-ssh-auth-test-uuid.sock
    [ "$(stat -c %U /tmp/vscode-ssh-auth-test-uuid.sock)" = root ] || exit 1'

check "the user cannot connect to a sealed socket" bash -c '
    out=$(sock-connect /tmp/vscode-ssh-auth-test-uuid.sock 2>&1) && { echo "CONNECTED: $out"; exit 1; }
    echo "$out" | grep -qi "permission denied"'

check "the user cannot remove a sealed socket" bash -c '
    rm -f /tmp/vscode-ssh-auth-test-uuid.sock 2>&1 | tee /dev/stderr | grep -qi "not permitted"
    test -e /tmp/vscode-ssh-auth-test-uuid.sock'

check "nothing can bind the path again" bash -c '
    out=$(sock-bind /tmp/vscode-ssh-auth-test-uuid.sock 2>&1) && { echo "REBOUND: $out"; exit 1; }
    echo "$out" | grep -qi "address already in use\|permission denied"'

# ---------------------------------------------------------------------------------------------
# The depth bug in the approach this is drawn from. XDG_RUNTIME_DIR is /tmp/user/<uid>, so the git
# credential socket -- the one that hands out the host's GitHub token -- sits at depth 3, and a
# -maxdepth 2 sweep misses it while looking thorough.
# ---------------------------------------------------------------------------------------------

check "sockets at XDG_RUNTIME_DIR depth are swept" bash -c '
    mkdir -p /tmp/user/1000
    sock-bind /tmp/user/1000/vscode-git-abc123.sock
    sock-bind /tmp/user/1000/vscode-ipc-deep.sock
    for s in /tmp/user/1000/vscode-git-abc123.sock /tmp/user/1000/vscode-ipc-deep.sock; do
        wait-sealed "$s" || { echo "$s not sealed -- depth 3 was missed"; exit 1; }
        ls -l "$s"
    done'

check "the remote-containers ipc socket is swept" bash -c '
    sock-bind /tmp/vscode-remote-containers-ipc-x.sock
    wait-sealed /tmp/vscode-remote-containers-ipc-x.sock || { echo "not sealed"; exit 1; }'

# ---------------------------------------------------------------------------------------------
# The forwarding manifest. VS Code declares what it forwarded in REMOTE_CONTAINERS_SOCKETS, so a
# channel none of the globs know about can still be surfaced. It is checked from an unprivileged
# hook rather than swept by root, for the two reasons spelled out in sandbox.sh: root cannot read
# it without CAP_SYS_PTRACE, and root must not chmod paths the remote user controls.
# ---------------------------------------------------------------------------------------------

check "check-manifest passes when the declared channels are sealed" bash -c '
    out=$(REMOTE_CONTAINERS_SOCKETS='"'"'["/tmp/vscode-ssh-auth-test-uuid.sock"]'"'"' \
        /usr/local/share/nshafer-sandbox/sandbox.sh check-manifest 2>&1)
    echo "$out"
    echo "$out" | grep -q "every channel VS Code declared is sealed"'

check "check-manifest reports a declared channel the globs do not cover" bash -c '
    sock-bind /tmp/some-future-name.sock
    out=$(REMOTE_CONTAINERS_SOCKETS='"'"'["/tmp/some-future-name.sock"]'"'"' \
        /usr/local/share/nshafer-sandbox/sandbox.sh check-manifest 2>&1) \
        && { echo "check-manifest exited 0 with an open channel:"; echo "$out"; exit 1; }
    echo "$out" | grep -q "/tmp/some-future-name.sock and it is still reachable"'

# BASH_ENV unsets these variables in every non-interactive bash, the lifecycle hooks included, so
# by the time a hook calls check-manifest they are gone from its shell -- and gone from anything it
# execs. Passing its own pid is what keeps the check working, because the kernel's copy of the exec
# environment is untouched.
check "the scrub really does blind a naive check" bash -c '
    out=$(SSH_AUTH_SOCK=/tmp/vscode-ssh-auth-test-uuid.sock bash -c "
        [ -z \"\$SSH_AUTH_SOCK\" ] || { echo \"BASH_ENV scrub did not run\"; exit 1; }
        /usr/local/share/nshafer-sandbox/sandbox.sh check-manifest
    " 2>&1)
    [ -z "$out" ] || { echo "expected no manifest to be found: $out"; exit 1; }'

check "passing the caller pid restores it" bash -c '
    out=$(SSH_AUTH_SOCK=/tmp/vscode-ssh-auth-test-uuid.sock bash -c "
        /usr/local/share/nshafer-sandbox/sandbox.sh check-manifest \$\$
    " 2>&1)
    echo "$out" | grep -q "every channel VS Code declared is sealed"'

# ---------------------------------------------------------------------------------------------
# What must NOT be touched. A sweep that eats the agent's own sockets is worse than no sweep.
# ---------------------------------------------------------------------------------------------

check "unrelated sockets are left alone" bash -c '
    mkdir -p /tmp/cc-socks /tmp/mcp-test
    sock-bind /tmp/cc-socks/53.sock
    sock-bind /tmp/mcp-test/mcp.sock
    sock-bind /tmp/app.sock
    sleep 3
    for s in /tmp/cc-socks/53.sock /tmp/mcp-test/mcp.sock /tmp/app.sock; do
        [ "$(stat -c %U "$s")" = "$(whoami)" ] || { echo "$s was taken; the sweep is too broad"; exit 1; }
    done
    echo "claude, mcp and app sockets untouched"'

# ---------------------------------------------------------------------------------------------
# The sweeper, and how fast it lands. The speed is the difference between a boundary and a
# formality. Sealed on the poll alone a socket stays usable for up to a second, which measured out
# at about 14,000 usable connections -- 13,999 more than it takes to have the host's ssh-agent sign
# something. inotify takes that to single figures, so these check inotify is actually driving it.
# ---------------------------------------------------------------------------------------------

check "the container start left exactly one sweeper running" bash -c '
    [ "$(count-sweepers)" = 1 ] || { echo "sweepers: $(count-sweepers)"; pgrep -af "sandbox\.sh daemon"; exit 1; }
    echo "one sweeper, pid $(pgrep -f "sandbox\.sh daemon" | head -1)"'

check "inotify is available, so sealing is not left to the poll interval" bash -c '
    command -v inotifywait >/dev/null || { echo "inotifywait missing; install.sh did not install it"; exit 1; }
    grep -q "inotify" /var/log/nshafer-sandbox.log || { echo "daemon did not report inotify mode:"; \
        cat /var/log/nshafer-sandbox.log; exit 1; }'

check "a new socket is sealed in milliseconds, not on the next poll" bash -c '
    sock-bind /tmp/vscode-ssh-auth-timing.sock
    start=$(date +%s%N)
    for _ in $(seq 1 200); do
        [ "$(stat -c %a /tmp/vscode-ssh-auth-timing.sock 2>/dev/null)" = 0 ] && break
        sleep 0.01
    done
    ms=$(( ($(date +%s%N) - start) / 1000000 ))
    echo "  sealed after ${ms}ms"
    [ "$(stat -c %a /tmp/vscode-ssh-auth-timing.sock)" = 0 ] || { echo "never sealed"; exit 1; }
    # The poll backstop is 1000ms, so anything well under that proves inotify drove it.
    [ "$ms" -lt 500 ] || { echo "took ${ms}ms -- that is the poll, not inotify"; exit 1; }'

check "sandbox-status says every channel is blocked" bash -c '
    sandbox-status | tee /dev/stderr
    sandbox-status | grep -qE "ssh agent +blocked"
    sandbox-status | grep -qE "gpg agent +blocked"
    sandbox-status | grep -qE "x11 display +blocked"
    sandbox-status | grep -qE "vscode ipc +blocked"
    sandbox-status | grep -qE "sudo +dropped"'

# ---------------------------------------------------------------------------------------------
# The environment scrub. The weakest of the three layers and not a control -- VS Code re-injects
# these -- but it covers shells the ~/.bashrc approach does not, and it must not live in $HOME.
# ---------------------------------------------------------------------------------------------

check "the scrub is wired into /etc, never \$HOME" bash -c '
    grep -q nshafer-sandbox /etc/profile.d/00-nshafer-sandbox.sh
    grep -q nshafer-sandbox /etc/bash.bashrc
    grep -q nshafer-sandbox /etc/zsh/zshenv
    # A persisted home volume masks whatever the image wrote to ~/.bashrc, so a scrub installed
    # there would work exactly once and then quietly stop on the next rebuild.
    ! grep -q nshafer-sandbox "$HOME/.bashrc" 2>/dev/null'

check "an interactive bash has the socket variables scrubbed" bash -c '
    out=$(SSH_AUTH_SOCK=/tmp/x.sock GIT_ASKPASS=/tmp/a.sh VSCODE_IPC_HOOK_CLI=/tmp/i.sock \
        bash -ic "echo ssh=[\$SSH_AUTH_SOCK] askpass=[\$GIT_ASKPASS] ipc=[\$VSCODE_IPC_HOOK_CLI]" 2>/dev/null)
    echo "$out" | grep -q "ssh=\[\] askpass=\[\] ipc=\[\]"'

check "a login shell has them scrubbed" bash -c '
    out=$(SSH_AUTH_SOCK=/tmp/x.sock bash -lc "echo ssh=[\$SSH_AUTH_SOCK]" 2>/dev/null)
    echo "$out" | grep -q "ssh=\[\]"'

check "a non-interactive bash is covered through BASH_ENV" bash -c '
    [ "$BASH_ENV" = /usr/local/share/nshafer-sandbox/scrub-env.sh ] \
        || { echo "BASH_ENV: $BASH_ENV"; exit 1; }
    out=$(SSH_AUTH_SOCK=/tmp/x.sock bash -c "echo ssh=[\$SSH_AUTH_SOCK]")
    echo "$out" | grep -q "ssh=\[\]"'

reportResults
