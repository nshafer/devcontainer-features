
# Tidewave (nshafer) (tidewave)

Installs the Tidewave CLI at build time and starts it on every container start, so the Tidewave app on the host can drive the project inside the container.

## Example Usage

```json
"features": {
    "ghcr.io/nshafer/devcontainer-features/tidewave:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| version | Version to install: 'latest', or an exact X.Y.Z matching a tidewave_app release tag. | string | latest |
| port | Port the CLI listens on inside the container. It has to be published to the identical port number on the host -- the CLI rejects a request whose Origin names a different port -- so add "appPort": ["127.0.0.1:9000:9000"] to devcontainer.json. | string | 9000 |
| allowRemoteAccess | Pass --allow-remote-access, which binds 0.0.0.0 instead of 127.0.0.1. Required for a published port to reach it: Docker forwards to the container's bridge address, not to its loopback. The CLI still rejects requests whose Origin is not localhost. | boolean | true |
| autostart | Start the CLI at postStart. Turn off to install the binary only and run 'tidewave' yourself. | boolean | true |

## Host setup

This feature mounts nothing from the host, so there is no path to create. But a feature cannot open a
port, and it cannot read the host's project path. So the project has to add two lines, and the host
has to set one variable.

In the project's `devcontainer.json`:

```jsonc
"features": {
  "ghcr.io/nshafer/devcontainer-features/tidewave:1": {}
},
"appPort": ["127.0.0.1:9000:9000"],
"remoteEnv": { "TIDEWAVE_HOST_PATH": "${localEnv:TIDEWAVE_HOST_PATH}" }
```

On the host, set `TIDEWAVE_HOST_PATH` to the project path the host editor uses. The feature says so
in the creation log when the variable is missing. Without it, the app hands the host editor container
paths it cannot open.

## Notes

The feature runs the [Tidewave](https://tidewave.ai) CLI inside the container, so the Tidewave app on
the host can drive the project. Two halves. The feature downloads the binary at **image build time**
to `/usr/local/bin/tidewave`. A `postStartCommand` starts it on every container start.

| Option              | Default  | |
| ------------------- | -------- | --- |
| `version`           | `latest` | Or an exact `X.Y.Z` matching a `tidewave_app` release tag. A tag that does not exist fails the build. |
| `port`              | `9000`   | |
| `allowRemoteAccess` | `true`   | |
| `autostart`         | `true`   | Off installs the binary and starts nothing. |

**The published port has to be the same number on both sides.** `9000:9000`, never `9411:9000`. The
CLI checks the `Origin` header and rejects one that names a port other than its own. This is
measured, and it is the reason the upstream containers guide says the app must be reachable "using
the same host and port inside and outside the container".

**`allowRemoteAccess` defaults on because nothing works without it.** Left off, the CLI binds
`127.0.0.1` only, and a published port cannot reach that: Docker forwards to the bridge address of
the container, not to its loopback. The upstream devcontainer snippet omits the flag, and a container
built from it has a port nobody can connect to. Binding `0.0.0.0` is less alarming than it reads. The
`Origin` check above still stands, so a request from anywhere but a `localhost` origin gets a 403,
and `appPort` binding `127.0.0.1` keeps the port off the other interfaces of the machine.

**The libc build is detected, not chosen** — glibc unless the image is genuinely musl. The CLI binary
itself would not care: the musl asset is statically linked and runs fine on Debian. What cares is the
**Bun runtime the CLI downloads at first use** into `~/.cache/tidewave/downloads`. The CLI picks
which Bun to fetch from its own build triple, which it reports verbatim from `POST /about` with no
idea what the host libc actually is. So a musl CLI on Debian fetches `bun-linux-x64-musl`, and the
image has no loader for it:

```
sh: 1: /home/node/.cache/tidewave/downloads/bun-linux-x64-musl-1-3-10: not found
```

Detection is `ldd --version` naming musl, or the `/lib/ld-musl-<arch>.so.1` loader existing for
images with no `ldd`. Everything else gets gnu. Tests cover both branches. The default suite asserts
a gnu asset and a gnu target on `node`, and the `musl_image` scenario asserts a musl one on
`devcontainers/base:alpine`.

Switching an existing container between the two is self-healing, because the two Bun builds have
different filenames. The feature leaves the stale one in the cache and downloads a correct one beside
it. It is only wasted bytes, but it does survive a rebuild when `persist-homedir` is in play.

The feature uses `postStart` rather than `postCreate`, because the process dies with the container
and has to come back with it. It runs on every start, so it first probes `POST /about` and leaves an
instance that already answers alone.

The CLI takes no project path and has no flag for one. It serves its working directory, which for a
lifecycle hook is the workspace folder. That is also why this is not the `entrypoint` of the feature.
An entrypoint runs as root, from `/`, before the workspace matters.

Startup goes to `/tmp/tidewave.log`, stamped with the command and time, because the CLI itself is
silent on a healthy run. Nothing in the start script exits non-zero. A bridge that failed to come up
is worth a loud line in the creation log, not worth failing the container over.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nshafer/devcontainer-features/blob/main/src/tidewave/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
