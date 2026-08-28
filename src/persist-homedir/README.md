
# Persistent home directory (nshafer) (persist-homedir)

Keeps /home on a named volume so shell history, caches and tool installs survive a rebuild, while keeping the VS Code server out of it so extensions reinstall fresh.

## Example Usage

```json
"features": {
    "ghcr.io/nshafer/devcontainer-features/persist-homedir:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|




---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nshafer/devcontainer-features/blob/main/src/persist-homedir/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
