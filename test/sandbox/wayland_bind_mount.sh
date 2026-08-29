#!/usr/bin/env bash
# The single most dangerous thing this feature could get wrong, tested against the real kernel.
#
# VS Code forwards the host's Wayland socket by *bind-mounting* /run/user/<uid>/wayland-0 into the
# container. A bind mount is not a copy: permission changes made to the mount point are written
# straight through to the source. So a sweeper that treats it like any other socket and chmod 000s
# it does not block a channel -- it sets mode 000 on the socket the user's own desktop session is
# running on, outside the container, and takes that session down.
#
# Creating a bind mount needs two things, and the scenario asks for both: CAP_SYS_ADMIN, and an
# unconfined AppArmor profile, because the docker-default profile denies the mount syscall whatever
# capabilities are held. Where a host grants neither -- a locked-down CI runner, a rootless daemon,
# SELinux in enforcing mode -- this degrades to a stated skip rather than a failure, because the
# guard itself is covered with a synthetic mount table in the sudo_kept scenario.
# What is skipped here is only the confirmation that the kernel behaves the way those tests assume.
set -e
source dev-container-features-test-lib
source ./_helpers.sh


# Stands in for the host's /run/user/<uid>/wayland-0. Nothing below may alter this file.
sock-bind /tmp/pretend-host-wayland.sock
sudo -n mkdir -p /tmp/fake-x11
sudo -n touch /tmp/fake-x11/X0

CAN_MOUNT=yes
if ! sudo -n mount --bind /tmp/pretend-host-wayland.sock /tmp/fake-x11/X0 2>/tmp/mount-error; then
    CAN_MOUNT=no
fi

if [ "$CAN_MOUNT" = no ]; then
    echo "=================================================================================="
    echo "SKIPPING the real-bind-mount checks: this host will not let the container mount."
    sed 's/^/  /' /tmp/mount-error
    echo ""
    echo "  Needs CAP_SYS_ADMIN *and* apparmor=unconfined; the scenario asks for both, so one"
    echo "  of them was refused by the host rather than by the container config."
    echo ""
    echo "  The guard this would confirm is still tested in the sudo_kept scenario:"
    echo "    - 'a socket listed as a mount is refused by the sweep, not sealed'"
    echo "    - 'the same socket is sealed when it is not a mount'"
    echo "=================================================================================="

    # Not left empty: a scenario that asserts nothing should still say the feature is installed,
    # or a broken build would show up here as a pass.
    check "the feature is installed even though the mount checks were skipped" bash -c '
        test -x /usr/local/share/devcontainer/sandbox/sandbox.sh
        sandbox-status'

    reportResults
    exit 0
fi

check "the bind mount was set up, so the scenario is testing something real" bash -c '
    awk "\$5 == \"/tmp/fake-x11/X0\"" /proc/self/mountinfo | grep -q fake-x11 \
        || { echo "no bind mount in the table"; exit 1; }
    ls -l /tmp/fake-x11/X0'

# The proof that the danger is real and not theoretical: the same chmod the sweeper would otherwise
# apply, shown writing through to the source.
check "chmod on the mount point does write through to the source" bash -c '
    sudo -n cp -a /tmp/pretend-host-wayland.sock /tmp/writethrough-canary.sock
    sudo -n mkdir -p /tmp/canary-dir && sudo -n touch /tmp/canary-dir/X0
    sudo -n mount --bind /tmp/writethrough-canary.sock /tmp/canary-dir/X0
    before=$(stat -c %a /tmp/writethrough-canary.sock); echo "source before: $before"
    sudo -n chmod 000 /tmp/canary-dir/X0
    after=$(stat -c %a /tmp/writethrough-canary.sock); echo "source after:  $after"
    sudo -n umount /tmp/canary-dir/X0
    [ "$after" = 0 ] || { echo "expected the write-through; the premise of this test is wrong"; exit 1; }'

check "the sweeper refuses the bind mount and leaves the source untouched" bash -c '
    before=$(stat -c %a:%U /tmp/pretend-host-wayland.sock)
    echo "source before: $before"
    out=$(sudo -n env SANDBOX_X11_DIR=/tmp/fake-x11 /usr/local/share/devcontainer/sandbox/sandbox.sh block-fixed 2>&1)
    echo "$out"
    echo "$out" | grep -q "bind mount from the host" || { echo "no bind-mount warning"; exit 1; }
    after=$(stat -c %a:%U /tmp/pretend-host-wayland.sock)
    echo "source after:  $after"
    [ "$before" = "$after" ] \
        || { echo "$before -> $after: the host socket was modified. This breaks the desktop."; exit 1; }'

check "the warning names the host-side setting, since that is the only real fix" bash -c '
    out=$(sudo -n env SANDBOX_X11_DIR=/tmp/fake-x11 /usr/local/share/devcontainer/sandbox/sandbox.sh block-fixed 2>&1)
    echo "$out" | grep -q "dev.containers.mountWaylandSocket"'

check "a full sweep also leaves it alone" bash -c '
    before=$(stat -c %a:%U /tmp/pretend-host-wayland.sock)
    sudo -n env SANDBOX_X11_DIR=/tmp/fake-x11 /usr/local/share/devcontainer/sandbox/sandbox.sh sweep >/dev/null 2>&1
    after=$(stat -c %a:%U /tmp/pretend-host-wayland.sock)
    echo "$before -> $after"
    [ "$before" = "$after" ] || { echo "the host socket was modified by the sweep"; exit 1; }'

# The report has to admit it rather than quietly claiming the display is blocked, because the user
# has to know to go and change the setting on the host.
check "the report surfaces a mounted wayland socket as reachable" bash -c '
    sudo -n mkdir -p /tmp/wl && sudo -n touch /tmp/wl/vscode-wayland-abc.sock
    sudo -n mount --bind /tmp/pretend-host-wayland.sock /tmp/wl/vscode-wayland-abc.sock
    out=$(sandbox-status || true)
    echo "$out"
    sudo -n umount /tmp/wl/vscode-wayland-abc.sock
    echo "$out" | grep -q "wayland display" || { echo "wayland not reported"; exit 1; }
    echo "$out" | grep -q "mountWaylandSocket"'

reportResults
