
# Claude Code (nshafer) (claude)

Installs the Claude Code CLI with the native installer, and can seed ~/.claude/settings.json at build time.

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
| settings | JSON object written to ~/.claude/settings.json at build time, written with single quotes: {'includeCoAuthoredBy': false}. Double quotes do not survive the devcontainer CLI's option quoting. Empty writes nothing; the CLI owns the file from its first run. | string | - |

## Customizations

### VS Code Extensions

- `anthropic.claude-code`



---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nshafer/devcontainer-features/blob/main/src/claude/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
