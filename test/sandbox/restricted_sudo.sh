#!/usr/bin/env bash
# sudoMode=restricted, run as the remote user -- the vantage point that matters, because every
# claim here is a claim about what that user can and cannot do.
#
# This mode is the one place the feature hands a privilege back, so the tests are shaped around the
# two ways that goes wrong. The blanket grant has to be gone (otherwise the allowlist is theatre),
# and the allowlist has to be exactly the allowlist (otherwise it is a blanket grant with extra
# steps). The lint checks are here rather than in a unit test of their own because every rule in it
# is a route from an allowed command back to full root, and a regression in one is not a style
# regression.
#
# Note what is NOT asserted here: what the allowlist actually permits. Two things stop it, and both
# are the point rather than a gap. The fragment is 0440 root:root, so this user cannot read it -- a
# test that grepped it would only prove the file is unreadable. And `sudo -l` cannot answer either:
# sudo is setuid, no_new_privs is inherited from the parent process and can never be cleared, and
# both CI and this repo's own dev container carry it, so every sudo call in here fails before it
# reads a policy. The restricted_sudo_policy scenario runs as root and asks sudo itself.
set -e
source dev-container-features-test-lib
source ./_helpers.sh

SBX=/usr/local/share/devcontainer/sandbox/sandbox.sh
FRAGMENT=/etc/sudoers.d/900-sandbox-restricted

check "the mode and the allowlist were baked in" bash -c '
    . /usr/local/share/devcontainer/sandbox/config
    [ "$SUDO_MODE" = restricted ] || { echo "mode: $SUDO_MODE"; exit 1; }
    cat /usr/local/share/devcontainer/sandbox/sudo-commands'

# ---------------------------------------------------------------------------------------------
# The half that has to hold no matter what the allowlist says.
# ---------------------------------------------------------------------------------------------

check "the blanket grant is gone" bash -c '
    out=$(sudo -n true 2>&1) && { echo "BLANKET SUDO STILL WORKS -- the allowlist is theatre"; exit 1; }
    echo "  refused: $out"'

# The attack the whole feature exists to stop. Still has to fail in this mode.
check "the documented undo still does not work" bash -c '
    sock-bind /tmp/vscode-ssh-auth-restricted.sock
    wait-sealed /tmp/vscode-ssh-auth-restricted.sock || { echo "never sealed"; exit 1; }
    sudo -n chmod 666 /tmp/vscode-ssh-auth-restricted.sock 2>&1 | sed "s/^/  /" || true
    [ "$(stat -c %a /tmp/vscode-ssh-auth-restricted.sock)" = 0 ] || { echo "the seal was undone"; exit 1; }'

# Only the metadata, because 0440 root:root is exactly what stops this user reading the content.
# The rules inside it are checked in the restricted_sudo_policy scenario, which runs as root.
check "the fragment is installed, root-owned and read-only" bash -c '
    ls -l '"$FRAGMENT"'
    [ "$(stat -c %U:%G '"$FRAGMENT"')" = "root:root" ] || { echo "not root-owned"; exit 1; }
    [ "$(stat -c %a '"$FRAGMENT"')" = 440 ] || { echo "mode $(stat -c %a '"$FRAGMENT"')"; exit 1; }
    cat '"$FRAGMENT"' 2>&1 | sed "s/^/  /"
    ! cat '"$FRAGMENT"' >/dev/null 2>&1 || { echo "the remote user can read the sudoers fragment"; exit 1; }'

# ---------------------------------------------------------------------------------------------
# The lint. Each of these is a real route from an allowed command back to full root, so each is a
# regression test and not a style test. lint-sudo exits 2 on an error and 1 on a warning.
# ---------------------------------------------------------------------------------------------

lint_rejects() {
    check "lint rejects: $1" bash -c '
        out=$('"$SBX"' lint-sudo "$1" 2>&1); rc=$?
        echo "$out" | sed "s/^/  /"
        [ "$rc" = 2 ] || { echo "expected an error, got rc=$rc"; exit 1; }' _ "$1"
}

lint_rejects '/bin/sh -c echo'                       # a shell runs anything
lint_rejects '/usr/bin/python3 /opt/app/run.py'      # so does an interpreter, pinned or not
lint_rejects '/usr/bin/find /var -name x'            # -exec runs anything
lint_rejects '/usr/bin/vim /etc/hosts'               # :!sh
lint_rejects '/usr/bin/env /bin/date'                # env runs what follows it
lint_rejects '/usr/sbin/iptables'                    # no arguments means every argument
lint_rejects '/usr/bin/apt-get'                      # maintainer scripts run as root
lint_rejects '/bin/systemctl reboot *'               # a wildcard matches / and spans arguments
lint_rejects 'systemctl restart nginx'               # relative path: the caller owns PATH
lint_rejects '/bin/systemctl restart a; /bin/sh'     # sudo never runs a shell, so this is one entry
lint_rejects '/usr/sbin/needrestart -r a'            # CVE-2024-48990 and siblings
lint_rejects '/bin/true'                             # would break the feature's own sudo probe
lint_rejects '/usr/bin/../bin/id -u'                 # the path checked is not the path run

check "lint rejects a binary the user can rewrite" bash -c '
    mkdir -p /tmp/sbx-bin; printf "#!/bin/sh\nexit 0\n" > /tmp/sbx-bin/mine; chmod 0777 /tmp/sbx-bin/mine
    out=$('"$SBX"' lint-sudo "/tmp/sbx-bin/mine --pinned" 2>&1); rc=$?
    echo "$out" | sed "s/^/  /"
    [ "$rc" = 2 ] || { echo "expected an error, got rc=$rc"; exit 1; }
    echo "$out" | grep -q "not root" || { echo "expected an owner finding"; exit 1; }'

check "lint accepts a pinned command under a root-owned path" bash -c '
    out=$('"$SBX"' lint-sudo "/usr/bin/id -u" 2>&1); rc=$?
    echo "$out" | sed "s/^/  /"
    [ "$rc" = 0 ] || { echo "expected clean, got rc=$rc"; exit 1; }'

check "lint warns, without rejecting, on a pinned command that can write a file" bash -c '
    out=$('"$SBX"' lint-sudo "/usr/bin/cp /etc/hosts /etc/hosts.bak" 2>&1); rc=$?
    echo "$out" | sed "s/^/  /"
    [ "$rc" = 1 ] || { echo "expected a warning, got rc=$rc"; exit 1; }'

# ---------------------------------------------------------------------------------------------

check "sandbox-status reports the mode and lists the allowlist" bash -c '
    sandbox-status | tee /dev/stderr
    sandbox-status | grep -qE "sudo +restricted"
    sandbox-status | grep -q "/usr/bin/id -u"
    sandbox-status | grep -qE "no-new-privs"'

reportResults
