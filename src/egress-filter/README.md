
# Egress filter (nshafer) (egress-filter)

Default-deny outbound networking, with a hostname allowlist merged from a global list on the host, a per-project list in the repo, and a baseline that keeps VS Code working. Enforced by an in-container firewall, so an agent that ignores HTTP_PROXY simply cannot connect.

## Example Usage

```json
"features": {
    "ghcr.io/nshafer/devcontainer-features/egress-filter:1": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| allow | Extra hostnames to allow, comma separated, on top of the lists. A leading dot means the domain and its subdomains: '.github.com,pypi.org'. | string | - |
| deny | Hostnames to remove from the merged allowlist, comma separated. Applied last, so it overrides the global, project and baseline lists. | string | - |
| baseline | Include the built-in baseline that keeps VS Code itself working - the marketplace, extension CDNs and update hosts. Without it the server cannot install extensions, and attaching may hang. | boolean | true |
| projectAllowlist | Where the per-project list lives inside the container. A glob, because a feature's entrypoint is not told the workspace folder. Read once at container start and never re-read - it lives in the repo, where the container's own user can write it. See the README. | string | /workspaces/*/.devcontainer/egress-allow.txt |
| allowDns | Let the container resolve names directly. Turning this off closes a slow exfiltration channel but breaks anything that resolves for itself - git, package managers, most clients. See the README. | boolean | true |
| proxyPort | Loopback port the filtering proxy listens on. | string | 3128 |



---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/nshafer/devcontainer-features/blob/main/src/egress-filter/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
