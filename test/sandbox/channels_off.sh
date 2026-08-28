#!/usr/bin/env bash
# Every switch off. Proves the options are consulted rather than decorative: a feature that hardens
# regardless of what you asked for is one nobody can adopt a channel at a time.
set -e
source dev-container-features-test-lib
source ./_helpers.sh


check "the options reached the config" bash -c '
    . /usr/local/share/nshafer-sandbox/config
    [ "$BLOCK_SSH" = false ]  || { echo "ssh: $BLOCK_SSH"; exit 1; }
    [ "$BLOCK_GPG" = false ]  || { echo "gpg: $BLOCK_GPG"; exit 1; }
    [ "$BLOCK_X11" = false ]  || { echo "x11: $BLOCK_X11"; exit 1; }
    [ "$BLOCK_IPC" = false ]  || { echo "ipc: $BLOCK_IPC"; exit 1; }
    [ "$SWEEP_INTERVAL" = 5 ] || { echo "interval: $SWEEP_INTERVAL"; exit 1; }'

check "a display socket is not touched" bash -c '
    mkdir -p /tmp/.X11-unix
    sock-bind /tmp/.X11-unix/X9
    sudo -n /usr/local/share/nshafer-sandbox/sandbox.sh sweep
    ls -l /tmp/.X11-unix/X9
    [ "$(stat -c %a /tmp/.X11-unix/X9)" != 0 ] || { echo "sealed despite blockX11=false"; exit 1; }'

check "a gpg agent socket is not touched" bash -c '
    mkdir -p -m 700 "$HOME/.gnupg"
    sock-bind "$HOME/.gnupg/S.gpg-agent"
    sudo -n /usr/local/share/nshafer-sandbox/sandbox.sh sweep
    ls -l "$HOME/.gnupg/S.gpg-agent"
    [ "$(stat -c %a "$HOME/.gnupg/S.gpg-agent")" != 0 ] \
        || { echo "sealed despite blockGpgAgent=false"; exit 1; }'

check "a forwarded ssh socket is not touched" bash -c '
    sock-bind /tmp/vscode-ssh-auth-off.sock
    sudo -n /usr/local/share/nshafer-sandbox/sandbox.sh sweep
    ls -l /tmp/vscode-ssh-auth-off.sock
    [ "$(stat -c %a /tmp/vscode-ssh-auth-off.sock)" != 0 ] \
        || { echo "sealed despite blockSshAgent=false"; exit 1; }
    echo "left reachable, as configured"'

check "a vscode ipc socket is not touched" bash -c '
    sock-bind /tmp/vscode-ipc-off.sock
    sudo -n /usr/local/share/nshafer-sandbox/sandbox.sh sweep
    [ "$(stat -c %a /tmp/vscode-ipc-off.sock)" != 0 ] \
        || { echo "sealed despite blockVscodeIpc=false"; exit 1; }'

check "scrubEnv=false wires nothing into the shells" bash -c '
    ! test -e /etc/profile.d/00-nshafer-sandbox.sh
    ! grep -q nshafer-sandbox /etc/bash.bashrc 2>/dev/null
    ! grep -q nshafer-sandbox /etc/zsh/zshenv 2>/dev/null'

# BASH_ENV is containerEnv, which is static metadata and cannot be conditional on an option -- so
# it is still set. The file it names is still installed, so sourcing it is harmless; it just is not
# reached from any of the shell rc files.
check "BASH_ENV is still set, since containerEnv cannot be conditional" bash -c '
    [ "$BASH_ENV" = /usr/local/share/nshafer-sandbox/scrub-env.sh ] || { echo "BASH_ENV: $BASH_ENV"; exit 1; }
    test -r "$BASH_ENV"'

check "the report says unblocked rather than claiming success" bash -c '
    out=$(sandbox-report || true)
    echo "$out"
    echo "$out" | grep -qE "ssh agent +not blocked \(option is off\)"
    echo "$out" | grep -qE "gpg agent +not blocked \(option is off\)"
    echo "$out" | grep -qE "x11 display +not blocked \(option is off\)"
    echo "$out" | grep -qE "vscode ipc +not blocked \(option is off\)"'

reportResults
