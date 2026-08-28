#!/usr/bin/env bash
# dropSudo off, which is the only way to test the privileged paths at all: with the grant removed
# the test user cannot drive a sweep, restart the entrypoint, or stop the daemon. Everything here
# needs one of those, so it cannot live in test.sh.
#
# It doubles as the check that dropSudo is a real option rather than decoration -- a feature that
# removed sudo regardless of what you asked for would be one nobody could adopt gradually.
set -e
source dev-container-features-test-lib
source ./_helpers.sh

check "sudo survives when the option is off" bash -c '
    . /usr/local/share/nshafer-sandbox/config
    [ "$DROP_SUDO" = false ] || { echo "dropSudo: $DROP_SUDO"; exit 1; }
    sudo -n true || { echo "sudo was dropped despite dropSudo=false"; exit 1; }'

check "the report says so rather than claiming success" bash -c '
    out=$(sandbox-report || true)
    echo "$out"
    echo "$out" | grep -qE "sudo +not dropped \(option is off\)"'

# ---------------------------------------------------------------------------------------------
# The bind-mount guard, driven by a synthetic mount table. A real bind mount needs CAP_SYS_ADMIN
# *and* an unconfined AppArmor profile, and CI runners deny the second -- so wayland_bind_mount
# cannot be relied on to run there. These need no special capability and therefore always do.
#
# They must run with the sweeper stopped: every check asserts a socket was *not* modified, and a
# live daemon would seal it against the real mount table the moment it was created, between the
# before and after readings.
# ---------------------------------------------------------------------------------------------

check "the sweeper can be stopped, as these checks require" bash -c '
    sudo -n pkill -f "sandbox\.sh daemon" 2>/dev/null || true
    for _ in $(seq 1 50); do
        pgrep -f "sandbox\.sh daemon" >/dev/null || break
        sleep 0.2
    done
    ! pgrep -f "sandbox\.sh daemon" >/dev/null || { echo "daemon still running"; exit 1; }'

check "a socket listed as a mount is refused by the sweep, not sealed" bash -c '
    sock-bind /tmp/vscode-ssh-auth-pretend-mount.sock
    before=$(stat -c %a:%U /tmp/vscode-ssh-auth-pretend-mount.sock)
    echo "before: $before"
    # Field 5 is the mount point; the rest only has to be shaped like mountinfo.
    printf "%s\n" "99 98 0:99 / /tmp/vscode-ssh-auth-pretend-mount.sock rw,relatime - overlay overlay rw" \
        > /tmp/fake-mountinfo
    out=$(sudo -n env SANDBOX_MOUNTINFO=/tmp/fake-mountinfo \
        /usr/local/share/nshafer-sandbox/sandbox.sh sweep 2>&1)
    echo "$out" | grep -q "bind mount from the host" || { echo "no bind-mount warning"; echo "$out"; exit 1; }
    after=$(stat -c %a:%U /tmp/vscode-ssh-auth-pretend-mount.sock)
    echo "after:  $after"
    [ "$before" = "$after" ] || { echo "$before -> $after: a mount was modified"; exit 1; }'

# The control: identical socket, identical code path, absent from the mount table. Without this, a
# guard that refused *everything* would look like a pass.
check "the same socket is sealed when it is not a mount" bash -c '
    : > /tmp/empty-mountinfo
    sudo -n env SANDBOX_MOUNTINFO=/tmp/empty-mountinfo \
        /usr/local/share/nshafer-sandbox/sandbox.sh sweep >/dev/null 2>&1
    ls -l /tmp/vscode-ssh-auth-pretend-mount.sock
    [ "$(stat -c %a /tmp/vscode-ssh-auth-pretend-mount.sock)" = 0 ] \
        || { echo "not sealed -- the guard is refusing everything"; exit 1; }'

check "the warning names the host-side setting, the only real fix for wayland" bash -c '
    sock-bind /tmp/vscode-ssh-auth-pretend-mount2.sock
    printf "%s\n" "99 98 0:99 / /tmp/vscode-ssh-auth-pretend-mount2.sock rw,relatime - overlay overlay rw" \
        > /tmp/fake-mountinfo2
    sudo -n env SANDBOX_MOUNTINFO=/tmp/fake-mountinfo2 \
        /usr/local/share/nshafer-sandbox/sandbox.sh sweep 2>&1 | grep -q "dev.containers.mountWaylandSocket"'

# The report has to be able to fail, or it is decoration. The daemon is still stopped here.
check "the report fails loudly when a channel is reachable" bash -c '
    sock-bind /tmp/vscode-ssh-auth-open.sock
    out=$(sandbox-report) && { echo "report exited 0 with a channel open:"; echo "$out"; exit 1; }
    echo "$out"
    echo "$out" | grep -q "REACHABLE"
    echo "$out" | grep -q "NOT RUNNING"'

# ---------------------------------------------------------------------------------------------
# The entrypoint, which can only be re-run with root.
# ---------------------------------------------------------------------------------------------

check "the entrypoint restarts the sweeper" bash -c '
    sudo -n /usr/local/share/nshafer-sandbox/entrypoint.sh
    sleep 1
    [ "$(count-sweepers)" = 1 ] || { echo "sweepers: $(count-sweepers)"; exit 1; }'

check "a second entrypoint run does not stack a second sweeper" bash -c '
    sudo -n /usr/local/share/nshafer-sandbox/entrypoint.sh
    # Settled, not sampled: a second sweeper that is slow to appear is still caught.
    for _ in $(seq 1 10); do
        n=$(count-sweepers)
        [ "$n" = 1 ] || { echo "sweepers: $n"; ps -eo pid,ppid,args | grep "[s]andbox.sh daemon"; exit 1; }
        sleep 0.3
    done
    echo "one sweeper, stable across 10 samples"'

# ---------------------------------------------------------------------------------------------
# The repair path for what 1.0.0 left behind. persist-homedir keeps /home on a named volume, so a
# ~/.gnupg that 1.0.0 made root-owned survives every rebuild and keeps the container unattachable:
#   Container server: [Error: EACCES: permission denied, unlink '/home/<user>/.gnupg/S.gpg-agent']
# ---------------------------------------------------------------------------------------------

check "a root-owned gpg directory is handed back at container start" bash -c '
    # Reproduce what 1.0.0 left on a persisted home volume.
    mkdir -p -m 700 "$HOME/.gnupg"
    sock-bind "$HOME/.gnupg/S.gpg-agent" >/dev/null 2>&1 || true
    sudo -n chown root:root "$HOME/.gnupg" && sudo -n chmod 0555 "$HOME/.gnupg"
    ls -ld "$HOME/.gnupg"
    sudo -n /usr/local/share/nshafer-sandbox/sandbox.sh repair
    ls -ld "$HOME/.gnupg"
    [ "$(stat -c %U "$HOME/.gnupg")" = "$(whoami)" ] || { echo "not repaired"; exit 1; }
    # The exact operation VS Code failed on.
    rm -f "$HOME/.gnupg/S.gpg-agent"
    sock-bind "$HOME/.gnupg/S.gpg-agent" || { echo "VS Code still could not attach"; exit 1; }'

check "a directory the feature does not own is left alone" bash -c '
    sudo -n mkdir -p /opt/not-ours && sudo -n chown root:root /opt/not-ours && sudo -n chmod 0555 /opt/not-ours
    sudo -n /usr/local/share/nshafer-sandbox/sandbox.sh repair
    [ "$(stat -c %U /opt/not-ours)" = root ] || { echo "repair reached beyond its own paths"; exit 1; }'

reportResults
