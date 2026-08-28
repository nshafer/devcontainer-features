#!/usr/bin/env bash
set -e
source dev-container-features-test-lib

check "server dir exists" test -d /var/local/vscode-server

# A volume is mounted over this directory, and whether the volume root keeps the image directory's
# ownership depends on the engine. Print what it actually is, so a failure here says why.
check "server dir is writable by the remote user" bash -c '
    ls -ldn /var/local/vscode-server
    touch /var/local/vscode-server/.write-probe && rm -f /var/local/vscode-server/.write-probe'

check "~/.vscode-server is redirected out of the home volume" bash -c '
    [ "$(readlink "$HOME/.vscode-server")" = "/var/local/vscode-server" ]'
check "home is under /home so the volume covers it" bash -c 'case "$HOME" in /home/*) ;; *) exit 1;; esac'

reportResults
