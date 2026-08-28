
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



---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nshafer/devcontainer-features/blob/main/src/tidewave/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
