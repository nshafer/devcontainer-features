# devcontainer-features

Dev container features that make a dev container a safer place to run a coding agent, such as
Claude Code, and that keep your settings when you rebuild the container.

A **dev container** is a Docker container that VS Code (or the `devcontainer` CLI) builds from a
`.devcontainer/devcontainer.json` file in your project. A **feature** is a packaged install script
that you name in that file. The tool runs the script when it builds the container.

| Feature                                  | What it does                                                                        |
| ---------------------------------------- | ----------------------------------------------------------------------------------- |
| [`persist-homedir`](src/persist-homedir) | Keeps `/home` on a Docker volume, so shell history, logins and caches survive a rebuild. |
| [`git-config`](src/git-config)           | Copies your git config and global ignore file from the host into the container.     |
| [`sandbox`](src/sandbox)                 | Blocks the SSH agent, GPG agent, display and credential sockets that VS Code forwards into the container. Removes `sudo`. |
| [`egress-filter`](src/egress-filter)     | Blocks all outbound network traffic except to the hosts that you allow.             |
| [`claude`](src/claude)                   | Installs the Claude Code CLI.                                                       |
| [`tidewave`](src/tidewave)               | Installs the Tidewave CLI and starts it, so the Tidewave app on your host can connect. |

Each link goes to the full documentation for that feature: options, how it works, and its risks.

## Quick start

### Step 1: Prepare your host (one time for each machine)

Run these commands on your computer, not in a container:

```bash
mkdir -p ~/.config/git ~/.config/egress-filter
touch ~/.config/egress-filter/allowlist.txt
```

`git-config` reads your git config from `~/.config/git/config` only. If your git config is in
`~/.gitconfig`, move it:

```bash
mv ~/.gitconfig ~/.config/git/config
```

> **Note:** Git ignores `~/.config/git/config` when `~/.gitconfig` exists. Do not create an empty
> `~/.gitconfig`.

### Step 2: Add the features to your project

Add this to `.devcontainer/devcontainer.json`. Remove the lines for the features that you do not
want. Keep `sandbox` if you keep `egress-filter`.

```jsonc
{
  "image": "mcr.microsoft.com/devcontainers/base:debian",

  // The features need a user that is not root.
  "remoteUser": "vscode",

  "features": {
    "ghcr.io/nshafer/devcontainer-features/persist-homedir:1": {},
    "ghcr.io/nshafer/devcontainer-features/git-config:2": {},
    "ghcr.io/nshafer/devcontainer-features/sandbox:3": {},
    "ghcr.io/nshafer/devcontainer-features/egress-filter:2": { "presets": "debian,github,claude" },
    "ghcr.io/nshafer/devcontainer-features/claude:1": {}
  },

  // git-config and egress-filter read these two folders. The folders must exist on the host.
  "mounts": [
    "type=bind,src=${localEnv:HOME}/.config/git,dst=/mnt/git-config,readonly",
    "type=bind,src=${localEnv:HOME}/.config/egress-filter,dst=/mnt/egress-filter,readonly"
  ],

  // For sandbox: stops setuid programs, such as sudo, from giving root back.
  "securityOpt": ["no-new-privileges"]
}
```

If your project uses Docker Compose, put the two mounts in `docker-compose.yml` instead. The
`readonly` flag does not work for a `devcontainer.json` mount in a Compose project.

```yaml
services:
  app:
    volumes:
      - ${HOME}/.config/git:/mnt/git-config:ro
      - ${HOME}/.config/egress-filter:/mnt/egress-filter:ro
```

### Step 3: Rebuild the container and make sure it works

1. In VS Code, run **Dev Containers: Rebuild Container** from the command palette.
2. Open a terminal in the container.
3. Run `sandbox-status`. Each channel except `code cli` must show `blocked`.
4. Run `egress-status`. The `firewall` line must start with `default deny`.
5. Run `curl https://example.com`. It must fail with `CONNECT tunnel failed, response 403`.

To allow a host, add it to `~/.config/egress-filter/allowlist.txt` on your host. The change applies
in about 2 seconds. See [Allow a host](src/egress-filter#allow-a-host).

## What changes in the container

Read this before you add `sandbox` and `egress-filter`. They remove access on purpose.

| What                                      | Why it stops working                   | What to do                                  |
| ----------------------------------------- | -------------------------------------- | ------------------------------------------- |
| `sudo`                                    | `sandbox` removes it.                  | Install tools in the image, or see [`sudoMode`](src/sandbox#sudo-modes). |
| `git push` over HTTPS                     | `sandbox` blocks your host login.      | Run `gh auth login` in the container.       |
| `git push` over SSH with your host keys   | `sandbox` blocks the SSH agent.        | Use HTTPS and `gh auth login`.              |
| Signed commits with your host keys        | `sandbox` blocks the GPG and SSH agents. | Sign on the host.                         |
| GUI apps on your desktop                  | `sandbox` blocks the X11 display.      | Run the app on the host.                    |
| Network access to most hosts              | `egress-filter` blocks them.           | Run `egress-denied`, then allow the hosts that you need. |
| SSH and other protocols that are not HTTP | `egress-filter` allows HTTP and HTTPS only. | Use HTTPS.                             |

## Other ways to add the features

### Keep the features out of the committed config

Your team may not want `sandbox` or `egress-filter` in the project. The
[`devc`](https://github.com/nshafer/devc) tool merges a `.devcontainer/devcontainer.local.json`
file over the committed `devcontainer.json`. Add that file to `.gitignore`, and put the features
in it.

### Add a feature to every project

The VS Code setting `dev.containers.defaultFeatures` adds features to every dev container that VS
Code builds:

```jsonc
"dev.containers.defaultFeatures": {
  "ghcr.io/nshafer/devcontainer-features/claude:1": {},
  "ghcr.io/nshafer/devcontainer-features/git-config:2": {},
  "ghcr.io/nshafer/devcontainer-features/persist-homedir:1": {}
}
```

Know these limits before you use it:

- The setting cannot add a mount. `git-config` copies nothing in a project without its mount.
- The `devcontainer` CLI ignores the setting. It reads `devcontainer.json` only.
- A project that names the same feature uses its own options.
- Do not add `sandbox`, `egress-filter` or `tidewave` this way. `sandbox` and `egress-filter` break
  normal work, so add them only where an agent runs. `tidewave` needs a port in each project.

## Rootless Docker and Podman

`egress-filter` needs extra setup on the host. See
[Rootless Docker and Podman](src/egress-filter#rootless-docker-and-podman). `sandbox` works without
changes. See [its notes](src/sandbox#rootless-docker-and-podman).

## Work on this repository

Open this folder in its dev container. The container builds the features from `src/`, so
**Rebuild Container** tests your change. Then use these commands:

```bash
make            # list the targets
make lint       # shellcheck, syntax and JSON checks, no containers
make sandbox    # test one feature
make test       # test all features, the same as CI
```

Each `src/<feature>/README.md` file is generated from `devcontainer-feature.json` and `NOTES.md`.
Edit `NOTES.md`, not the README. A push to `main` publishes each feature whose `version` changed.
