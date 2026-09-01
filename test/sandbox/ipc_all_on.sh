#!/usr/bin/env bash
# All three IPC channels switched on. Two of them ship off, for reasons that are about VS Code
# rather than about security -- sealing the `code` CLI socket stops the container attaching, and
# sealing the git askpass socket stops git push. Someone who accepts both costs must still get what
# the option says, so this proves the switches reach the sweeper.
set -e
source dev-container-features-test-lib
source ./_helpers.sh

check "the options reached the config" bash -c '
    . /usr/local/share/devcontainer/sandbox/config
    [ "$BLOCK_CODE_CLI" = true ]    || { echo "codeCli: $BLOCK_CODE_CLI"; exit 1; }
    [ "$BLOCK_GIT_ASKPASS" = true ] || { echo "gitAskpass: $BLOCK_GIT_ASKPASS"; exit 1; }
    [ "$BLOCK_EXT_IPC" = true ]     || { echo "extensionIpc: $BLOCK_EXT_IPC"; exit 1; }'

check "the code cli socket is sealed" bash -c '
    sock-bind /tmp/vscode-ipc-all-on.sock
    wait-sealed /tmp/vscode-ipc-all-on.sock || { echo "not sealed"; exit 1; }
    ls -l /tmp/vscode-ipc-all-on.sock'

check "the git askpass socket is sealed" bash -c '
    sock-bind /tmp/vscode-git-all-on.sock
    wait-sealed /tmp/vscode-git-all-on.sock || { echo "not sealed"; exit 1; }
    ls -l /tmp/vscode-git-all-on.sock'

check "the extension ipc socket is sealed" bash -c '
    sock-bind /tmp/vscode-remote-containers-ipc-all-on.sock
    wait-sealed /tmp/vscode-remote-containers-ipc-all-on.sock || { echo "not sealed"; exit 1; }
    ls -l /tmp/vscode-remote-containers-ipc-all-on.sock'

# The other direction of the same switch: with every channel blocked, every variable goes too.
check "the scrub covers all three channels" bash -c '
    out=$(GIT_ASKPASS=/tmp/a.sh VSCODE_IPC_HOOK_CLI=/tmp/i.sock REMOTE_CONTAINERS_IPC=/tmp/e.sock \
        bash -c "echo askpass=[\$GIT_ASKPASS] ipc=[\$VSCODE_IPC_HOOK_CLI] ext=[\$REMOTE_CONTAINERS_IPC]")
    echo "$out"
    echo "$out" | grep -q "askpass=\[\] ipc=\[\] ext=\[\]"'

check "the report says blocked for all three" bash -c '
    out=$(sandbox-status || true)
    echo "$out"
    echo "$out" | grep -qE "code cli +blocked"
    echo "$out" | grep -qE "git askpass +blocked"
    echo "$out" | grep -qE "extension ipc +blocked"'

reportResults
