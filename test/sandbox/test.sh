#!/usr/bin/env bash
# Runs as the remote user, which is exactly the right vantage point: almost every claim this
# feature makes is a claim about what the *user* can no longer do. Where root is needed, it is
# reached through sudo and said so explicitly.
#
# Unlike the other features here, the harness does run this one's entrypoint and postStartCommand,
# so the daemon and the fixed blocks are already in place when the first check runs. That is worth
# leaning on: the checks below test the container as it actually comes up, not a simulation of it.
set -e
source dev-container-features-test-lib

# perl, because it is the one interpreter present in every image this suite runs on (the Debian
# base has no python3 and no node). A unix socket outlives the process that bound it, so
# bind-and-exit leaves behind exactly the artifact VS Code leaves behind.
sudo tee /usr/local/bin/sock-bind >/dev/null <<'PERL'
#!/usr/bin/perl
use strict; use Socket;
socket(my $s, PF_UNIX, SOCK_STREAM, 0) or die "socket: $!\n";
bind($s, sockaddr_un($ARGV[0])) or die "bind refused: $!\n";
listen($s, 1);
print "bound $ARGV[0]\n";
PERL
sudo tee /usr/local/bin/sock-connect >/dev/null <<'PERL'
#!/usr/bin/perl
use strict; use Socket;
socket(my $s, PF_UNIX, SOCK_STREAM, 0) or die "socket: $!\n";
connect($s, sockaddr_un($ARGV[0])) or die "connect refused: $!\n";
print "connected $ARGV[0]\n";
PERL
sudo chmod 0755 /usr/local/bin/sock-bind /usr/local/bin/sock-connect

# pkill returns when the signal is queued, not when the process has gone. A fixed sleep is a bet on
# how fast the machine is, and CI runners are slower and more contended than a laptop -- so wait for
# the condition instead of for the clock.
sudo tee /usr/local/bin/stop-sweeper >/dev/null <<'SH'
#!/bin/sh
pkill -f 'sandbox\.sh daemon' 2>/dev/null
for _ in $(seq 1 50); do
    pgrep -f 'sandbox\.sh daemon' >/dev/null || { echo "sweeper stopped"; exit 0; }
    sleep 0.2
done
echo "sweeper still running after 10s" >&2
exit 1
SH
sudo chmod 0755 /usr/local/bin/stop-sweeper

# "How many sweepers are running" is not the same question as "how many processes match", and
# pgrep only answers the second. The daemon runs `find ... | while read` on every pass, and bash
# forks a subshell for the right-hand side of a pipeline; that subshell inherits the parent's
# command line verbatim. So mid-sweep there are two or more processes whose cmdline reads
# "bash .../sandbox.sh daemon", and a raw count reports two sweepers. Measured over 400 samples
# against a busy daemon, that count was wrong 37 times -- which is precisely the intermittent
# failure this check used to show.
#
# Filtering by parent does not fix it (also 37/400): a transient subshell whose parent has already
# exited is reparented to init, so its parent is no longer a match either.
#
# Session leadership does, and was wrong 0 times out of 400. The entrypoint starts the daemon under
# setsid, making it a session leader -- pid == sid -- while every subshell it forks inherits that
# session without leading it. The check below fails loudly if setsid is absent, because the
# entrypoint then falls back to plain nohup and this method would silently count zero.
sudo tee /usr/local/bin/count-sweepers >/dev/null <<'SH'
#!/bin/sh
command -v setsid >/dev/null 2>&1 || {
    echo "count-sweepers: no setsid, so sweepers are not session leaders and cannot be counted" >&2
    exit 1
}
pids=$(pgrep -f 'sandbox\.sh daemon' 2>/dev/null || true)
[ -n "$pids" ] || { echo 0; exit 0; }
ps -o pid=,sess= -p "$(echo $pids | tr ' ' ',')" 2>/dev/null | awk '$1 == $2' | wc -l
SH
sudo chmod 0755 /usr/local/bin/count-sweepers

check "the scripts and config landed" bash -c '
    test -x /usr/local/share/nshafer-sandbox/sandbox.sh
    test -x /usr/local/share/nshafer-sandbox/entrypoint.sh
    test -x /usr/local/share/nshafer-sandbox/post-start.sh
    test -x /usr/local/share/nshafer-sandbox/post-attach.sh
    test -x /usr/local/bin/sandbox-report
    test -r /usr/local/share/nshafer-sandbox/config'

check "defaults were baked in" bash -c '
    . /usr/local/share/nshafer-sandbox/config
    [ "$BLOCK_SSH" = true ] || { echo "ssh: $BLOCK_SSH"; exit 1; }
    [ "$BLOCK_GPG" = true ] || { echo "gpg: $BLOCK_GPG"; exit 1; }
    [ "$BLOCK_X11" = true ] || { echo "x11: $BLOCK_X11"; exit 1; }
    [ "$BLOCK_IPC" = true ] || { echo "ipc: $BLOCK_IPC"; exit 1; }
    [ "$USERNAME" = "$(whoami)" ] || { echo "user: $USERNAME vs $(whoami)"; exit 1; }'

# ---------------------------------------------------------------------------------------------
# The fixed blocks. Structural rather than swept: the directory is root-owned and unwritable, so
# the forwarded socket cannot be created in the first place. No race, no daemon needed.
# ---------------------------------------------------------------------------------------------

check "the display directory is sealed" bash -c '
    ls -ld /tmp/.X11-unix
    [ "$(stat -c %U /tmp/.X11-unix)" = root ] || { echo "owner: $(stat -c %U /tmp/.X11-unix)"; exit 1; }
    [ "$(stat -c %a /tmp/.X11-unix)" = 555 ]  || { echo "mode: $(stat -c %a /tmp/.X11-unix)"; exit 1; }'

# The seal proven from the user side, which is the only side that matters.
check "the user cannot create an X socket" bash -c '
    ! sock-bind /tmp/.X11-unix/X0 2>&1 | tee /dev/stderr | grep -qi "bound"
    sock-bind /tmp/.X11-unix/X0 2>&1 | grep -qi "permission denied"'

check "the gpg directory is sealed" bash -c '
    ls -ld "$HOME/.gnupg"
    [ "$(stat -c %U "$HOME/.gnupg")" = root ] || { echo "owner: $(stat -c %U "$HOME/.gnupg")"; exit 1; }
    [ "$(stat -c %a "$HOME/.gnupg")" = 555 ]  || { echo "mode: $(stat -c %a "$HOME/.gnupg")"; exit 1; }'

check "the user cannot replace the gpg agent socket" bash -c '
    test -e "$HOME/.gnupg/S.gpg-agent"
    rm -f "$HOME/.gnupg/S.gpg-agent" 2>&1 | tee /dev/stderr | grep -qi "permission denied"
    test -e "$HOME/.gnupg/S.gpg-agent"
    ! sock-bind "$HOME/.gnupg/S.gpg-agent" 2>&1 | grep -q bound'

# ---------------------------------------------------------------------------------------------
# Tombstoning, the reason this feature seals rather than deletes. Three separate properties, each
# checked from the user, because deleting gives you only the first and not for long.
# ---------------------------------------------------------------------------------------------

check "a forwarded ssh socket is sealed, not deleted" bash -c '
    sock-bind /tmp/vscode-ssh-auth-test-uuid.sock
    test -S /tmp/vscode-ssh-auth-test-uuid.sock
    sudo /usr/local/share/nshafer-sandbox/sandbox.sh sweep

    # Still on disk. That is the difference from -delete, and it is what blocks the rebind below.
    test -e /tmp/vscode-ssh-auth-test-uuid.sock || { echo "deleted, not sealed"; exit 1; }
    ls -l /tmp/vscode-ssh-auth-test-uuid.sock
    [ "$(stat -c %U /tmp/vscode-ssh-auth-test-uuid.sock)" = root ] || exit 1
    [ "$(stat -c %a /tmp/vscode-ssh-auth-test-uuid.sock)" = 0 ]    || exit 1'

check "the user cannot connect to a sealed socket" bash -c '
    out=$(sock-connect /tmp/vscode-ssh-auth-test-uuid.sock 2>&1) && { echo "CONNECTED: $out"; exit 1; }
    echo "$out"
    echo "$out" | grep -qi "permission denied"'

check "the user cannot remove a sealed socket" bash -c '
    rm -f /tmp/vscode-ssh-auth-test-uuid.sock 2>&1 | tee /dev/stderr | grep -qi "not permitted"
    test -e /tmp/vscode-ssh-auth-test-uuid.sock'

check "nothing can bind the path again" bash -c '
    out=$(sock-bind /tmp/vscode-ssh-auth-test-uuid.sock 2>&1) && { echo "REBOUND: $out"; exit 1; }
    echo "$out"
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
    sudo /usr/local/share/nshafer-sandbox/sandbox.sh sweep
    for s in /tmp/user/1000/vscode-git-abc123.sock /tmp/user/1000/vscode-ipc-deep.sock; do
        ls -l "$s"
        [ "$(stat -c %a "$s")" = 0 ] || { echo "$s not sealed -- depth 3 was missed"; exit 1; }
    done'

check "the remote-containers ipc socket is swept" bash -c '
    sock-bind /tmp/vscode-remote-containers-ipc-x.sock
    sudo /usr/local/share/nshafer-sandbox/sandbox.sh sweep
    [ "$(stat -c %a /tmp/vscode-remote-containers-ipc-x.sock)" = 0 ]'

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

# The value of the manifest: a channel whose name none of the globs know is still surfaced, so a
# future VS Code forwarding something new is reported rather than silently missed.
check "check-manifest reports a declared channel the globs do not cover" bash -c '
    sock-bind /tmp/some-future-name.sock
    out=$(REMOTE_CONTAINERS_SOCKETS='"'"'["/tmp/some-future-name.sock"]'"'"' \
        /usr/local/share/nshafer-sandbox/sandbox.sh check-manifest 2>&1) \
        && { echo "check-manifest exited 0 with an open channel:"; echo "$out"; exit 1; }
    echo "$out"
    echo "$out" | grep -q "/tmp/some-future-name.sock and it is still reachable"'

# The scrub and the manifest check have to coexist: BASH_ENV unsets these variables in every
# non-interactive bash, the lifecycle hooks included, so by the time a hook calls check-manifest
# they are gone from its shell -- and gone from anything it execs. Passing its own pid is what
# keeps the check working, because the kernel's copy of the exec environment is untouched.
check "the scrub really does blind a naive check" bash -c '
    out=$(SSH_AUTH_SOCK=/tmp/vscode-ssh-auth-test-uuid.sock bash -c "
        [ -z \"\$SSH_AUTH_SOCK\" ] || { echo \"BASH_ENV scrub did not run\"; exit 1; }
        /usr/local/share/nshafer-sandbox/sandbox.sh check-manifest
    " 2>&1)
    echo "$out"
    # Nothing declared, because the intermediate shell scrubbed it before exec.
    [ -z "$out" ] || { echo "expected no manifest to be found"; exit 1; }'

check "passing the caller pid restores it" bash -c '
    out=$(SSH_AUTH_SOCK=/tmp/vscode-ssh-auth-test-uuid.sock bash -c "
        [ -z \"\$SSH_AUTH_SOCK\" ] || { echo \"BASH_ENV scrub did not run\"; exit 1; }
        /usr/local/share/nshafer-sandbox/sandbox.sh check-manifest \$\$
    " 2>&1)
    echo "$out"
    echo "$out" | grep -q "every channel VS Code declared is sealed"'

# Root cannot do this itself: reading another user'"'"'s /proc/<pid>/environ needs CAP_SYS_PTRACE,
# which Docker does not grant by default -- and granting it to a hardening feature would let the
# remote user ptrace the root daemon doing the hardening.
check "the container genuinely lacks CAP_SYS_PTRACE" bash -c '
    REMOTE_CONTAINERS_SOCKETS='"'"'["/tmp/canary.sock"]'"'"' sleep 20 &
    sleep 1
    readable=no
    for f in /proc/[0-9]*/environ; do
        sudo tr "\0" "\n" < "$f" 2>/dev/null | grep -q "canary.sock" && readable=yes
    done
    kill %1 2>/dev/null || true
    echo "root could read another user env: $readable"
    [ "$readable" = no ] || echo "NOTE: SYS_PTRACE is present here; the manifest could be swept directly"'

# ---------------------------------------------------------------------------------------------
# What must NOT be touched. A sweep that eats the agent's own sockets is worse than no sweep.
# ---------------------------------------------------------------------------------------------

check "unrelated sockets are left alone" bash -c '
    mkdir -p /tmp/cc-socks /tmp/mcp-test
    sock-bind /tmp/cc-socks/53.sock
    sock-bind /tmp/mcp-test/mcp.sock
    sock-bind /tmp/app.sock
    sudo /usr/local/share/nshafer-sandbox/sandbox.sh sweep
    for s in /tmp/cc-socks/53.sock /tmp/mcp-test/mcp.sock /tmp/app.sock; do
        [ "$(stat -c %U "$s")" = "$(whoami)" ] || { echo "$s was taken; the sweep is too broad"; exit 1; }
    done
    echo "claude, mcp and app sockets untouched"'

# ---------------------------------------------------------------------------------------------
# The bind-mount guard, and it is the most important safety property in the feature. A forwarded
# Wayland socket is a bind mount of the host's /run/user/<uid>/wayland-0, and permission changes on
# a bind mount are written through to the source -- so sealing one would land on the socket the
# user's own desktop session is running on. Docker bind-mounts /etc/hosts into every container,
# which gives this a real mount to aim at without needing CAP_SYS_ADMIN to create one.
# ---------------------------------------------------------------------------------------------

check "/etc/hosts is genuinely a bind mount here" bash -c '
    awk "\$5 == \"/etc/hosts\"" /proc/self/mountinfo | tee /dev/stderr | grep -q /etc/hosts'

check "a bind-mounted directory is refused, not sealed" bash -c '
    # The workspace folder is a bind mount in this harness, which makes it a safe stand-in for a
    # host-mounted /tmp/.X11-unix: real mount, and modifying it would write back to the host.
    dir=$(awk "\$5 ~ /^\/workspaces/ { print \$5; exit }" /proc/self/mountinfo)
    [ -n "$dir" ] || { echo "no bind-mounted directory available to test with"; exit 1; }
    echo "using $dir"
    before=$(stat -c %a:%U "$dir")
    out=$(sudo env SANDBOX_X11_DIR="$dir" /usr/local/share/nshafer-sandbox/sandbox.sh block-fixed 2>&1)
    echo "$out"
    echo "$out" | grep -q "mounted from the host" || { echo "no warning issued"; exit 1; }
    after=$(stat -c %a:%U "$dir")
    [ "$before" = "$after" ] || { echo "$before -> $after: a bind mount was modified"; exit 1; }'

# ---------------------------------------------------------------------------------------------
# The daemon. This is what covers a second VS Code window attaching hours later with a fresh UUID,
# which a bounded loop stops doing after five minutes.
# ---------------------------------------------------------------------------------------------

check "the container start left a sweeper running" bash -c '
    [ "$(count-sweepers)" = 1 ] || { echo "sweepers: $(count-sweepers)"; pgrep -af "sandbox\.sh daemon"; exit 1; }
    echo "one sweeper, pid $(pgrep -f "sandbox\.sh daemon" | head -1)"'

check "a second entrypoint run does not stack a second daemon" bash -c '
    sudo /usr/local/share/nshafer-sandbox/entrypoint.sh
    # Settled, not sampled: require the count to stay at one across several reads, so a second
    # daemon that is slow to appear is still caught.
    # Sampled repeatedly rather than once, so a second sweeper that is slow to appear is caught.
    for _ in $(seq 1 10); do
        n=$(count-sweepers)
        [ "$n" = 1 ] || { echo "sweepers: $n"; ps -eo pid,ppid,args | grep "[s]andbox.sh daemon"; exit 1; }
        sleep 0.3
    done
    echo "one sweeper, stable across 10 samples"'

check "the daemon seals a socket that appears after it started" bash -c '
    sock-bind /tmp/vscode-ssh-auth-late-uuid.sock
    for _ in $(seq 1 20); do
        [ "$(stat -c %a /tmp/vscode-ssh-auth-late-uuid.sock 2>/dev/null)" = 0 ] && break
        sleep 1
    done
    ls -l /tmp/vscode-ssh-auth-late-uuid.sock
    [ "$(stat -c %a /tmp/vscode-ssh-auth-late-uuid.sock)" = 0 ] || { echo "daemon did not catch it"; exit 1; }'

check "sandbox-report says every channel is blocked" bash -c '
    sandbox-report | tee /dev/stderr
    sandbox-report | grep -qE "ssh agent +blocked"
    sandbox-report | grep -qE "gpg agent +blocked"
    sandbox-report | grep -qE "x11 display +blocked"
    sandbox-report | grep -qE "vscode ipc +blocked"'

# The report has to be able to fail, or it is decoration. Daemon stopped first, or it seals the
# socket before the report can see it.
check "the report fails loudly when a channel is reachable" bash -c '
    sudo stop-sweeper
    sock-bind /tmp/vscode-ssh-auth-open.sock
    out=$(sandbox-report) && { echo "report exited 0 with a channel open:"; echo "$out"; exit 1; }
    echo "$out"
    echo "$out" | grep -q "REACHABLE"
    echo "$out" | grep -q "NOT RUNNING"'

# ---------------------------------------------------------------------------------------------
# The bind-mount guard, driven by a synthetic mount table. A real bind mount needs CAP_SYS_ADMIN
# *and* an unconfined AppArmor profile, and CI runners deny the second -- so wayland_bind_mount
# cannot be relied on to run there. These need no privileges and therefore always do.
#
# They have to run with the sweeper stopped. Every check below asserts that a socket was *not*
# modified, and the daemon sweeps the same path every second using the real mount table, where the
# socket is not a mount -- so a live daemon seals it between the before and after readings and the
# check fails intermittently. The previous check stopped it; this makes that a stated requirement
# instead of a property of the ordering.
# ---------------------------------------------------------------------------------------------

check "the sweeper is stopped, as these checks require" bash -c '
    sudo stop-sweeper
    ! pgrep -f "sandbox\.sh daemon" >/dev/null || { echo "daemon still running"; exit 1; }'

check "a socket listed as a mount is refused by the sweep, not sealed" bash -c '
    sock-bind /tmp/vscode-ssh-auth-pretend-mount.sock
    before=$(stat -c %a:%U /tmp/vscode-ssh-auth-pretend-mount.sock)
    echo "before: $before"
    # Field 5 is the mount point; the rest only has to be shaped like mountinfo.
    printf "%s\n" "99 98 0:99 / /tmp/vscode-ssh-auth-pretend-mount.sock rw,relatime - overlay overlay rw" \
        > /tmp/fake-mountinfo
    out=$(sudo env SANDBOX_MOUNTINFO=/tmp/fake-mountinfo \
        /usr/local/share/nshafer-sandbox/sandbox.sh sweep 2>&1)
    echo "$out"
    echo "$out" | grep -q "bind mount from the host" || { echo "no bind-mount warning"; exit 1; }
    after=$(stat -c %a:%U /tmp/vscode-ssh-auth-pretend-mount.sock)
    echo "after:  $after"
    [ "$before" = "$after" ] || { echo "$before -> $after: a mount was modified"; exit 1; }'

# The control for the check above: identical socket, identical code path, absent from the mount
# table. Without this, a guard that refused *everything* would look like a pass.
check "the same socket is sealed when it is not a mount" bash -c '
    : > /tmp/empty-mountinfo
    sudo env SANDBOX_MOUNTINFO=/tmp/empty-mountinfo \
        /usr/local/share/nshafer-sandbox/sandbox.sh sweep >/dev/null 2>&1
    ls -l /tmp/vscode-ssh-auth-pretend-mount.sock
    [ "$(stat -c %a /tmp/vscode-ssh-auth-pretend-mount.sock)" = 0 ] \
        || { echo "not sealed -- the guard is refusing everything"; exit 1; }'

check "the warning names the host-side setting, the only real fix for wayland" bash -c '
    sock-bind /tmp/vscode-ssh-auth-pretend-mount2.sock
    printf "%s\n" "99 98 0:99 / /tmp/vscode-ssh-auth-pretend-mount2.sock rw,relatime - overlay overlay rw" \
        > /tmp/fake-mountinfo2
    sudo env SANDBOX_MOUNTINFO=/tmp/fake-mountinfo2 \
        /usr/local/share/nshafer-sandbox/sandbox.sh sweep 2>&1 | grep -q "dev.containers.mountWaylandSocket"'

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
    echo "$out"
    echo "$out" | grep -q "ssh=\[\] askpass=\[\] ipc=\[\]"'

check "a login shell has them scrubbed" bash -c '
    out=$(SSH_AUTH_SOCK=/tmp/x.sock bash -lc "echo ssh=[\$SSH_AUTH_SOCK]" 2>/dev/null)
    echo "$out"
    echo "$out" | grep -q "ssh=\[\]"'

check "a non-interactive bash is covered through BASH_ENV" bash -c '
    [ "$BASH_ENV" = /usr/local/share/nshafer-sandbox/scrub-env.sh ] \
        || { echo "BASH_ENV: $BASH_ENV"; exit 1; }
    out=$(SSH_AUTH_SOCK=/tmp/x.sock bash -c "echo ssh=[\$SSH_AUTH_SOCK]")
    echo "$out"
    echo "$out" | grep -q "ssh=\[\]"'

reportResults
