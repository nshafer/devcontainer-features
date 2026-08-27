#!/usr/bin/env bash
set -e
source dev-container-features-test-lib

check "server dir exists" test -d /var/local/vscode-server
check "server dir is owned by the remote user" bash -c '[ -w /var/local/vscode-server ]'
check "~/.vscode-server is redirected out of the home volume" bash -c '
    [ "$(readlink "$HOME/.vscode-server")" = "/var/local/vscode-server" ]'
check "home is under /home so the volume covers it" bash -c 'case "$HOME" in /home/*) ;; *) exit 1;; esac'

reportResults
