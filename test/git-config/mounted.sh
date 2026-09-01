#!/usr/bin/env bash
# The mount is declared by this scenario and not by the feature, which is the point of the whole
# arrangement: a feature's own mount metadata has no read-only field, and every workaround for that
# is mode-dependent -- see the mount note in the feature's NOTES.md. So the suite declares the mount
# the way a user does, and every check that reads the host's real git directory lives here.
#
# Assertions compare against the mounted host files rather than hardcoding values, so they hold on
# any machine. Nothing here writes to /mnt/git-config: that is the host's own git directory. It is
# mounted read-only, and the snapshot below still holds the run to leaving it alone.
set -e
source dev-container-features-test-lib

before=$(find /mnt/git-config -type f -exec md5sum {} + | sort; find /mnt/git-config -exec stat -c '%n %Y %a' {} + | sort)

/usr/local/share/devcontainer/git-config/post-create.sh

check "config was copied" test -s "$HOME/.config/git/config"
check "excludes file was copied" test -s "$HOME/.config/git/ignore"

check "copied config matches the host's values" bash -c '
    want=$(git config -f /mnt/git-config/config --get user.name || true)
    [ -z "$want" ] || [ "$(git config --global --get user.name)" = "$want" ]'

# credential sections are the one thing that does not travel, so they come off the host side of
# this comparison. test.sh drives that removal with a source of its own.
check "sections are copied verbatim, filters included" bash -c '
    diff <(tail -n +2 "$HOME/.config/git/config" | grep "^\[") \
         <(grep "^\[" /mnt/git-config/config | grep -Ev "^\[credential( |\])")'

check "no credential section reaches the container" bash -c '
    ! grep -qE "^\[credential( |\])" "$HOME/.config/git/config"'

check "git honors the copied excludes" bash -c '
    v=$(git config --global --get core.excludesfile || true)
    f="${v:+${v/#\~/$HOME}}"; f="${f:-$HOME/.config/git/ignore}"; [ -f "$f" ] || exit 0
    # Needs a literal pattern: no trailing slash, since a directory-only pattern cannot match a
    # path that does not exist, and no glob characters.
    pat=$(grep -m1 -E "^[^#[:space:]/*?![]+$" "$f"); [ -n "$pat" ] || exit 0
    d=$(mktemp -d) && cd "$d" && git init -q .
    git check-ignore -q "$pat"'

# The regression check for the readonly flag on the mount string this scenario declares. Read from
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
    /usr/local/share/devcontainer/git-config/post-create.sh >/dev/null
    [ "$a" = "$(md5sum < "$HOME/.config/git/config")" ]'

check "will not clobber a file it did not write" bash -c '
    echo "not ours" > "$HOME/.config/git/ignore"
    /usr/local/share/devcontainer/git-config/post-create.sh 2>&1 | grep -q "leaving it alone"
    [ "$(cat "$HOME/.config/git/ignore")" = "not ours" ]'

reportResults
