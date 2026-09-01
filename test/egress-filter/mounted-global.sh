#!/usr/bin/env bash
# The global allowlist, and the read-only mount that carries it. The mount is declared by this
# scenario and not by the feature, which is the point of the whole arrangement: a feature's own
# mount metadata has no read-only field, and every workaround for that is mode-dependent -- see the
# mount note in NOTES.md. So the suite declares the mount the way a user does.
#
# Deliberately not asserting anything about which hosts the global list contains. That file belongs
# to whoever runs the tests.
set -e
source dev-container-features-test-lib

check "the global list on the host is merged" bash -c '
    test -r /mnt/egress-filter/allowlist.txt || { echo "global list not mounted"; exit 1; }
    egress-status | tee /dev/stderr | grep -q "global:   ~/.config/egress-filter/allowlist.txt"'

check "the concatenated allowlist carries a global header" bash -c '
    f=/etc/devcontainer/egress-filter/allowlist.txt
    grep -q "^# global: " "$f" || { echo "no global header"; exit 1; }
    # The header names the host-side path, not the mount, for the same reason the status does.
    grep -q "^# global: ~/.config/egress-filter/allowlist.txt" "$f" \
        || { echo "global header does not name the host path"; grep "^# global" "$f"; exit 1; }'

# Read from /proc/mounts as well as trying the write below: the two answer different questions, and
# this one answers it without depending on the uid the container happens to run as.
check "the mount is read-only" bash -c '
    opts=$(awk "\$2 == \"/mnt/egress-filter\" { print \$4 }" /proc/mounts | tail -n1)
    [ -n "$opts" ] || { echo "/mnt/egress-filter is not a mount point"; exit 1; }
    case ",$opts," in *,ro,*) exit 0;; esac
    echo "/mnt/egress-filter is mounted $opts"; exit 1'

check "the global list is read-only from inside, which is why it can be watched" bash -c '
    echo evil.example.net >> /mnt/egress-filter/allowlist.txt 2>&1 | sed "s/^/  /"
    ! grep -q evil /mnt/egress-filter/allowlist.txt 2>/dev/null \
        || { echo "the container could write the global list"; exit 1; }
    echo "  refused, as it must be"'

check "the read-write warning stays quiet on a read-only mount" bash -c '
    ! grep -q "mounted READ-WRITE" /var/log/devcontainer/egress-filter.log \
        || { echo "warned about a read-only mount"; exit 1; }
    ! grep -q "is not mounted" /var/log/devcontainer/egress-filter.log \
        || { echo "warned about a mount that is there"; exit 1; }'

reportResults
