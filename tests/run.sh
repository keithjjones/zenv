#!/bin/sh
# zenv test harness.
#
# Runs every tests/test_*.sh under sh, bash and zsh, and asserts the real
# ~/zeek, ~/.zkg and ~/zenv were not touched by any of it.
#
#   tests/run.sh                       everything, all three shells
#   tests/run.sh --shells sh            one shell
#   tests/run.sh --only path            only cases whose name contains "path"
#   tests/run.sh --hostile              sandbox path with a space and a quote
#   tests/run.sh --keep                 leave sandboxes behind for inspection
#   tests/run.sh tests/test_paths.sh    specific files
#
# Exit 0 only if every case passed in every shell and the guard stayed quiet.

set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
REAL_HOME=$HOME
ZENV_BIN=$REPO_ROOT/bin/zenv
export REPO_ROOT REAL_HOME ZENV_BIN

SHELLS=
ONLY=
HOSTILE=
KEEP=
FILES=

while [ $# -gt 0 ]; do
    case $1 in
        --shells)
            SHELLS=$2
            shift 2
            ;;
        --shells=*)
            SHELLS=${1#--shells=}
            shift
            ;;
        --only)
            ONLY=$2
            shift 2
            ;;
        --only=*)
            ONLY=${1#--only=}
            shift
            ;;
        --hostile)
            HOSTILE=1
            shift
            ;;
        --keep)
            KEEP=1
            shift
            ;;
        -h | --help)
            sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --*)
            printf 'run.sh: unknown option %s\n' "$1" >&2
            exit 2
            ;;
        *)
            FILES="$FILES $1"
            shift
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Which shells
# ---------------------------------------------------------------------------

if [ -z "$SHELLS" ]; then
    SHELLS="sh bash zsh"
fi

RESOLVED_SHELLS=
for s in $SHELLS; do
    p=$(command -v "$s" 2>/dev/null) || p=
    if [ -z "$p" ]; then
        printf 'run.sh: %s not found, skipping\n' "$s" >&2
        continue
    fi
    RESOLVED_SHELLS="$RESOLVED_SHELLS $p"
done
if [ -z "$RESOLVED_SHELLS" ]; then
    printf 'run.sh: no usable shells\n' >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Which files
# ---------------------------------------------------------------------------

if [ -z "$FILES" ]; then
    for f in "$REPO_ROOT"/tests/test_*.sh; do
        [ -f "$f" ] || continue
        FILES="$FILES $f"
    done
fi
if [ -z "$FILES" ]; then
    printf 'run.sh: no test files found under %s/tests\n' "$REPO_ROOT" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Run-level scratch, then the guard baseline
# ---------------------------------------------------------------------------

RUNDIR=$(mktemp -d "${TMPDIR:-/tmp}/zenv-run.XXXXXX")
export RUNDIR

if [ -n "$HOSTILE" ]; then
    # A path with a space and an apostrophe, to run the whole suite against the
    # quoting hazard rather than testing it once.
    hostile_parent="$RUNDIR/zenv sb/it's"
    mkdir -p "$hostile_parent"
    ZENV_TEST_TMPL="$hostile_parent/sb.XXXXXX"
elif [ -z "${ZENV_TEST_TMPL:-}" ]; then
    # An inherited value is honoured: the selftest points sandboxes into its own
    # work dir so it can assert they were cleaned up.
    ZENV_TEST_TMPL="${TMPDIR:-/tmp}/zenv-sb.XXXXXX"
fi
export ZENV_TEST_TMPL

[ -n "$ONLY" ] && export ZENV_TEST_ONLY="$ONLY"
[ -n "$KEEP" ] && export ZENV_TEST_KEEP=1

cleanup() {
    if [ -n "$KEEP" ]; then
        # --keep retains the harness scratch too; say so rather than leaking it.
        printf 'kept run dir: %s\n' "$RUNDIR" >&2
        return 0
    fi
    rm -rf "$RUNDIR"
}

# ZENV_ROOT must not leak in from the caller's environment: every case sets its
# own inside its sandbox, and an inherited one would be a live escape route.
unset ZENV_ROOT 2>/dev/null || true

# Bring in guard_init/guard_check. lib.sh is written to be sourced repeatedly.
. "$REPO_ROOT/tests/lib.sh"

guard_init

printf 'zenv tests\n'
printf '  repo:   %s\n' "$REPO_ROOT"
printf '  shells:%s\n' "$RESOLVED_SHELLS"
printf '  home:   %s (guarded)\n' "$REAL_HOME"
[ -n "$HOSTILE" ] && printf '  mode:   hostile sandbox paths\n'
[ -n "$ONLY" ] && printf '  only:   %s\n' "$ONLY"
printf '\n'

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

files_run=0
files_failed=0

for sh_path in $RESOLVED_SHELLS; do
    sh_name=$(basename "$sh_path")
    printf '=== %s (%s)\n' "$sh_name" "$sh_path"
    for f in $FILES; do
        if [ ! -f "$f" ]; then
            printf 'run.sh: no such test file: %s\n' "$f" >&2
            files_failed=$((files_failed + 1))
            continue
        fi
        files_run=$((files_run + 1))
        if ! "$sh_path" "$f"; then
            files_failed=$((files_failed + 1))
        fi
    done
    printf '\n'
done

# ---------------------------------------------------------------------------
# Guard, then verdict
# ---------------------------------------------------------------------------

guard_rc=0
guard_check || guard_rc=$?

printf -- '---\n'
printf 'files run: %s   files with failures: %s\n' "$files_run" "$files_failed"

if [ "$guard_rc" = 1 ]; then
    printf 'ESCAPE GUARD TRIPPED: the real home was modified. See above.\n' >&2
    cleanup
    exit 3
fi
if [ "$guard_rc" = 2 ]; then
    # Not the suite -- see the guard's own note above and the reasoning in lib.sh.
    printf 'escape guard: %s not touched by the suite (external activity noted above)\n' \
        "$REAL_HOME"
else
    printf 'escape guard: clean (%s untouched)\n' "$REAL_HOME"
fi

if [ "$files_failed" != 0 ]; then
    cleanup
    exit 1
fi
printf 'all tests passed\n'
cleanup
exit 0
