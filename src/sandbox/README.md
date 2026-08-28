
# Sandbox (nshafer) (sandbox)

Cuts the host sockets VS Code forwards into a dev container - SSH agent, GPG agent, X11 and the VS Code IPC channels - so a coding agent running inside cannot sign with your keys, spend your GitHub token or reach your desktop.

## Example Usage

```json
"features": {
    "ghcr.io/nshafer/devcontainer-features/sandbox:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| blockSshAgent | Block the forwarded SSH agent (/tmp/vscode-ssh-auth-*.sock). Your host SSH keys stop being usable from inside, so git over SSH stops working there. | boolean | true |
| blockGpgAgent | Block the forwarded GPG agent (~/.gnupg/S.gpg-agent), by making ~/.gnupg itself root-owned and unwritable. Signed commits stop working inside the container. | boolean | true |
| blockX11 | Block the forwarded display (/tmp/.X11-unix), by making that directory root-owned and unwritable so no X socket can be created in it. GUI apps stop reaching your desktop. Wayland cannot be blocked from inside - see the README. | boolean | true |
| blockVscodeIpc | Block the VS Code IPC channels: vscode-ipc-* (the 'code' CLI), vscode-git-* (the git credential helper, which hands out the host's GitHub token) and vscode-remote-containers-ipc-* (the extension's own channel). Breaks 'code .' from the terminal and VS Code's git authentication. | boolean | true |
| scrubEnv | Also unset the variables that advertise these sockets (SSH_AUTH_SOCK, DISPLAY, GIT_ASKPASS, BROWSER, VSCODE_IPC_HOOK_CLI, REMOTE_CONTAINERS_*) in every shell. Cosmetic next to the socket blocks - VS Code re-injects them - but it stops tools finding the paths by accident. | boolean | true |
| sweepInterval | Seconds between sweeps by the root daemon. Each sweep is one find over /tmp and /run. | string | 1 |



---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nshafer/devcontainer-features/blob/main/src/sandbox/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
