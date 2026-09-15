#!/bin/sh
# Undo install.sh. Every flag is passed straight through to `zenv uninstall`:
#
#   ./uninstall.sh --dry-run    the inventory, with nothing removed
#   ./uninstall.sh              remove zenv, keeping the installs you built
#   ./uninstall.sh --purge      remove those too
#
# There is no logic here on purpose. The installed script is the one that knows
# which root *it* was installed with (that value is baked into it), and it is the
# only copy guaranteed to still exist after the checkout is deleted or moved --
# so it does the work, and this file only finds it.
#
# With nothing installed this is a no-op that exits 0, so it is safe to rerun and
# safe to call unconditionally from a script.

set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)

FOUND=
for zenv in \
    "$(command -v zenv 2>/dev/null || true)" \
    "${HOME:-}/.local/bin/zenv" \
    "$HERE/bin/zenv"; do
    [ -n "$zenv" ] || continue
    [ -x "$zenv" ] || continue
    FOUND=$zenv
    break
done

if [ -n "$FOUND" ]; then
    exec "$FOUND" uninstall "$@"
fi

# A checkout whose bin/zenv is there but not runnable is a broken checkout, not a
# clean machine, and the two must not report the same thing: the first is
# something to fix, the second is the state being asked for.
if [ -e "$HERE/bin/zenv" ]; then
    printf 'uninstall.sh: %s is not executable, so it cannot do the removal\n' \
        "$HERE/bin/zenv" >&2
    printf "uninstall.sh: 'chmod +x %s' then try again\\n" "$HERE/bin/zenv" >&2
    exit 1
fi

# No zenv on PATH, none in ~/.local/bin, none beside this script: there is
# nothing installed to remove, which is the state `uninstall` was asked to
# produce. Exit 0 so a script or a make target can run this unconditionally.
printf 'uninstall.sh: found no zenv (looked on PATH, in %s, and %s)\n' \
    "${HOME:-\$HOME}/.local/bin/zenv" "$HERE/bin/zenv" >&2
printf 'uninstall.sh: nothing is installed, so there is nothing to undo.\n' >&2
exit 0
