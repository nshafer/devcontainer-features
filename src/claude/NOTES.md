## Host setup

None. This feature mounts nothing from the host. You create no path before the first build.
Everything comes from the image and the `settings` option.

## Notes

The feature installs the CLI at image build time. The build needs network access and downloads
about 300MB. The native installer runs as the remote user, so the layout matches what the CLI
updater expects. The feature also hard-links the resolved binary to a system path.
`/usr/local/bin/claude` is a wrapper that prefers the home copy. So `claude` runs from a fresh
volume, a stale volume, or no volume.

The feature mounts nothing from the host `~/.claude`. Credentials, transcripts, file history, and
plans stay on the host. Each container signs in for itself and holds nothing from another project.

`version` takes `stable` (the default), `latest`, or an exact `X.Y.Z`. `settings` seeds
`~/.claude/settings.json` before the installer runs:

```jsonc
"ghcr.io/nshafer/devcontainer-features/claude:1": {
  "settings": "{'includeCoAuthoredBy': false, 'model': 'opus'}"
}
```

**Write that object with single quotes.** The devcontainer CLI writes option values into the
generated Dockerfile without escaping. A value with double quotes arrives with the quotes collapsed
and the JSON broken. The feature converts `'` into `"` when it reads the value. The cost: you cannot
write a value that contains an apostrophe. An unparsable value fails the build and prints the
received text. It does not build a container whose CLI errors on startup.

The feature seeds the file _before_ the installer on purpose. The installer writes
`autoUpdatesChannel` into the same file and merges, so both values survive. This is also the last
time the feature touches the file. From the first run the CLI owns it. The CLI writes the theme,
model, and update channel back. Expect the CLI to normalize what it finds: `'model': 'opus'` becomes
`"opus[1m]"`.

A persisted home volume with existing content hides the image copy. A container whose volume
predates a settings change does not see the change until you recreate the volume.
