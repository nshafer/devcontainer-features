
# Sandbox (nshafer) (sandbox)

Blocks the host channels that VS Code forwards into a dev container: the SSH agent, the GPG agent, the X11 display, the git credentials and the Dev Containers extension socket. Also removes sudo from the remote user, so a program in the container cannot open the channels again. This is a mitigation, not a security boundary.

## Example Usage

```json
"features": {
    "ghcr.io/nshafer/devcontainer-features/sandbox:3": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| blockSshAgent | Block the forwarded SSH agent (/tmp/vscode-ssh-auth-*.sock). Git over SSH with your host keys then fails in the container. | boolean | true |
| blockGpgAgent | Block the forwarded GPG agent (~/.gnupg/S.gpg-agent, .extra and S.keyboxd). Signed commits with your host keys then fail in the container. | boolean | true |
| blockX11 | Block the forwarded X11 display (/tmp/.X11-unix/X*). GUI apps in the container then cannot open a window on your desktop. Wayland cannot be blocked from inside the container. Read the README. | boolean | true |
| blockCodeCli | Block the 'code' CLI socket (vscode-ipc-*.sock). Off by default, because a block on this socket stops the container from attaching: the VS Code server deletes the path when it shuts the channel down, and a file that root owns makes the delete fail. While the channel is open, a program in the container can open a VS Code window on any host path, install extensions, and give a URI to an app on your host. Turn it on only if you accept that the container does not attach. | boolean | false |
| blockGitAskpass | Block the git credential socket (vscode-git-*.sock, reached through GIT_ASKPASS). On by default, together with blockExtensionIpc, so no host credential is reachable from the container. Git push, pull and fetch over HTTPS then fail, in the VS Code interface and in the terminal. Run 'gh auth login' in the container to get a login of its own. Set this to false to use the token of your host instead. | boolean | true |
| blockExtensionIpc | Block the Dev Containers extension socket (vscode-remote-containers-ipc-*.sock). The socket answers for every host in the credential store of your host, with no prompt, and git uses it as credential.helper. A block also costs your host Docker registry logins. | boolean | true |
| scrubEnv | Unset the variables that name the blocked sockets (SSH_AUTH_SOCK, DISPLAY, GIT_ASKPASS, BROWSER, VSCODE_IPC_HOOK_CLI, REMOTE_CONTAINERS_*) in every shell. Only for the channels that are blocked. This is not a control, because VS Code sets them again, but it stops a tool from finding a path by accident. | boolean | true |
| sweepInterval | Seconds between the backup scans for new sockets. inotify seals a socket about a millisecond after it appears, so this poll catches only what inotify missed. | string | 1 |
| sudoMode | What happens to the sudo grant of the remote user. 'drop' removes it, and removes everything that could restore it. This is the default, and the only mode where every block holds. 'restricted' removes the blanket grant and installs the checked list in sudoCommands. 'keep' changes nothing, which leaves this feature with nothing to protect. The name is sudoMode and not sudo, because a feature option becomes an environment variable in the image, and SUDO=drop would break the common '$SUDO apt-get install' pattern. | string | drop |
| sudoCommands | The commands that the remote user can run as root when sudoMode is 'restricted', comma separated. Each one needs an absolute path and exact arguments: '/bin/systemctl restart myapp,/usr/sbin/nginx -s reload'. The build checks each entry and fails on a route back to full root, such as a shell, an interpreter, a wildcard, a package manager with no arguments, a firewall tool, or a program that the remote user can write. This list becomes the trust boundary of the feature. Read the README. | string | - |
| sudoAllowUnsafe | Install the sudoCommands list even when the check rejects an entry. Off by default, and the build fails instead. Turn it on only after you read each finding and decided that it is acceptable. | boolean | false |

## The problem this feature solves

When VS Code opens a dev container, it forwards a set of host channels into it. Each channel is a
Unix socket inside the container that connects to a program on your host. They are useful:

- `git push` over SSH uses the SSH keys on your host.
- A signed commit uses the GPG keys on your host.
- `git push` over HTTPS uses the GitHub login on your host.
- A GUI app in the container opens a window on your desktop.

The problem is that every program in the container can use these channels. A coding agent in the
container can sign a commit with your key, push to any repository that your host token can reach,
read your screen, or ask the VS Code extension on your host for a credential.

This feature closes those channels, and it removes `sudo` from the remote user, so a program in the
container cannot open them again.

> **Caution:** This feature is a mitigation, not a security boundary. There is a short time at each
> attach when a channel is open. Read [Limits](#limits) before you trust it.

## What stops working

These are the defaults. Each one has an option, and [Channels](#channels) lists them.

| What                                    | How to work without it                                    |
| --------------------------------------- | --------------------------------------------------------- |
| `git push`, `pull`, `fetch` over HTTPS  | Run `gh auth login` in the container.                     |
| `git push`, `pull`, `fetch` over SSH    | Use an HTTPS remote, or an SSH key in the container.       |
| Signed commits with your host keys      | Commit in the container, then sign on the host.           |
| GUI apps on your desktop                | Run the app on the host.                                  |
| `docker pull` with your host registry login | Log in to the registry in the container.              |
| `sudo`                                  | Install tools in the image. Or see [sudo modes](#sudo-modes). |

The `code` command still works, because `blockCodeCli` is off by default. Read
[The `code` CLI channel](#the-code-cli-channel) for what that channel gives away.

## Install

### 1. Add the feature to your project

```jsonc
"remoteUser": "vscode",
"features": {
  "ghcr.io/nshafer/devcontainer-features/sandbox:3": {}
},
"securityOpt": ["no-new-privileges"]
```

`remoteUser` must not be `root`. Root can undo every block, so the feature does nothing in a
container that runs as root. The build says so in a warning.

Add `securityOpt` yourself. The feature cannot add it, and [sudo modes](#sudo-modes) explains why.
The flag stops every setuid program, `sudo` included, so it makes the removal of `sudo` permanent.
Leave it out if you use `"sudoMode": "restricted"`.

### 2. Change these settings on the host

The blocks inside the container cannot be complete. The fixes that fully close the channels are on
your host. Do these on each machine where an agent runs in a container:

1. Unset `SSH_AUTH_SOCK` and `DISPLAY` in the environment that starts VS Code. Then VS Code has
   nothing to forward.
2. Turn off the Wayland mount in your VS Code user settings:

   ```jsonc
   "dev.containers.mountWaylandSocket": false
   ```

3. Keep your source in a container volume, not in a bind mount of a host folder. The command
   **Dev Containers: Clone Repository in Container Volume** does this. See
   [The workspace bind mount](#the-workspace-bind-mount).
4. Run the agent as a different Unix user than the remote user, if you can. Another user cannot
   connect to a forwarded socket.

### 3. Rebuild the container and check the result

Run `sandbox-status` in the container. It reads only, so it is always safe to run. It exits with an
error code if a channel is still open.

```console
$ sandbox-status
sandbox: forwarded host channels in this container
  ssh agent        blocked
  gpg agent        blocked
  x11 display      blocked
  code cli         not blocked (option is off)
  git askpass      blocked
  extension ipc    blocked
  sudo             dropped
  no-new-privs     not set -- add "securityOpt": ["no-new-privileges"] in devcontainer.json
  sweeper          running (inotify, 1s poll backstop)
```

The feature writes what it does to `/var/log/devcontainer/sandbox.log`.

## Channels

This is the full list of channels that VS Code forwards. The extension itself writes the list into
the `REMOTE_CONTAINERS_SOCKETS` variable in the container.

| Channel        | Path                                             | Option              | Default     | What it gives a program in the container |
| -------------- | ------------------------------------------------ | ------------------- | ----------- | ---------------------------------------- |
| SSH agent      | `/tmp/vscode-ssh-auth-<uuid>.sock`               | `blockSshAgent`     | blocked     | Signing with your host SSH keys.         |
| GPG agent      | `~/.gnupg/S.gpg-agent`                           | `blockGpgAgent`     | blocked     | Signing with your host GPG keys.         |
| GPG keyring    | `~/.gnupg/S.keyboxd`                             | `blockGpgAgent`     | blocked     | Your keyring.                            |
| X11 display    | `/tmp/.X11-unix/X<n>`                            | `blockX11`          | blocked     | Your desktop: keystrokes and screenshots. |
| Extension IPC  | `vscode-remote-containers-ipc-<uuid>.sock`       | `blockExtensionIpc` | blocked     | Calls to the extension on your host, including every credential that your host stores. |
| Git credentials | `vscode-git-<id>.sock`                          | `blockGitAskpass`   | blocked     | Your GitHub token, through `GIT_ASKPASS`. |
| `code` CLI     | `vscode-ipc-<uuid>.sock`                         | `blockCodeCli`      | **open**    | A local VS Code window on any host path. A URI that an app on your host opens. |
| Wayland        | `/tmp/vscode-wayland-<uuid>.sock`                | none                | open        | Your desktop. This one is a bind mount. See [Limits](#limits). |

### The two credential channels

Two channels answer a request for a credential, and either one is enough to push over HTTPS:

- The extension IPC socket. VS Code writes it into `/etc/gitconfig` as `credential.helper`. It
  answers for every host in the credential store of your host, with no prompt.
- The git credentials socket. Git reaches it through `GIT_ASKPASS`. VS Code asks you only for a
  host that it has no session for.

Both are blocked by default, so a push over HTTPS fails and names both:

```
> git push origin main:main
Unable to connect to VS Code Dev Containers extension.
Error in request Error: connect EACCES /tmp/vscode-remote-containers-ipc-<uuid>.sock
Missing or invalid credentials.
Error: connect EACCES /tmp/vscode-git-<id>.sock
```

Run `gh auth login` in the container to get a login of its own. Set `blockGitAskpass` to `false` if
you want to push with the token of your host instead.

## How the blocks work

**The feature seals a socket. It does not delete it.** It runs `chown root:root` and `chmod 000` on
the socket. A deleted socket is worse, because the path is then free and VS Code makes a new one
that works.

| Action                      | After a delete       | After a seal                                |
| --------------------------- | -------------------- | ------------------------------------------- |
| A program connects          | It works.            | `EACCES`                                    |
| A program deletes the file  | Not applicable.      | `EPERM`. `/tmp` is sticky, and root owns the file. |
| VS Code makes a new socket  | It works.            | `EADDRINUSE`                                |

**The feature seals each socket after VS Code creates it.** It does not take the path in advance.
Taking the path first looks safer, and it works, but then the container never opens: the helper of
VS Code fails to create the socket, and the window stays on "Configuring Dev Container" with no
error and no timeout.

**A root daemon does the sealing.** The entrypoint of the feature runs as root when the container
starts, before VS Code attaches. It seals the sockets with fixed names, then leaves a daemon
running for the life of the container. The daemon watches for new sockets with `inotify`, and
seals one about a millisecond after it appears. A poll every second, from the `sweepInterval`
option, catches anything that `inotify` missed.

The daemon has to keep running, because each VS Code window that you open forwards a new set of
sockets with new names in them.

**The daemon looks three folders deep.** In a dev container, `XDG_RUNTIME_DIR` is `/tmp/user/<uid>`,
and the git credential socket is often there. A search two folders deep misses it.

**The feature reports a channel that it does not know.** The `postStart` and `postAttach` scripts
run as the remote user, and they read `REMOTE_CONTAINERS_SOCKETS`. If that list names a socket that
the daemon did not seal, you get a warning. The scripts report only. They do not seal, because the
remote user controls the content of that variable, and root must not change the mode of a path that
the remote user names.

**The environment scrub is the weakest layer.** With `scrubEnv` on, every shell unsets the
variables that name the blocked sockets: `SSH_AUTH_SOCK`, `DISPLAY`, `GIT_ASKPASS`, `BROWSER`,
`VSCODE_IPC_HOOK_CLI` and `REMOTE_CONTAINERS_*`. This is not a control. VS Code puts the variables
back in each process that it starts, and any program can read the path from `/proc`. The sealed
socket is the control. The scrub only stops a tool from finding a path by accident.

The scrub covers the blocked channels only. An open channel keeps its variable, because a shell
without `GIT_ASKPASS` cannot push even when the socket works.

The scrub lines go in `/etc/profile.d`, `/etc/bash.bashrc`, `/etc/zsh/zshenv` and `BASH_ENV`. They
are all in `/etc`, never in the home directory, because [`persist-homedir`](../persist-homedir) puts
`/home` on a volume that hides what the image wrote there.

## sudo modes

Every block is a file that root owns. A remote user who can become root undoes all of them with one
command. So what happens to `sudo` is the most important part of this feature. The `sudoMode`
option sets it.

| `sudoMode`         | What the remote user can run as root                          | Use it when                          |
| ------------------ | ------------------------------------------------------------- | ------------------------------------ |
| `drop` (default)   | Nothing. The feature removes the grant, and removes the setuid bit from `sudo` if a route survived. | Almost always. |
| `restricted`       | Only the exact command lines in `sudoCommands`, and only as root. | A project needs one or two root commands. |
| `keep`             | Everything. The feature then protects nothing.                 | Never, if you can help it.          |

In `drop` mode, the feature deletes the `sudoers.d` entry, removes the user from the `sudo`, `wheel`
and `admin` groups, then tests the result with `sudo -n true`. If any route is still open, it
removes the setuid bit from `sudo`.

### Why you add `no-new-privileges` yourself

The `no-new-privileges` flag stops every setuid program. It is a second lock: a setuid program that
the drop missed still cannot give root back.

The feature cannot set the flag. A `devcontainer-feature.json` file is static, so a feature cannot
set a flag only for some option values. The flag blocks `sudo` for everyone, restricted mode
included. So the flag lives in your `devcontainer.json`, where you control it.

```jsonc
"securityOpt": ["no-new-privileges"]
```

`sandbox-status` shows whether the flag is set.

**The flag reaches into a nested Docker daemon, and nothing can clear it.** The kernel gives
`no_new_privs` to every child process. A `docker-in-docker` daemon in a container with the flag
gives it to every container that it starts. In those containers, `sudo` fails with *"the no new
privileges flag is set"*, whatever their own settings say. Give such a container root directly
instead, with a `remoteUser` of `root` or with `docker run -u root`.

### Restricted mode

The blanket grant still goes away. In its place, the feature writes
`/etc/sudoers.d/900-sandbox-restricted`, with one line for each command that you name:

```jsonc
"sudoMode": "restricted",
"sudoCommands": "/bin/systemctl restart myapp,/usr/sbin/nginx -s reload"
```

Rules of the generated file:

- **Root is the only target user.** A caller cannot choose the user to run as. That closes a whole
  class of bugs, such as CVE-2019-14287.
- **The arguments are exact.** `sudo /usr/bin/id -u` works and `sudo /usr/bin/id -g` does not. An
  entry with no arguments allows every argument, which is the most common way that an allowlist
  turns into full root.
- **`visudo` checks the file before the feature installs it.** A syntax error in one `sudoers.d`
  file stops `sudo` for everyone, root included.
- **The feature writes the file again at each container start.** A later feature, or a
  `postCreateCommand`, can put a blanket grant back.

> **Caution:** The list becomes the trust boundary of this whole feature. Any command in it that
> can write a file or start a program undoes every block above.

`sandbox-status` prints the list in restricted mode, because nobody can review a number:

```console
  sudo             restricted -- blanket grant gone, 2 command(s) allowed
                     /bin/systemctl restart myapp
                     /usr/sbin/nginx -s reload
  no-new-privs     not set (sudoMode=restricted needs it unset)
```

### The check on `sudoCommands`

The feature checks each entry when the image builds, and **the build fails** if an entry is a route
back to full root. Each rule below is a real escape. You can run the check by hand:

```console
$ sandbox.sh lint-sudo '/usr/sbin/iptables'
error: iptables with no arguments permits every argument, and it rewrites the firewall, which
       switches off the egress-filter feature entirely
```

Entries that the check rejects:

| What                                                                   | Why                                                      |
| ---------------------------------------------------------------------- | -------------------------------------------------------- |
| A relative path, such as `systemctl restart x`                         | The caller controls `PATH`, so the caller picks the program. |
| A wildcard, such as `systemctl reboot *`                               | A wildcard in sudoers matches `/` and spans arguments. So `chmod 666 /tmp/*` allows `chmod 666 /tmp/../etc/shadow`. |
| Shell syntax: `;` `&&` `\|` `<` `>`, a backtick, a dollar sign or a quote | `sudo` runs the command itself. It never runs a shell, so `/bin/foo; rm -rf /` is one command. |
| `!`                                                                    | Negation in sudoers denies a path. The same program at another path is allowed. |
| A shell or interpreter: `sh`, `bash`, `python3`, `perl`, `awk`, `node`  | It runs anything as root.                                |
| A program that runs a program: `env`, `xargs`, `find`, `timeout`, `nohup`, `watch`, `systemd-run` | The same, one step away.        |
| An editor or pager: `vim`, `less`, `man`, `nano`                       | They can start a shell. In `vim`, `:!sh`.                |
| A privilege tool: `su`, `chroot`, `unshare`, `nsenter`, `setcap`, `passwd`, `usermod`, `mount` | It changes the privilege model itself. |
| A container tool: `docker`, `podman`, `runc`, `ctr`                    | A container can mount the host filesystem as root.       |
| A debugger: `gdb`, `strace`                                            | It controls another process as root.                     |
| `needrestart`                                                          | A known local root escalation, CVE-2024-48990 and others. It reads `PYTHONPATH` from another running process, so `env_reset` does not stop it. |
| `true`, `false`, `:`                                                   | The feature runs `sudo -n true` to prove that the grant is gone. |
| A program, or a folder above it, that root does not own, or that the group or other users can write | Whoever can write it picks what `sudo` runs. |
| Any program in the table below **with no arguments**                   | No arguments means every argument.                       |

Entries that the check allows with a warning. Each one is only as safe as the arguments that you
pinned:

| What                                                     | Why                                                        |
| -------------------------------------------------------- | ---------------------------------------------------------- |
| `cp`, `mv`, `tee`, `dd`, `install`, `ln`, `chmod`, `chown` | They write or re-own what you named. A `cp` whose source the remote user can write makes a root-owned copy of their content. |
| `tar`, `unzip`, `rsync`, `scp`                           | They write the paths that the archive or the far side names. |
| `systemctl`, `service`                                   | They start, stop or mask a unit. A unit file that the remote user can write, plus an allowed `daemon-reload`, is root. |
| `apt-get`, `dpkg`, `pip`, `npm`, `gem`                   | Package installs run scripts as root.                      |
| `git`, `curl`, `ssh`, `socat`                            | They run or fetch what the far side chooses.               |
| `journalctl`, `dmesg`                                    | They pipe to a pager, and a pager can start a shell. Pin `--no-pager`. |
| `iptables`, `nft`, `ipset`, `ip`, `tc`, `ufw`            | They rewrite the firewall, which turns off the [`egress-filter`](../egress-filter) feature. |

Set `sudoAllowUnsafe` to `true` to install the list after you read each finding and decided that it
is acceptable. The findings still print, at build time and at each container start.

**The check fails closed.** A list that does not pass is not installed, and the mode becomes a full
`drop`. It does not become "restricted, without the rejected entries". `sandbox-status` says so.

**You cannot read the list from a file in the workspace.** The remote user can write the workspace,
so such a file would be a way to grant root to itself. `sudoCommands` is a build-time option only.

## Limits

**There is a short window at each attach.** The socket must exist, because a container where the
helper of VS Code cannot create the socket is a container that you cannot open. So the socket
appears, and the feature takes it a moment later. The table shows a measurement against a forwarded
socket, with a program in a loop that calls `connect()`:

| How the feature seals       | Connections before the seal | Window  |
| --------------------------- | --------------------------- | ------- |
| The 1 second poll alone     | 15,299                      | 993 ms  |
| `inotify` (the default)     | **7**                       | **5 ms** |

`inotify` is about 2,000 times better, and the feature installs `inotify-tools` for it. It is still
not zero, and **one connection is enough** to sign something with the `ssh-agent` of your host. The
window opens again for each window that you attach.

**A fixed-name socket has a weaker guarantee than a UUID-named one.** The folders `/tmp/.X11-unix`
and `~/.gnupg` stay writable, because the container cannot start otherwise. The user who owns the
folder can delete a sealed socket there and make a new one. The names with a UUID in them are in
`/tmp`, which is sticky, so the remote user cannot delete a file that root owns.

**Wayland cannot be blocked from inside the container, and the feature does not try.** The Wayland
socket is not a socket that VS Code creates in the container. It is a bind mount of
`/run/user/<uid>/wayland-0` from your host. The container cannot delete it (`EBUSY`) or unmount it
(no `CAP_SYS_ADMIN`), and **a permission change on a bind mount changes the host file**. A seal
would set mode `000` on the socket of your own desktop session. Every change that the feature makes
first checks `/proc/self/mountinfo` for this reason. Turn off the mount on the host instead.

**A sealed socket stays sealed.** The remote user cannot delete the file in `/tmp`. A new socket at
the same path belongs to their own process and has nothing behind it, because the forwarding lives
in the helper process, not in the file. So a tool that finds `SSH_AUTH_SOCK` by accident fails, and
an agent that does not race the seal fails.

Treat this feature as a seat belt for an agent that does something careless. It is not armor
against an agent that was told to go looking.

## The `code` CLI channel

`blockCodeCli` is off by default. A seal on this socket stops the container from attaching: the VS
Code server deletes that path when it shuts the channel down, a file that root owns makes the delete
throw `EPERM`, and the window stays on "Configuring Dev Container".

```js
dispose() { ...; this._ipcHandlePath && existsSync(this._ipcHandlePath) && unlinkSync(this._ipcHandlePath) }
```

The error goes to `~/.vscode-server/data/logs/*/remoteagent.log`:

```
[error] Error: EPERM: operation not permitted, unlink '/tmp/vscode-ipc-<uuid>.sock'
    at Module.unlinkSync ... at Eh.dispose ...
```

Nothing in the container can fix this. Set `blockCodeCli` to `true` only if you accept that the
container does not attach.

### What the channel gives away

Anything that runs as the remote user can send four message types to that socket. It does not need
the `code` command. An HTTP `POST` to the socket is enough.

**`open`** opens files and folders in a VS Code window. This is the most serious of the four. The
request names its own `remoteAuthority`, so a `null` value asks your host for a **local** window.
The path uses the `vscode-local:` scheme, which VS Code rewrites to a `file:` path on your host.
This request, sent from inside the container, opens a window on a host folder:

```sh
curl --noproxy '*' --unix-socket "$VSCODE_IPC_HOOK_CLI" -H 'Content-Type: application/json' \
    -d '{"type":"open","folderURIs":["vscode-local:/host/path"],"forceNewWindow":true,"remoteAuthority":null}' \
    http://localhost/
```

In a test on VS Code 1.137.0, the window opened with no workspace trust prompt, because the folder
was inside a project that the host already trusted. A trusted folder makes its subfolders trusted.
The git extension on the host then offered to open the parent repository.

The container reads nothing back. The response is `null`. But the path can be any file or folder on
your host, and the window runs your host extensions against it. The next section shows why that is
enough to run a command on your host.

**`openExternal`** gives a URI to your host. The `code --openExternal` flag and the `BROWSER`
variable both use it.

| Scheme            | What your host does                                                            |
| ----------------- | ------------------------------------------------------------------------------ |
| `file:`           | The server in the container drops it. Nothing reaches your host.               |
| `http:`, `https:` | Your host asks "Do you want Code to open the external website?". It does not ask for a domain in `workbench.trustedDomains`. |
| Any other scheme  | Your host gives it to the operating system with no prompt. The app that is registered for the scheme opens it. |

The last row is the risk. The attacker picks the scheme and the whole URI, and you see no prompt.

**`extensionManagement`** installs, removes and lists extensions. The extension goes into
`~/.vscode-server/extensions` and runs in the container, as the remote user. Your host refuses an
extension that can run in the host UI only. The install is machine-scoped, so Settings Sync does not
copy it to your other machines. An installed extension still gets the full VS Code API, and part of
that API reaches your host UI: `env.openExternal`, commands, and `authentication.getSession`, which
prompts. The socket is not the only route here. The remote user owns
`~/.vscode-server/extensions` and can write an extension into it.

**`status`** returns the text that "Help: Report Issue" collects.

## The workspace bind mount

**A program in the container can run a command on your host, as your host user, with no click.**
The `code` CLI channel is not the cause. The cause is the workspace bind mount: tools on your host
read files that the container can write. The channel only lets the attacker pick the moment.

The chain:

1. The attacker writes one setting into `.git/config` in the workspace:

   ```ini
   [core]
       fsmonitor = "sh -c 'any command here' #"
   ```

   On Linux, Dev Containers gives the container user the same UID as your host user. So git on the
   host sees a repository that you own, and it trusts the config.
2. The attacker sends the `open` request above for the root of the repository.
3. A local window opens. The folder is trusted, so the git extension on your host opens the
   repository and runs `git status`.
4. `git status` runs the `core.fsmonitor` command on your host.

Step 4 is tested: `git status` in git 2.55.0 runs the command. The git extension in VS Code 1.137.0
has no reference to `fsmonitor`, so it does not stop it. The full chain is not tested on a host.

Other routes, and what each one needs from you:

| Route                                                         | What runs on your host                                         | What you must do                    |
| ------------------------------------------------------------- | -------------------------------------------------------------- | ----------------------------------- |
| `core.fsmonitor` in `.git/config`                             | Any command.                                                   | Nothing.                            |
| `initializeCommand` in `.devcontainer/devcontainer.json`      | Any command.                                                   | Click "Reopen in Container", or rebuild. |
| `mounts` or `runArgs` in `devcontainer.json`                  | A container with your host home folder or `/var/run/docker.sock`. | Rebuild.                         |
| `.git/hooks/*` or `core.hooksPath`                            | Any command.                                                   | Commit from the host.               |
| `.vscode/tasks.json` with `runOptions.runOn: folderOpen`      | Any command.                                                   | Accept the prompt about automatic tasks. |
| A `vscode-local:` file URI                                    | A host file shows on screen, such as `~/.ssh/id_ed25519`.      | Nothing, but the container gets no copy. |

**Every route in that table works without the `code` CLI channel.** It fires the next time that you
run `git` in the folder, open the folder in a local window, or rebuild. A shell prompt that shows
git status is enough for `core.fsmonitor`. The channel changes "the next time you do something" into
"now".

What reduces the risk:

1. Keep your source in a container volume, not in a bind mount. Use **Dev Containers: Clone
   Repository in Container Volume**. Then no host tool reads a file that the container wrote.
2. If you keep the bind mount, do not run `git` or VS Code on the host in that folder while an agent
   works in the container.
3. Before you rebuild, run `git diff .devcontainer/` and read `.git/config`.
4. On the host, trust single project folders, not a parent folder such as `~/projects`. Every folder
   under a trusted folder is trusted, so any of them is a target for the `open` request.

## Rootless Docker and Podman

**The blocks work.** Each one is a `chown root` and a `chmod 000` **inside** the container, and
inside a rootless container root is still root. It owns the user namespace that the container runs
in. The removal of `sudo` works for the same reason. Nothing in this feature asks the host for a
capability.

**You still need the feature.** Under a rootless runtime, a program that breaks out of the container
lands on your normal host account and not on host root. That closes one route. It does not change
this one: VS Code still forwards your SSH agent, your GPG agent, your display and your GitHub token
into the container, and those sockets answer any program in it.

Two things to check on your host:

- **The `userns` flag.** Podman with `--userns=keep-id` maps your host UID into the container and
  renumbers the other users. The blocks expect a mapped root. Build one container with the exact
  flag that you plan to use, then read `/var/log/devcontainer/sandbox.log` and make sure that each
  block reports success.
- **SELinux.** On Fedora and RHEL, the runtime labels a socket that VS Code forwards through a bind
  mount. The feature leaves a bind mount alone and says so in the log, so SELinux changes the
  report and not the behavior.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nshafer/devcontainer-features/blob/main/src/sandbox/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
