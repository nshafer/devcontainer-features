
# Claude Code (nshafer) (claude)

Installs the Claude Code CLI with the native installer.

## Example Usage

```json
"features": {
    "ghcr.io/nshafer/devcontainer-features/claude:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| version | Version to install: 'stable', 'latest', or an exact X.Y.Z. | string | stable |

## Customizations

### VS Code Extensions

- `anthropic.claude-code`

## Host setup

None. This feature mounts nothing from the host. You create no path before the first build.
Everything comes from the image.

## Notes

The feature installs the CLI at image build time. The build needs network access and downloads
about 300MB. The native installer runs as the remote user, so the layout matches what the CLI
updater expects. The feature also hard-links the resolved binary to a system path.
`/usr/local/bin/claude` is a wrapper that prefers the home copy. So `claude` runs from a fresh
volume, a stale volume, or no volume.

The feature mounts nothing from the host `~/.claude`. Credentials, transcripts, file history, and
plans stay on the host. Each container signs in for itself and holds nothing from another project.

`version` takes `stable` (the default), `latest`, or an exact `X.Y.Z`.

## Settings

Claude Code reads `.claude/settings.json` from the repository root. Keep your own local config in
`.claude/settings.local.json`, and gitignore it.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nshafer/devcontainer-features/blob/main/src/claude/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
