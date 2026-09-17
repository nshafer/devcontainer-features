
# Tidewave (nshafer) (tidewave)

Installs the Tidewave CLI when the image builds, and starts it at each container start, so the Tidewave app on your host can work with the project in the container.

## Example Usage

```json
"features": {
    "ghcr.io/nshafer/devcontainer-features/tidewave:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| version | The version to install: 'latest', or an exact X.Y.Z that matches a tidewave_app release tag. | string | latest |
| port | The port that the CLI listens on in the container. Publish the same port number on the host, with "appPort": ["127.0.0.1:9000:9000"]. The CLI refuses a request whose Origin names another port. | string | 9000 |
| allowRemoteAccess | Listen on every address in the container, not on 127.0.0.1 only. A published port needs this, because Docker sends it to the bridge address of the container. The CLI still refuses a request whose Origin is not localhost. | boolean | true |
| debug | Write what the CLI does to /tmp/tidewave.log. Off by default, because a healthy run is silent. | boolean | false |
| autostart | Start the CLI at each container start. Turn it off to install the program only, and run 'tidewave' yourself. | boolean | true |

## Install

[Tidewave](https://tidewave.ai) is an app that runs on your host. It connects to the Tidewave CLI,
which runs next to your project. This feature installs the CLI in the container and starts it.

A feature cannot publish a port or read environment variables of the host. So you must add three
things yourself.

### 1. Set `TIDEWAVE_HOST_PATH` on the host

Set it to the path of your project on the host, in the environment that starts VS Code. The CLI uses
this path when it opens a file in your editor. Without it, the CLI gives your editor paths from
inside the container, and the editor cannot open them. I suggest tools that can set environment
variables in your project directory, such as `mise` or `direnv`.

### 2. Add the feature, the port and the variable to `devcontainer.json`

```jsonc
"features": {
  "ghcr.io/nshafer/devcontainer-features/tidewave:1": {}
},
"appPort": ["127.0.0.1:9000:9000"],
"remoteEnv": { "TIDEWAVE_HOST_PATH": "${localEnv:TIDEWAVE_HOST_PATH}" }
```

If you change the `port` option, change both numbers in `appPort` to the same value.

### 3. Rebuild the container

The creation log shows `tidewave: listening on 9000`. The Tidewave app on the host can then
connect to port 9000.

## Port rules

**Use the same port number on the host and in the container.** Write `9000:9000`, not `9411:9000`.
The CLI reads the `Origin` header of each request. It refuses a request that names a different port.

**Keep `allowRemoteAccess` on.** Docker sends a published port to the network address of the
container, not to `127.0.0.1` in the container. With the option off, the CLI listens on
`127.0.0.1` only, and nothing on the host can connect.

**Keep `127.0.0.1:` at the start of `appPort`.** It publishes the port on the loopback address of
your host only. Without it, other computers on your network can connect to the port.

## How it works

### At build time

1. The feature finds the CPU type (`x86_64` or `aarch64`) and the C library of the image (glibc or
   musl).
2. It downloads the matching CLI from the `tidewave_app` GitHub releases to
   `/usr/local/bin/tidewave`. A version that does not exist stops the build.
3. It writes the option values to `/usr/local/share/devcontainer/tidewave/config`.

The C library matters because of the Bun runtime. The CLI downloads Bun the first time it runs,
and it picks the Bun build that matches its own build. A musl CLI on a glibc image downloads a Bun
that cannot run there. So the feature installs the musl CLI only on a musl image, such as Alpine.

### At each container start

1. If a Tidewave CLI already answers on the port, the script stops.
2. The script sets `TMPDIR` to `~/.cache/tidewave/tmp`. If it cannot write there, it keeps the
   default.
3. It starts the CLI in the background, as the remote user, in the workspace folder. The CLI serves
   the folder that it starts in.
4. It waits up to 10 seconds for the CLI to answer, and writes the result to the log.

The script never stops the container from starting. If the CLI does not start, the creation log
shows an error and the contents of the log file.

## Files and logs

| Path                                             | What it holds                                              |
| ------------------------------------------------ | ---------------------------------------------------------- |
| `/tmp/tidewave.log`                              | The start command and time. The CLI output. Cleared at each start. |
| `~/.cache/tidewave/downloads`                    | The Bun runtime that the CLI downloads.                    |
| `~/.cache/tidewave/tmp`                          | Temporary files of the CLI.                                |
| `/usr/local/share/devcontainer/tidewave/config`  | The options, fixed at build time.                          |

The CLI writes nothing to the log when it works. Set `debug` to `true` to log what it does.

With [`persist-homedir`](../persist-homedir), the Bun download and the temporary files stay after a
rebuild.

## What it does not do

- It does not publish the port. Add `appPort` yourself.
- It does not apply option changes to a running container. Rebuild the container after you change
  an option.
- It does not restart the CLI if the CLI stops. Restart the container, or run `tidewave` yourself
  with the flags in the config file.
- It does not delete an old Bun download. If you change the image between glibc and musl, the old
  download stays in the cache.

## Risks

- **The Tidewave app gets access to your project through the CLI.** Anything that can connect to the
  port can use the same access.
- **The `Origin` check stops web pages, not programs.** A web page from another site cannot use the
  CLI. A program on your host can send any `Origin` header, so it can connect.
- **Without `127.0.0.1:` in `appPort`, the port is open to your network.**
- **The first run needs network access.** The CLI downloads Bun. With
  [`egress-filter`](../egress-filter), enable the `tidewave` preset or run `egress-denied` to see
  which hosts to allow.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nshafer/devcontainer-features/blob/main/src/tidewave/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
