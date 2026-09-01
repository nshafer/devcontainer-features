## Upgrading from 1.x

`blockVscodeIpc` is gone. It covered three sockets that are not equivalent, and one of those
sockets cannot be sealed without stopping the container from attaching. Three options replace it:

| Was | Is now | Default |
| --- | --- | --- |
| `blockVscodeIpc` → `vscode-ipc-*.sock` | `blockCodeCli` | `false` |
| `blockVscodeIpc` → `vscode-git-*.sock` | `blockGitAskpass` | `false` |
| `blockVscodeIpc` → `vscode-remote-containers-ipc-*.sock` | `blockExtensionIpc` | `true` |

The CLI warns about an option it does not know, so a `devcontainer.json` that still sets
`blockVscodeIpc` builds and gets the new defaults. To keep 1.x behaviour exactly, set all three to
`true` — and read the section on `vscode-ipc-*.sock` below first, because that is the setting that
hangs the attach.

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

The feature takes away the remote user's blanket sudo grant, which closes the hole that matters: a
remote user who regains root undoes every seal. Add `no-new-privileges` yourself as a second lock —
the feature does not set it, because it cannot be conditional and it breaks restricted sudo. See
the sudo section below.

## Rootless Docker and Podman

The seals hold. Every one of them is a `chown root` and a `chmod 000` **inside** the container, and
inside a rootless container root is still root — it owns the user namespace the container runs in.
The sudo drop holds for the same reason. Nothing in this feature asks the host for a capability.

What changes is the reason to use it, and the change is smaller than it looks. Under a rootless
runtime, a process that breaks out of the container lands on your unprivileged host account rather
than on host root. That closes one path and leaves this feature's path open: VS Code still forwards
your SSH agent, your GPG agent, your display and your GitHub token into the container, and those
sockets answer to anything inside it. A rootless runtime does not make a forwarded credential any
less forwarded. Read [what this actually buys you](#what-this-actually-buys-you--read-this-first)
again with that in mind — the numbers there do not move.

Two things to check on your own host:

- **The `userns` flag.** Podman with `--userns=keep-id` maps your host uid into the container and
  renumbers everything else. The seals assume a mapped root. Build one container with the exact
  flag you plan to use, then read `/var/log/devcontainer/sandbox.log` and confirm each block
  reports success.
- **SELinux.** On Fedora and RHEL, a socket VS Code forwards through a bind mount is already
  labelled by the runtime. This feature leaves a bind mount alone rather than sealing it, and says
  so in the log, so SELinux changes what the report says and not what the feature does.

## What this feature does

VS Code's Dev Containers extension forwards a set of host sockets into every container it starts.
Each socket is a capability that an agent in the container inherits. This is measured from a live
container, not assumed. The extension writes the list into `REMOTE_CONTAINERS_SOCKETS` itself:

| Channel | Path | Option | Default | What it grants |
| --- | --- | --- | --- | --- |
| SSH agent | `/tmp/vscode-ssh-auth-<uuid>.sock` | `blockSshAgent` | blocked | signing with your host SSH keys |
| GPG agent | `~/.gnupg/S.gpg-agent` | `blockGpgAgent` | blocked | signing with your host GPG keys |
| GPG keyboxd | `~/.gnupg/S.keyboxd` | `blockGpgAgent` | blocked | your keyring |
| X11 | `/tmp/.X11-unix/X<n>` | `blockX11` | blocked | your desktop: keystrokes, screenshots |
| extension IPC | `vscode-remote-containers-ipc-<uuid>.sock` | `blockExtensionIpc` | blocked | RPC to the extension on your host, including every credential your host stores |
| git credentials | `$XDG_RUNTIME_DIR/vscode-git-<id>.sock` | `blockGitAskpass` | **open** | your GitHub token, via `GIT_ASKPASS` |
| `code` CLI | `vscode-ipc-<uuid>.sock` | `blockCodeCli` | **open** | driving your editor, and opening a URI on your host desktop |
| Wayland | `/tmp/vscode-wayland-<uuid>.sock` | none | open | your desktop — **a bind mount**, see below |

This feature seals those sockets and removes the remote user's sudo grant, so the seals hold. Two
of them ship open, and the next two sections say why, because in both cases the reason is about
what VS Code needs rather than about what the channel costs you.

### The three IPC channels are not one channel

They used to share an option, `blockVscodeIpc`. They are not equivalent. Measured from the
container server's own source, `/tmp/vscode-remote-containers-server-<uuid>.js`, and from the
server CLI in `~/.vscode-server/bin/<commit>/out/server-cli.js`:

| Socket | Reaches the host? | What it grants | What blocking it breaks |
| --- | --- | --- | --- |
| `vscode-ipc-*.sock` | through the editor UI | four message types — `open`, `status`, `extensionManagement`, and `openExternal`, which opens any URI with your **host** desktop's handler | `code .`, `code --wait` as `core.editor`, **and the attach itself** |
| `vscode-git-*.sock` | yes, through the git extension | your host's GitHub token, for a host name the caller picks. VS Code prompts only for a host it has no session for | `git push`, `pull` and `fetch` over HTTPS, in the UI and in the terminal |
| `vscode-remote-containers-ipc-*.sock` | yes, directly | an HTTP `POST` on it calls `rpc` on the extension **on your host**. Git uses it as `credential.helper`, so it answers for every host in your host's credential store, with no prompt | the host credential helper, and host docker registry logins |

`blockExtensionIpc` is on by default because it is the broadest of the three, and because the
narrower credential channel covers push and pull on its own. If you want no host credential
reachable at all, set `blockGitAskpass` to `true` as well and authenticate some other way.

### Why `vscode-ipc-*.sock` ships open

It is not only the `code` CLI. The VS Code server registers its own channels on one of those
paths, and it deletes the file when it disposes the hook — with nothing around the call:

```js
dispose() { ...; this._ipcHandlePath && existsSync(this._ipcHandlePath) && unlinkSync(this._ipcHandlePath) }
```

A tombstone is root-owned and `/tmp` is sticky, so that `unlinkSync` cannot succeed. It throws,
and the throw surfaces in `~/.vscode-server/data/logs/*/remoteagent.log` as:

```
[error] Error: EPERM: operation not permitted, unlink '/tmp/vscode-ipc-<uuid>.sock'
    at Module.unlinkSync ... at Eh.dispose ...
```

The window then sits on "Configuring Dev Container" for good, with an empty log. This is the same
shape of failure as the 1.0.0 directory bug below, and it has the same root cause: a tombstone is
permanent by design, so it cannot coexist with a component that unlinks and rebinds its own path.
Nothing inside the container can fix it. `blockCodeCli` is there for anyone who accepts the cost.

### Two paths ask for a credential, not one

`git push` over HTTPS fails through both of them when both are sealed, and the log names each one:

```
> git push origin main:main
Unable to connect to VS Code Dev Containers extension.
Error in request Error: connect EACCES /tmp/vscode-remote-containers-ipc-<uuid>.sock
Missing or invalid credentials.
Error: connect EACCES /tmp/vscode-git-<id>.sock
```

The first line is `credential.helper`, which VS Code writes into `/etc/gitconfig`. The second is
`GIT_ASKPASS`. Either one alone is enough to authenticate a push, so the defaults open the
narrower one and keep the broader one shut.

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
password-less sudo, and one `sudo chmod 666` undoes every seal here. So the feature takes the
blanket grant away. It deletes the `sudoers.d` entry, drops the user from `sudo`/`wheel`/`admin`,
then *verifies by outcome* and strips the setuid bit from `sudo` if any route survived. **This is
the change that turns the rest from theatre into something an agent has to work around rather than
switch off.** It also means `sudo` stops working in the container, for you too.

That is `sudoMode: "drop"`, the default. Two other modes exist, and the sudo section below is the
one part of this README worth reading before you use either.

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

**Depth 3, not 2.** `XDG_RUNTIME_DIR` in a dev container is `/tmp/user/<uid>`, and a forwarded
socket can live there rather than directly in `/tmp` — the git credential socket, the one that
hands out your GitHub token, is the usual example. A sweep two levels deep looks thorough and
silently leaves it open.

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

**The scrub follows the blocks, one channel at a time.** `install.sh` generates the list at build
time and writes one `unset` line per *blocked* channel. For an open channel the variable stays,
because there the scrub would not be cosmetic — a terminal with no `GIT_ASKPASS` cannot
authenticate a push however reachable the socket is, and a terminal with no `VSCODE_IPC_HOOK_CLI`
has no working `code`.

Check the result at any time. It exits non-zero if anything is still reachable:

```console
$ sandbox-status
sandbox: forwarded host channels in this container
  ssh agent        blocked
  gpg agent        blocked
  x11 display      blocked
  code cli         not blocked (option is off)
  git askpass      not blocked (option is off)
  extension ipc    blocked
  sudo             dropped
  no-new-privs     not set -- add "securityOpt": ["no-new-privileges"] in devcontainer.json
  sweeper          running (inotify, 1s poll backstop)
```

In restricted mode it lists the allowlist rather than counting it, because the list is the boundary
and nobody can audit a number:

```console
  sudo             restricted -- blanket grant gone, 2 command(s) allowed
                     /bin/systemctl restart myapp
                     /usr/sbin/nginx -s reload
  no-new-privs     not set (sudoMode=restricted needs it unset)
```

## sudo: the three modes, and what each one costs

Every seal this feature makes is a root-owned file. A remote user who can become root undoes all of
them with one command, so what happens to their sudo grant *is* the feature. Set it with `sudoMode`.

| `sudoMode` | What the remote user can run as root | Use it when |
| --- | --- | --- |
| `drop` (default) | Nothing. The grant goes, and the setuid bit goes with it if anything survived. | Almost always. |
| `restricted` | Only the exact command lines in `sudoCommands`, and only as root. | A project genuinely needs one or two root commands. |
| `keep` | Everything. This feature becomes decoration. | Never, knowingly. |

**`no-new-privileges` cannot be set by this feature.** The flag blocks every setuid path, so it adds a
second lock: a setuid binary the drop misses still cannot hand back root. It blocks `sudo` for
*everyone*, though, restricted included — and a feature cannot set an option conditionally, because
`devcontainer-feature.json` is static metadata with no way to read an option value. So restricted
mode and a feature-supplied flag cannot both exist. The flag moves to your `devcontainer.json`,
where you add it yourself when you use `drop`:

```jsonc
"securityOpt": ["no-new-privileges"]
```

Add it. `sandbox-status` tells you whether it is set, and nags in `drop` mode when it is not. Note
that `capDrop` has no feature-level equivalent at all.

**The flag reaches inside a nested Docker daemon, and cannot be cleared.** The kernel passes
`no_new_privs` to every child process and never clears it. So a `docker-in-docker` daemon in a
container that carries the flag hands it to every container it starts. `sudo` in those containers
fails with *"the no new privileges flag is set"*, whatever their own `securityOpt` says — and so
does restricted mode, for the same reason. Give the process the root it needs by name — a
`remoteUser` of `root`, or `docker run -u root` — rather than by a setuid binary.

### Restricted mode

The blanket grant still goes. In its place the feature writes `/etc/sudoers.d/900-sandbox-restricted`
— one line per entry, root as the only target user, arguments pinned exactly as you wrote them:

```jsonc
"sudoMode": "restricted",
"sudoCommands": "/bin/systemctl restart myapp,/usr/sbin/nginx -s reload"
```

Rules the generator holds to, and why each one:

- **Root only, never `(ALL:ALL)`.** Letting the caller pick the target user buys nothing here and
  costs the whole runas bug class, CVE-2019-14287 included.
- **Arguments are pinned.** `sudo -l /usr/bin/id -u` is permitted and `sudo -l /usr/bin/id -g` is
  not. A sudoers entry with no arguments permits *every* argument, which is the single most common
  way an allowlist turns out to be a blanket grant.
- **The file is validated with `visudo` before it is installed.** A syntax error in a `sudoers.d`
  fragment does not fail that fragment. It makes `sudo` refuse to run at all, for everyone, root
  included.
- **It is rewritten at every container start,** like the rest of the feature, because a later
  feature or a project's `postCreate` can put a blanket grant back.

**The allowlist becomes the trust boundary of the whole feature.** Any command in it that can write
a file or start a program undoes every seal above. That is not a caveat, it is the deal.

### The lint

`sudoCommands` is checked at build time and the build **fails** on anything that reads as a route
back to full root. Every rule below is a real escape that a careful reviewer misses, not a style
rule. Run one by hand at any time:

```console
$ sandbox.sh lint-sudo '/usr/sbin/iptables'
error: iptables with no arguments permits every argument, and it rewrites the firewall, which
       switches off the egress-filter feature entirely
```

Rejected outright:

| What | Why |
| --- | --- |
| A relative path — `systemctl restart x` | The caller owns `PATH`, so the caller picks the binary. |
| A wildcard — `systemctl reboot *` | A sudoers wildcard is a glob. It matches `/` and spans arguments, so `chmod 666 /tmp/*` permits `chmod 666 /tmp/../etc/shadow`. |
<!-- The dollar below is written as ` $ ` on purpose. generate-docs builds the README with a
     JavaScript String.replace, and a dollar followed by a backtick is a replacement pattern
     there: it means "everything before the match", so one plain dollar in a code span injects
     a whole second copy of the template into this table. A code span with spaces around it
     renders identically and puts a space after the dollar instead. -->
| Shell syntax — `;` `&&` `\|` `` ` `` ` $ ` `<` `>` quotes | `sudo` execs the command. It never runs a shell, so `/bin/foo; rm -rf /` is one entry, not two. |
| `!` | sudoers command negation denies a *path*. The same binary copied elsewhere is a different path. |
| A shell or interpreter — `sh`, `bash`, `python3`, `perl`, `awk`, `node` | Runs anything as root, pinned or not. |
| A command that runs a command — `env`, `xargs`, `find`, `timeout`, `nohup`, `watch`, `systemd-run` | Same, one step removed. |
| An editor or pager — `vim`, `less`, `man`, `nano` | Shell escape. `:!sh`. |
| A privilege tool — `su`, `chroot`, `unshare`, `nsenter`, `setcap`, `passwd`, `usermod`, `mount` | Edits the privilege model itself. |
| A container runtime — `docker`, `podman`, `runc`, `ctr` | A container mounts the host filesystem as root. |
| A debugger — `gdb`, `strace` | Drives another process as root. |
| `needrestart` | A known local root escalation — CVE-2024-48990 and siblings. It reads a poisoned `PYTHONPATH` out of an *unrelated* running process, so sudo's `env_reset` does not stop it. |
| `true`, `false`, `:` | The feature runs `sudo -n true` to prove the blanket grant is gone. |
| A binary, or any directory above it, that is not root-owned or is group/other writable | Whoever can write it, or write any directory on the way to it, chooses what `sudo` runs. |
| Any of the *pin-sensitive* list below **with no arguments** | No arguments means every argument. |

Warned about, and allowed — an entry is only as safe as the exact arguments you pinned:

| What | Why it is only as safe as its arguments |
| --- | --- |
| `cp`, `mv`, `tee`, `dd`, `install`, `ln`, `chmod`, `chown` | Writes or re-owns whatever you named. A `cp` whose *source* the remote user can write is a root-owned copy of their content. |
| `tar`, `unzip`, `rsync`, `scp` | Writes whatever path the archive or the far side names. |
| `systemctl`, `service` | Starts, stops or masks a unit. And a unit file the remote user can write plus an allowed `daemon-reload` is root. |
| `apt-get`, `dpkg`, `pip`, `npm`, `gem` | Installing a package runs its maintainer scripts as root. |
| `git`, `curl`, `ssh`, `socat` | Runs or fetches what the far side chooses. |
| `journalctl`, `dmesg` | Pipes to a pager, and the pager has a shell escape. Pin `--no-pager`. |
| `iptables`, `nft`, `ipset`, `ip`, `tc`, `ufw` | Rewrites the firewall, which switches off the `egress-filter` feature in this same repo completely. |

If you have read a finding and decided it is wrong or acceptable, set `sudoAllowUnsafe: true`. It
downgrades every error to a warning and installs the list anyway. Nothing else changes: the findings
still print, at build time and at every container start.

**It fails closed, and all the way.** A list that does not lint clean is not installed, and the mode
degrades to a full `drop` — not to "restricted, minus the rejected entries". You asked for a smaller
grant than `drop`, so the safe direction to be wrong in is a smaller one still. `sandbox-status`
says so plainly when this happens.

**There is no way to read the list from a file in the workspace,** and there will not be. The
workspace is writable by the remote user, so a sudoers list read from it would be a self-service
root grant. `sudoCommands` is a build-time option only.

Finally, the feature is only as good as the container's user model. **It does nothing if
`remoteUser` is root**, since root can `chmod` any tombstone back. `install.sh` says so loudly when
it detects that.
