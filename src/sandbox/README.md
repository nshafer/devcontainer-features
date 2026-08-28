
# Sandbox (nshafer) (sandbox)

Seals the host sockets VS Code forwards into a dev container - SSH agent, GPG agent, X11 and the VS Code IPC channels - and removes the remote user's sudo grant so the seals cannot simply be undone. Mitigation, not a boundary: the socket must exist for the container to attach, so there is a short window at each attach. See the README.

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
| blockGpgAgent | Block the forwarded GPG agent (~/.gnupg/S.gpg-agent, .extra and S.keyboxd), by sealing the sockets just after VS Code creates them. Signed commits stop working inside the container. | boolean | true |
| blockX11 | Block the forwarded display (/tmp/.X11-unix/X*). The socket is sealed just after VS Code creates it, not pre-empted -- pre-empting it stops the container attaching at all. GUI apps stop reaching your desktop. Wayland cannot be blocked from inside - see the README. | boolean | true |
| blockVscodeIpc | Block the VS Code IPC channels: vscode-ipc-* (the 'code' CLI), vscode-git-* (the git credential helper, which hands out the host's GitHub token) and vscode-remote-containers-ipc-* (the extension's own channel). Breaks 'code .' from the terminal and VS Code's git authentication. | boolean | true |
| dropSudo | Remove the remote user's passwordless sudo grant. Without this the whole feature is decorative - a stock dev container lets the user run 'sudo chmod 666' on any sealed socket and undo it. Turning it off leaves sudo alone, and leaves every block below undoable by anything running in the container. | boolean | true |
| scrubEnv | Also unset the variables that advertise these sockets (SSH_AUTH_SOCK, DISPLAY, GIT_ASKPASS, BROWSER, VSCODE_IPC_HOOK_CLI, REMOTE_CONTAINERS_*) in every shell. Cosmetic next to the socket blocks - VS Code re-injects them - but it stops tools finding the paths by accident. | boolean | true |
| sweepInterval | Seconds between backstop sweeps. Sealing is normally driven by inotify, within about a millisecond of a socket appearing; this poll only catches what inotify missed, so it rarely needs changing. | string | 1 |



---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nshafer/devcontainer-features/blob/main/src/sandbox/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
