
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

## Host setup

None on the filesystem. This feature mounts nothing from the host, so you create no path before the
first build.

But the feature is mitigation, not a boundary (see below), and the fixes that fully close the
forwarded channels are host-side. Set these on any machine that runs an agent in the container:

- Unset `SSH_AUTH_SOCK` and `DISPLAY` in the environment that starts VS Code. Nothing is forwarded,
  so there is nothing to race.
- Turn off the Wayland mount in VS Code user settings:

  ```jsonc
  "dev.containers.mountWaylandSocket": false
  ```

- Run the agent as a different Unix user than the remote user, if you can. A second user cannot
  connect to a forwarded socket at all.

Keep `dropSudo` on. Without it, the rest of the feature is decorative.

## What this feature does

VS Code's Dev Containers extension forwards a set of host sockets into every container it starts.
Each socket is a capability that an agent in the container inherits. This is measured from a live
container, not assumed. The extension writes the list into `REMOTE_CONTAINERS_SOCKETS` itself:

| Channel | Path | What it grants |
| --- | --- | --- |
| SSH agent | `/tmp/vscode-ssh-auth-<uuid>.sock` | signing with your host SSH keys |
| GPG agent | `~/.gnupg/S.gpg-agent` | signing with your host GPG keys |
| X11 | `/tmp/.X11-unix/X<n>` | your desktop: keystrokes, screenshots |
| GPG keyboxd | `~/.gnupg/S.keyboxd` | your keyring |
| git credentials | `$XDG_RUNTIME_DIR/vscode-git-<id>.sock` | your GitHub token, via `GIT_ASKPASS` |
| `code` CLI | `vscode-ipc-<uuid>.sock` | driving your editor |
| extension IPC | `vscode-remote-containers-ipc-<uuid>.sock` | the extension's own channel to the host |
| Wayland | `/tmp/vscode-wayland-<uuid>.sock` | your desktop — **a bind mount**, see below |

This feature seals those sockets and removes the remote user's sudo grant, so the seals hold.

## What this actually buys you — read this first

**This is mitigation, not a boundary.** It makes the forwarded channels hard to reach by accident
and awkward to reach on purpose. It does not make them unreachable. Nothing installed *inside* the
container can, because the hole is in how VS Code forwards them.

The reason is structural. VS Code's helper runs **as the remote user** and calls
`net.Server.listen()` on a socket inside the container. Anything else that runs as that user may
`connect()` to it. The socket has to exist. A path the helper cannot write is a container you cannot
attach to. Block the path, and the helper fails like this:

```
Container server: Error: listen EACCES: permission denied /tmp/.X11-unix/X0
```

So the socket appears, and this feature takes it. Between those two moments it is live and usable.
This is measured against a socket forwarded the way VS Code forwards one, with an attacker looping
on `connect()`:

| sealing driven by | usable connections before the seal | window |
| --- | --- | --- |
| the 1s poll alone | 15,299 | 993 ms |
| inotify (the default) | **7** | **5 ms** |

inotify is a ~2,000× reduction, and it is why the feature installs `inotify-tools`. It is still not
zero, and **one connection is enough** to have your host's `ssh-agent` sign something. The window
reopens on every window you attach, not only the first.

**All of that rests on the remote user not being root.** A stock dev container hands them
password-less sudo, and one `sudo chmod 666` undoes every seal here. So the feature removes the
grant (`dropSudo`, on by default). It deletes the `sudoers.d` entry, drops the user from
`sudo`/`wheel`/`admin`, then *verifies by outcome* and strips the setuid bit from `sudo` if any
route survived. **This is the change that turns the rest from theatre into something an agent has to
work around rather than switch off.** It also means `sudo` stops working in the container, for you
too.

What the feature *does* hold: once sealed, a UUID-named socket is closed for good. `/tmp` is sticky,
so the remote user cannot remove a root-owned file in it at all. Recreating one gets you a socket
bound to your own process with nothing behind it, because the forwarding lives in the helper
process, not in the file. So opportunistic use, tools that stumble onto `SSH_AUTH_SOCK`, and an
agent that does not specifically race the seal all fail.

**The only fixes that actually close it are outside this feature** — see the host setup above. Treat
this feature as a seatbelt for a coding agent that does something careless, not armour against one
that was told to go looking.

## How the seals work

The feature closes the channels with three mechanisms, in descending order of how much they are
worth.

**Sealing beats deleting.** The obvious move is to delete the sockets, but deleting frees the path
and VS Code puts a working one back. That is why approaches built on `find -delete` need a
background loop that re-deletes every 30 seconds. This feature takes the socket instead, `chown
root:root` plus `chmod 000`, and that closes three doors at once:

| | after `rm` | after sealing |
| --- | --- | --- |
| agent connects | recreated, works | `EACCES` |
| agent deletes it | n/a | `EPERM` — `/tmp` is sticky and the file is root's |
| VS Code recreates it | yes | `EADDRINUSE` |

**Everything is sealed after the fact, never preempted.** The obvious refinement is to make the
directories these sockets live in — `/tmp/.X11-unix` and `~/.gnupg` — root-owned and read-only, so
the socket can never be created. That is a stronger boundary, and it works, but it makes the
container impossible to open. VS Code's helper creates those sockets while attaching, fails, and
dies. It leaves **"Configuring Dev Container" on screen forever**, with no error and no timeout. So
the feature lets the forwarding succeed and takes the channel a moment later. Blocking that starts a
second late beats blocking that never lets you open the editor. `test/sandbox/test.sh` checks that
the directories stay writable before it checks anything else.

The cost is stated rather than hidden. With the directory writable, the user who owns that directory
can unlink a tombstone inside it. So the fixed-name channels — X11 and GPG — are open for the moment
between the helper creating the socket and inotify firing, rather than never. The UUID-named
channels keep the stronger guarantee, because `/tmp` is sticky and the user cannot remove a
root-owned file in it at all.

**The rest needs a daemon, not a bounded loop.** The remaining names carry a fresh UUID per window,
so every VS Code window you attach forwards a whole new set, hours after the first. A loop that runs
ten passes and stops has stopped covering you. The feature's `entrypoint` runs as root before VS
Code attaches and leaves a sweeper behind for the life of the container.

## Some things worth knowing

**Wayland cannot be blocked from inside, and you must not try.** It is not a socket VS Code creates
in the container. It is a bind mount of the host's `/run/user/<uid>/wayland-0`. You cannot remove it
(`EBUSY`) or unmount it (no `CAP_SYS_ADMIN`), and **permission changes on a bind mount write through
to the source**. So sealing it would set mode `000` on the socket your own desktop session runs on.
Every mutation in the feature is gated on a `/proc/self/mountinfo` check for exactly this reason,
and `test/sandbox/wayland_bind_mount.sh` shows the write-through happening and then proves the guard
stops it. The only real fix is host-side, in the host setup above.

**Depth 3, not 2.** `XDG_RUNTIME_DIR` in a dev container is `/tmp/user/<uid>`, and the git
credential socket — the one that hands out your GitHub token — lives there. A sweep two levels deep
looks thorough and silently leaves it open.

**The manifest is reported on, never acted on.** `REMOTE_CONTAINERS_SOCKETS` is the authoritative
list of what was forwarded, so a channel these globs do not know about still gets surfaced. The
unprivileged `postStart`/`postAttach` hooks check it rather than root sweeping it, for two reasons.
Root cannot read another user's `/proc/<pid>/environ` without `CAP_SYS_PTRACE`, which Docker does
not grant — and a feature that granted it would hand the remote user the ability to ptrace the very
daemon doing the hardening. Nor should root `chmod 000` a path named by something the remote user
controls, because that turns the feature into a denial-of-service primitive against `/etc/passwd`.
So a new channel gets you a warning, not silence, and not an exploit.

**The env scrub is the weakest layer and is not a control.** VS Code re-injects `SSH_AUTH_SOCK`,
`GIT_ASKPASS` and friends into everything it starts, and any program can read a path back out of
`/proc`. The sockets being unusable is the control. The scrub is wired in at `/etc/profile.d`,
`/etc/bash.bashrc`, `/etc/zsh/zshenv` and `BASH_ENV`, all in `/etc`, never in `$HOME`. The reason is
`persist-homedir`: it puts `/home` on a volume that masks whatever the image wrote to `~/.bashrc`,
so a scrub installed there works exactly once and then stops.

Check the result at any time. It exits non-zero if anything is still reachable:

```console
$ sandbox-status
sandbox: forwarded host channels in this container
  ssh agent        blocked
  gpg agent        blocked
  x11 display      blocked
  vscode ipc       blocked
  sweeper          running (inotify, 1s poll backstop)
```

**`no-new-privileges` is not part of the feature**, though it pairs well with it. A feature's
`securityOpt` is static metadata and cannot depend on an option, so shipping it would force it on
every container and break `sudo` everywhere. It is one line in `devcontainer.json` when you want it.
Note that `capDrop` has no equivalent at all, feature or otherwise:

```jsonc
"securityOpt": ["no-new-privileges"]
```

Finally, the feature is only as good as the container's user model. **It does nothing if
`remoteUser` is root**, since root can `chmod` any tombstone back. `install.sh` says so loudly when
it detects that.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
