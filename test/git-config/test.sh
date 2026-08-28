#!/usr/bin/env bash
set -e
source dev-container-features-test-lib

# postCreateCommand does not run in this harness, so drive the copy directly. Assertions compare
# against the mounted host files rather than hardcoding values, so they hold on any machine.
# Nothing here writes to /mnt/git-config: that mount is the host's real git directory. It is mounted
# read-only, but the snapshot below still holds the run to leaving it alone, since the read-only
# flag reaches docker through a workaround (see the mount comment in post-create.sh) that a future
# CLI could stop honoring silently.
before=$(find /mnt/git-config -type f -exec md5sum {} + | sort; find /mnt/git-config -exec stat -c '%n %Y %a' {} + | sort)

/usr/local/share/nshafer-git-config/post-create.sh

check "git is installed" git --version
check "config was copied" test -s "$HOME/.config/git/config"
check "excludes file was copied" test -s "$HOME/.config/git/ignore"

check "copied config matches the host's values" bash -c '
    want=$(git config -f /mnt/git-config/config --get user.name || true)
    [ -z "$want" ] || [ "$(git config --global --get user.name)" = "$want" ]'

check "sections are copied verbatim, filters included" bash -c '
    diff <(tail -n +2 "$HOME/.config/git/config" | grep "^\[") <(grep "^\[" /mnt/git-config/config)'

check "git honors the copied excludes" bash -c '
    v=$(git config --global --get core.excludesfile || true)
    f="${v:+${v/#\~/$HOME}}"; f="${f:-$HOME/.config/git/ignore}"; [ -f "$f" ] || exit 0
    # Needs a literal pattern: no trailing slash, since a directory-only pattern cannot match a
    # path that does not exist, and no glob characters.
    pat=$(grep -m1 -E "^[^#[:space:]/*?![]+$" "$f"); [ -n "$pat" ] || exit 0
    d=$(mktemp -d) && cd "$d" && git init -q .
    git check-ignore -q "$pat"'

# The cleanup pass, driven with a synthetic source so it does not depend on the host's config.
check "unsets keys naming a program this container lacks, keeps the rest" bash -c '
    src=$(mktemp -d); home=$(mktemp -d)
    printf "%s\n" \
        "[core]" \
        "	editor = definitely-not-installed-xyz --wait" \
        "	sshCommand = cat" \
        "[gpg]" \
        "	program = also-not-installed-xyz" \
        "[http]" \
        "	sslBackend = schannel" \
        "[filter \"lfs\"]" \
        "	clean = git-lfs clean -- %f" \
        "	required = true" \
        "[user]" \
        "	name = Synthetic" > "$src/config"
    out=$(GIT_CONFIG_SOURCE_DIR="$src" HOME="$home" /usr/local/share/nshafer-git-config/post-create.sh 2>&1)
    g() { HOME="$home" git config --global --get "$1" 2>/dev/null || true; }
    [ -z "$(g core.editor)" ]        || { echo "core.editor survived"; exit 1; }
    [ -z "$(g gpg.program)" ]        || { echo "gpg.program survived"; exit 1; }
    [ -z "$(g http.sslBackend)" ]    || { echo "http.sslBackend survived"; exit 1; }
    [ "$(g core.sshCommand)" = cat ] || { echo "core.sshCommand was dropped"; exit 1; }
    [ "$(g user.name)" = Synthetic ] || { echo "unrelated config lost"; exit 1; }
    # The lfs filter is deliberately left in place: its failure is the signal to install git-lfs.
    [ "$(g filter.lfs.required)" = true ] || { echo "lfs filter was stripped"; exit 1; }
    echo "$out" | grep -q "definitely-not-installed-xyz is not installed" || { echo "no reason given"; exit 1; }
    exit 0'

# The regression check for the readonly flag smuggled through the mount target. Read from
# /proc/mounts rather than by attempting a write: if the flag ever stops being honored, a probe
# write would land in the host's real git directory.
check "the host mount is read-only" bash -c '
    opts=$(awk "\$2 == \"/mnt/git-config\" { print \$4 }" /proc/mounts | tail -n1)
    [ -n "$opts" ] || { echo "/mnt/git-config is not a mount point"; exit 1; }
    case ",$opts," in *,ro,*) exit 0;; esac
    echo "/mnt/git-config is mounted $opts"; exit 1'

check "leaves the host mount untouched" bash -c '
    after=$(find /mnt/git-config -type f -exec md5sum {} + | sort; find /mnt/git-config -exec stat -c "%n %Y %a" {} + | sort)
    [ "'"$before"'" = "$after" ] || { diff <(printf "%s\n" "'"$before"'") <(printf "%s\n" "$after"); exit 1; }'

check "is idempotent" bash -c '
    a=$(md5sum < "$HOME/.config/git/config")
    /usr/local/share/nshafer-git-config/post-create.sh >/dev/null
    [ "$a" = "$(md5sum < "$HOME/.config/git/config")" ]'

check "will not clobber a file it did not write" bash -c '
    echo "not ours" > "$HOME/.config/git/ignore"
    /usr/local/share/nshafer-git-config/post-create.sh 2>&1 | grep -q "leaving it alone"
    [ "$(cat "$HOME/.config/git/ignore")" = "not ours" ]'

reportResults
