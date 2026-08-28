#!/usr/bin/env bash
# The single most dangerous thing this feature could get wrong.
#
# VS Code forwards the host's Wayland socket by *bind-mounting* /run/user/<uid>/wayland-0 into the
# container. A bind mount is not a copy: permission changes made to the mount point are written
# straight through to the source. So a sweeper that treats it like any other socket and chmod 000s
# it does not block a channel -- it sets mode 000 on the socket the user's own desktop session is
# running on, outside the container, and takes down their session.
#
# This scenario reproduces that exact shape. SYS_ADMIN is granted to the *test container* only, so
# it can create a real bind mount; the feature itself never asks for the capability.
set -e
source dev-container-features-test-lib

sudo tee /usr/local/bin/sock-bind >/dev/null <<'PERL'
#!/usr/bin/perl
use strict; use Socket;
socket(my $s, PF_UNIX, SOCK_STREAM, 0) or die "socket: $!\n";
bind($s, sockaddr_un($ARGV[0])) or die "bind refused: $!\n";
listen($s, 1);
print "bound $ARGV[0]\n";
PERL
sudo chmod 0755 /usr/local/bin/sock-bind

# Stands in for the host's /run/user/<uid>/wayland-0. Nothing below may alter this file.
sock-bind /tmp/pretend-host-wayland.sock
sudo mkdir -p /tmp/fake-x11
sudo touch /tmp/fake-x11/X0
sudo mount --bind /tmp/pretend-host-wayland.sock /tmp/fake-x11/X0

check "the bind mount was set up, so the scenario is testing something real" bash -c '
    awk "\$5 == \"/tmp/fake-x11/X0\"" /proc/self/mountinfo | grep -q fake-x11 \
        || { echo "no bind mount; SYS_ADMIN may not have applied"; exit 1; }
    ls -l /tmp/fake-x11/X0'

# The proof that the danger is real, not theoretical: the same chmod the sweeper would otherwise
# apply, shown writing through to the source.
check "chmod on the mount point does write through to the source" bash -c '
    sudo cp -a /tmp/pretend-host-wayland.sock /tmp/writethrough-canary.sock
    sudo mkdir -p /tmp/canary-dir && sudo touch /tmp/canary-dir/X0
    sudo mount --bind /tmp/writethrough-canary.sock /tmp/canary-dir/X0
    before=$(stat -c %a /tmp/writethrough-canary.sock); echo "source before: $before"
    sudo chmod 000 /tmp/canary-dir/X0
    after=$(stat -c %a /tmp/writethrough-canary.sock); echo "source after:  $after"
    sudo umount /tmp/canary-dir/X0
    [ "$after" = 0 ] || { echo "expected the write-through; the premise of this test is wrong"; exit 1; }'

check "the sweeper refuses the bind mount and leaves the source untouched" bash -c '
    before=$(stat -c %a:%U /tmp/pretend-host-wayland.sock)
    echo "source before: $before"
    out=$(sudo env SANDBOX_X11_DIR=/tmp/fake-x11 /usr/local/share/nshafer-sandbox/sandbox.sh block-fixed 2>&1)
    echo "$out"
    echo "$out" | grep -q "bind mount from the host" || { echo "no bind-mount warning"; exit 1; }
    after=$(stat -c %a:%U /tmp/pretend-host-wayland.sock)
    echo "source after:  $after"
    [ "$before" = "$after" ] \
        || { echo "$before -> $after: the host socket was modified. This breaks the desktop."; exit 1; }'

check "the warning names the host-side setting, since that is the only real fix" bash -c '
    out=$(sudo env SANDBOX_X11_DIR=/tmp/fake-x11 /usr/local/share/nshafer-sandbox/sandbox.sh block-fixed 2>&1)
    echo "$out" | grep -q "dev.containers.mountWaylandSocket"'

check "a full sweep also leaves it alone" bash -c '
    before=$(stat -c %a:%U /tmp/pretend-host-wayland.sock)
    sudo env SANDBOX_X11_DIR=/tmp/fake-x11 /usr/local/share/nshafer-sandbox/sandbox.sh sweep >/dev/null 2>&1
    after=$(stat -c %a:%U /tmp/pretend-host-wayland.sock)
    echo "$before -> $after"
    [ "$before" = "$after" ] || { echo "the host socket was modified by the sweep"; exit 1; }'

# The report has to admit it rather than quietly claiming the display is blocked, because the user
# has to know to go and change the setting on the host.
check "the report surfaces a mounted wayland socket as reachable" bash -c '
    sudo mkdir -p /tmp/wl && sudo touch /tmp/wl/vscode-wayland-abc.sock
    sudo mount --bind /tmp/pretend-host-wayland.sock /tmp/wl/vscode-wayland-abc.sock
    out=$(sandbox-report || true)
    echo "$out"
    sudo umount /tmp/wl/vscode-wayland-abc.sock
    echo "$out" | grep -q "wayland display" || { echo "wayland not reported"; exit 1; }
    echo "$out" | grep -q "mountWaylandSocket"'

reportResults
