#!/usr/bin/env bash
# What the restricted allowlist actually permits, asked of sudo itself.
#
# This runs as root because nothing else can ask the question. The generated fragment is 0440
# root:root, so the remote user cannot read it -- and `sudo -l` cannot answer for them either: sudo
# is setuid, no_new_privs is inherited from the parent process and never cleared, and both CI and
# this repo's own dev container carry it, so every sudo call from an unprivileged process in here
# fails before it reaches a policy. Root running `sudo -l -U <user>` gains no privilege, so the
# setuid transition never happens and the policy is evaluated normally.
#
# root is not a claim about the boundary. restricted_sudo makes that claim, as the remote user.
# root is only the vantage point that can read the answer.
#
# The feature will not act when the remote user is root, so these drive sandbox.sh against a user
# made here. That is the same generator the feature runs, pointed at a user this script can see the
# "before" of.
set -e
source dev-container-features-test-lib

SHARE=/usr/local/share/devcontainer/sandbox
SBX=$SHARE/sandbox.sh
FRAGMENT=/etc/sudoers.d/900-sandbox-restricted
TESTUSER=sbxpolicy

# The starting state a stock dev container is in: a user with password-less sudo over everything.
setup_user() {
    useradd -m -s /bin/bash "$TESTUSER" 2>/dev/null || true
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$TESTUSER" > /etc/sudoers.d/"$TESTUSER"
    chmod 0440 /etc/sudoers.d/"$TESTUSER"
}

write_config() {
    cat > "$SHARE/config" <<EOF
BLOCK_SSH=true
BLOCK_GPG=true
BLOCK_X11=true
BLOCK_CODE_CLI=false
BLOCK_GIT_ASKPASS=false
BLOCK_EXT_IPC=true
SWEEP_INTERVAL=1
SUDO_MODE=$1
SUDO_ALLOW_UNSAFE=${2:-false}
USERNAME=$TESTUSER
USER_HOME=/home/$TESTUSER
USER_UID=$(id -u "$TESTUSER" 2>/dev/null || echo 0)
EOF
}

setup_user
write_config restricted
printf '/usr/bin/id -u\n/usr/bin/cp /etc/hosts /etc/hosts.bak\n' > "$SHARE/sudo-commands"

check "the blanket grant is removed and the allowlist installed in its place" bash -c '
    '"$SBX"' apply-sudo 2>&1 | sed "s/^/  /"
    test -f '"$FRAGMENT"' || { echo "no fragment was written"; exit 1; }
    test ! -f /etc/sudoers.d/'"$TESTUSER"' || { echo "the blanket grant file survived"; exit 1; }'

check "no sudoers file other than the fragment names the user" bash -c '
    for f in /etc/sudoers.d/*; do
        [ -f "$f" ] || continue
        [ "$f" = '"$FRAGMENT"' ] && continue
        grep -qE "^[[:space:]]*'"$TESTUSER"'[[:space:]]" "$f" && { echo "$f still names the user"; exit 1; }
    done
    echo "  only the fragment names '"$TESTUSER"'"'

check "the fragment parses -- a broken one stops sudo for everyone, root included" bash -c '
    command -v visudo >/dev/null || { echo "  no visudo in this image, skipped"; exit 0; }
    visudo -cf '"$FRAGMENT"' 2>&1 | sed "s/^/  /"'

# (ALL:ALL) would let the caller pick the target user, which buys nothing here and costs the whole
# CVE-2019-14287 class. Written as a negated grep and not a read loop: `exit 1` inside the right
# side of a pipeline exits that subshell, so a read loop would pass no matter what it found.
check "every rule targets root only, never ALL" bash -c '
    grep -v "^#" '"$FRAGMENT"' | grep -v "^$" | tee /dev/stderr \
        | grep -qv "ALL=(root) NOPASSWD:" && { echo "a rule does not target root only"; exit 1; }
    echo "  every rule is ALL=(root) NOPASSWD:"'

# ---------------------------------------------------------------------------------------------
# The policy itself. `sudo -l -U <user> <command>` asks "would this exact command line be
# permitted", which is the only question worth asking about an allowlist.
# ---------------------------------------------------------------------------------------------

check "sudo agrees the user may run only what the allowlist names" bash -c '
    sudo -l -U '"$TESTUSER"' 2>&1 | sed "s/^/  /"'

check "an allowed command, with its exact arguments, is permitted" bash -c '
    sudo -l -U '"$TESTUSER"' /usr/bin/id -u >/dev/null 2>&1 \
        || { echo "the allowlisted command is NOT permitted"; exit 1; }
    echo "  permitted: /usr/bin/id -u"'

check "the same command with a different argument is refused" bash -c '
    sudo -l -U '"$TESTUSER"' /usr/bin/id -g >/dev/null 2>&1 \
        && { echo "ARGUMENT PINNING DOES NOT HOLD"; exit 1; }
    echo "  refused: /usr/bin/id -g"'

check "the same command with no arguments is refused" bash -c '
    sudo -l -U '"$TESTUSER"' /usr/bin/id >/dev/null 2>&1 \
        && { echo "the bare command is permitted"; exit 1; }
    echo "  refused: /usr/bin/id"'

# The attack the whole feature exists to stop, asked of the policy rather than of a chmod.
check "nothing that could undo a seal is permitted" bash -c '
    for c in "/bin/chmod 666 /tmp/x" "/bin/sh" "/bin/bash -c id" "/usr/bin/tee /tmp/x" "/usr/bin/chown root /tmp/x"; do
        # shellcheck disable=SC2086
        if sudo -l -U '"$TESTUSER"' $c >/dev/null 2>&1; then echo "PERMITTED: $c"; exit 1; fi
        echo "  refused: $c"
    done'

check "the probe the feature relies on is not permitted" bash -c '
    sudo -l -U '"$TESTUSER"' /usr/bin/true >/dev/null 2>&1 && { echo "true is permitted"; exit 1; }
    sudo -l -U '"$TESTUSER"' /bin/true  >/dev/null 2>&1 && { echo "true is permitted"; exit 1; }
    echo "  refused: true"'

# ---------------------------------------------------------------------------------------------
# Fail-closed. A list that does not lint clean must leave the user with less than they asked for,
# never more -- so it degrades to a full drop, not to "restricted, minus the rejected entries".
# ---------------------------------------------------------------------------------------------

check "a list with an error is not installed, and the mode degrades to a full drop" bash -c '
    setup() { useradd -m '"$TESTUSER"' 2>/dev/null || true; }
    printf "%s ALL=(ALL) NOPASSWD:ALL\n" '"$TESTUSER"' > /etc/sudoers.d/'"$TESTUSER"'
    chmod 0440 /etc/sudoers.d/'"$TESTUSER"'
    printf "/usr/bin/id -u\n/bin/bash\n" > '"$SHARE"'/sudo-commands
    rm -f '"$FRAGMENT"'
    out=$('"$SBX"' apply-sudo 2>&1); echo "$out" | sed "s/^/  /"
    echo "$out" | grep -q "was NOT installed" || { echo "expected a refusal"; exit 1; }
    test ! -f '"$FRAGMENT"' || { echo "the rejected list was installed anyway"; exit 1; }
    test ! -f /etc/sudoers.d/'"$TESTUSER"' || { echo "the blanket grant survived the fallback"; exit 1; }
    # Not even the clean entry survives -- the fallback is a full drop, not a partial allowlist.
    sudo -l -U '"$TESTUSER"' /usr/bin/id -u >/dev/null 2>&1 \
        && { echo "the clean entry was installed on its own"; exit 1; }
    echo "  nothing is permitted"'

check "sudoAllowUnsafe installs the same list, and says so" bash -c '
    printf "%s ALL=(ALL) NOPASSWD:ALL\n" '"$TESTUSER"' > /etc/sudoers.d/'"$TESTUSER"'
    chmod 0440 /etc/sudoers.d/'"$TESTUSER"'
    sed -i "s/SUDO_ALLOW_UNSAFE=false/SUDO_ALLOW_UNSAFE=true/" '"$SHARE"'/config
    out=$('"$SBX"' apply-sudo 2>&1); echo "$out" | sed "s/^/  /"
    echo "$out" | grep -q "sudoAllowUnsafe=true" || { echo "expected the override to be announced"; exit 1; }
    test -f '"$FRAGMENT"' || { echo "the override did not install the list"; exit 1; }
    sudo -l -U '"$TESTUSER"' /bin/bash >/dev/null 2>&1 || { echo "the accepted entry is not permitted"; exit 1; }
    echo "  /bin/bash is permitted, which is exactly what the lint said it would be"'

# ---------------------------------------------------------------------------------------------

check "switching to drop removes the fragment the previous build left behind" bash -c '
    sed -i "s/SUDO_MODE=restricted/SUDO_MODE=drop/" '"$SHARE"'/config
    '"$SBX"' apply-sudo 2>&1 | sed "s/^/  /"
    test ! -f '"$FRAGMENT"' || { echo "a stale allowlist survived the switch to drop"; exit 1; }
    sudo -l -U '"$TESTUSER"' /bin/bash >/dev/null 2>&1 && { echo "still permitted after drop"; exit 1; }
    echo "  the allowlist is gone"'

check "keep changes nothing, and says so loudly" bash -c '
    printf "%s ALL=(ALL) NOPASSWD:ALL\n" '"$TESTUSER"' > /etc/sudoers.d/'"$TESTUSER"'
    chmod 0440 /etc/sudoers.d/'"$TESTUSER"'
    sed -i "s/SUDO_MODE=drop/SUDO_MODE=keep/" '"$SHARE"'/config
    out=$('"$SBX"' apply-sudo 2>&1); echo "$out" | sed "s/^/  /"
    echo "$out" | grep -q "sudoMode=keep" || { echo "expected a warning"; exit 1; }
    test -f /etc/sudoers.d/'"$TESTUSER"' || { echo "keep removed the grant anyway"; exit 1; }
    sudo -l -U '"$TESTUSER"' /bin/chmod 666 /tmp/x >/dev/null 2>&1 \
        || { echo "keep did not actually keep it"; exit 1; }
    echo "  the blanket grant is untouched, which is what keep means"'

reportResults
