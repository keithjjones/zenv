#!/bin/sh
# Tests the test harness. This is step A's gate: it proves that run.sh actually
# reports failures and that the escape guard actually trips -- the two things a
# green suite would otherwise be silently lying about.
#
# Every case runs run.sh with HOME pointed at a *fake* home containing fake
# zeek/ and .zkg/ trees. run.sh derives REAL_HOME from HOME, so the "escaping"
# cases trip the guard against the fake tree and the real ~/zeek is never at
# risk. Each inner run also gets its own TMPDIR, so the selftest can assert that
# a run leaves no temporary artifacts behind -- and never litters the real one.
#
# Run by `make selftest`; deliberately not part of `make test`, because these
# cases are supposed to fail and a failing suite has to stay meaningful.
#
# shellcheck disable=SC2016
#   Single-quoted `$` in this file is shell code for another shell to expand,
#   or the literal text an assertion looks for. Expanding it in this process is
#   the bug these cases exist to catch.

set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
RUN="$REPO_ROOT/tests/run.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/zenv-selftest.XXXXXX")
trap 'cd /; rm -rf "$WORK"' EXIT INT TERM

fails=0
checks=0

check() {
    # check <description> <condition-result>
    checks=$((checks + 1))
    if [ "$2" = 0 ]; then
        printf '  ok    %s\n' "$1"
    else
        printf '  FAIL  %s\n' "$1"
        fails=$((fails + 1))
    fi
}

# A condition for `check "..." $?`, as a function rather than a bare `[ ... ]`.
# The status of a plain `[` is fragile in exactly this position: the moment a
# description grows a `$(...)`, the substitution runs during argument expansion
# and overwrites the `$?` the check was about. Going through a command makes that
# impossible, and reads like the contains/lacks/matches lines below.
cond() { test "$@"; }

contains() {
    case "$1" in
        *"$2"*) return 0 ;;
    esac
    return 1
}

lacks() {
    case "$1" in
        *"$2"*) return 1 ;;
    esac
    return 0
}

# For result lines, whose column padding is a formatting detail the selftest
# should not be pinned to.
matches() { printf '%s\n' "$1" | grep -qE "$2"; }

count_in() { find "$1" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '; }

# A fake "real home" with the three guarded paths present and populated.
FAKE_HOME="$WORK/fakehome"
mkdir -p "$FAKE_HOME/zeek/share/zeek/site/packages" \
         "$FAKE_HOME/zeek/lib/zeek/plugins/packages" \
         "$FAKE_HOME/.zkg/clones/source/zeek/.git"
printf 'original\n' >"$FAKE_HOME/zeek/share/zeek/site/packages/packages.zeek"
# zkg's real layout: the autoloader zeek reads is a *symlink* to the file zkg
# rewrites. The guard has to snapshot both, or a login shell's no-op rewrite of
# the target leaves the link unexplainable.
ln -s packages.zeek "$FAKE_HOME/zeek/share/zeek/site/packages/__load__.zeek"
printf '{"installed_packages": []}\n' >"$FAKE_HOME/.zkg/manifest.json"
# A package source clone, so the guard's "outside activity" classification has
# something to classify: a real `zkg env` refreshes exactly this.
printf 'idx1\n' >"$FAKE_HOME/.zkg/clones/source/zeek/.git/index"

snap() { find "$FAKE_HOME" | LC_ALL=C sort; }

CASES="$WORK/cases"
mkdir -p "$CASES"

# --- the generated test files ----------------------------------------------

# 1. Passes. Proves a green run is reachable at all, so a red one means something.
cat >"$CASES/test_selftest_pass.sh" <<'EOF'
#!/bin/sh
. "$REPO_ROOT/tests/lib.sh"

test_sandbox_is_isolated() {
    assert_dir "$SANDBOX" "sandbox should exist"
    assert_eq "$SANDBOX/home" "$HOME" "HOME should be inside the sandbox"
    assert_ne "$REAL_HOME" "$HOME" "HOME must not be the real home"
}

test_writing_in_the_sandbox_is_fine() {
    mkdir -p "$HOME/zeek/share"
    printf 'hello\n' >"$HOME/zeek/share/f"
    assert_file "$HOME/zeek/share/f"
}

run_cases
EOF

# 2. Deliberately failing assertions, one per assertion family. Proves failures
#    are reported per case, with detail, and set run.sh's exit status.
cat >"$CASES/test_selftest_fails.sh" <<'EOF'
#!/bin/sh
. "$REPO_ROOT/tests/lib.sh"

test_deliberate_assert_eq_failure() {
    assert_eq "expected-value" "actual-value" "this failure is intentional"
}

test_deliberate_missing_file_failure() {
    assert_file "$SANDBOX/definitely-not-here" "intentional missing-file failure"
}

test_deliberate_nonzero_exit() {
    return 7
}

test_this_one_passes_anyway() {
    assert_eq a a
}

run_cases
EOF

# 3. Escapes by creating a new path in the real home. No failing assertions, so
#    only the guard can catch it.
cat >"$CASES/test_selftest_escape_new.sh" <<'EOF'
#!/bin/sh
. "$REPO_ROOT/tests/lib.sh"

test_escapes_by_creating_a_path() {
    mkdir -p "$REAL_HOME/zeek/share/zeek/site/packages"
    printf 'escaped\n' >"$REAL_HOME/zeek/share/zeek/site/packages/intruder"
    assert_eq a a
}

run_cases
EOF

# 4. Escapes by rewriting an existing file, leaving the path set identical.
#    Only the mtime arm of the guard can catch this one.
cat >"$CASES/test_selftest_escape_modify.sh" <<'EOF'
#!/bin/sh
. "$REPO_ROOT/tests/lib.sh"

test_escapes_by_modifying_a_file() {
    printf 'clobbered\n' >"$REAL_HOME/zeek/share/zeek/site/packages/packages.zeek"
    assert_eq a a
}

run_cases
EOF

# 5. Reports which shell it ran under, so the multi-shell check can prove each
#    shell really executed the cases rather than just printing a banner.
# Records to a log outside the sandbox, because a *passing* case's output is
# deliberately discarded by the harness -- so the log is the only way to prove
# which shells really executed it.
cat >"$CASES/test_selftest_shellid.sh" <<'EOF'
#!/bin/sh
. "$REPO_ROOT/tests/lib.sh"

test_reports_its_shell() {
    if [ -n "${ZSH_VERSION:-}" ]; then
        printf 'ran under zsh %s\n' "$ZSH_VERSION" >>"$ZENV_SELFTEST_LOG"
    elif [ -n "${BASH_VERSION:-}" ]; then
        printf 'ran under bash %s\n' "$BASH_VERSION" >>"$ZENV_SELFTEST_LOG"
    else
        printf 'ran under a plain sh\n' >>"$ZENV_SELFTEST_LOG"
    fi
    assert_eq a a
}

run_cases
EOF

# 6. Touches the real home the way something *outside* the suite does: a login
#    shell running `eval `zkg env`` (~/.zprofile) rewrites zkg's autoloader with
#    the bytes already there and refreshes the source clone's git bookkeeping.
#    Nothing is lost, so the guard must report it and let the run stand -- else
#    opening a terminal during a twenty-minute run fails the whole suite.
cat >"$CASES/test_selftest_external_touch.sh" <<'EOF'
#!/bin/sh
. "$REPO_ROOT/tests/lib.sh"

test_touches_the_real_home_the_way_a_login_shell_does() {
    printf 'original\n' >"$REAL_HOME/zeek/share/zeek/site/packages/packages.zeek"
    printf 'idx2\n' >"$REAL_HOME/.zkg/clones/source/zeek/.git/index"
    assert_eq a a
}

run_cases
EOF

chmod +x "$CASES"/*.sh

harness_n=0
run_harness() {
    # run_harness <run.sh args...> ; sets HARNESS_OUT, HARNESS_RC, HARNESS_TMP
    harness_n=$((harness_n + 1))
    HARNESS_TMP="$WORK/tmp.$harness_n"
    mkdir -p "$HARNESS_TMP"
    HARNESS_OUT=$(HOME="$FAKE_HOME" TMPDIR="$HARNESS_TMP" "$RUN" "$@" 2>&1)
    HARNESS_RC=$?
}

# ---------------------------------------------------------------------------

printf 'selftest: harness reports passes\n'
before=$(snap)
run_harness --shells sh "$CASES/test_selftest_pass.sh"
cond "$HARNESS_RC" = 0; check "a passing file exits 0 (got $HARNESS_RC)" $?
matches "$HARNESS_OUT" '^  test_sandbox_is_isolated +ok$'
check "per-case ok lines are printed" $?
contains "$HARNESS_OUT" 'all tests passed'; check "final verdict is printed" $?
contains "$HARNESS_OUT" 'escape guard: clean'; check "guard reports clean" $?
cond "$before" = "$(snap)"; check "a passing run leaves the real home alone" $?

printf 'selftest: a run leaves no temporary artifacts behind\n'
n=$(count_in "$HARNESS_TMP")
cond "$n" = 0; check "no run dir or sandbox left in TMPDIR (found $n)" $?
lacks "$HARNESS_OUT" 'refusing to remove'
check "teardown recognised its own sandboxes" $?

printf 'selftest: --keep keeps them, and says where\n'
run_harness --shells sh --keep "$CASES/test_selftest_pass.sh"
cond "$HARNESS_RC" = 0; check "--keep run exits 0 (got $HARNESS_RC)" $?
n=$(count_in "$HARNESS_TMP")
# One run dir plus one sandbox per case.
cond "$n" = 3; check "--keep retains 1 run dir + 2 sandboxes (found $n)" $?
contains "$HARNESS_OUT" 'kept sandbox:'; check "--keep names the sandboxes" $?
contains "$HARNESS_OUT" 'kept run dir:'; check "--keep names the run dir" $?

printf 'selftest: an inherited ZENV_TEST_TMPL is honoured\n'
SBDIR="$WORK/custom-sandboxes"
mkdir -p "$SBDIR"
# Compare against the physical path: the harness resolves sandboxes with pwd -P,
# and on macOS $TMPDIR lives under /var -> /private/var.
SBDIR_P=$(cd -P "$SBDIR" && pwd -P)
HARNESS_TMP="$WORK/tmp.tmpl"; mkdir -p "$HARNESS_TMP"
HARNESS_OUT=$(HOME="$FAKE_HOME" TMPDIR="$HARNESS_TMP" \
    ZENV_TEST_TMPL="$SBDIR/sb.XXXXXX" \
    "$RUN" --shells sh --keep "$CASES/test_selftest_pass.sh" 2>&1)
n=$(count_in "$SBDIR")
cond "$n" = 2; check "sandboxes went to the requested parent (found $n)" $?
contains "$HARNESS_OUT" "$SBDIR_P"; check "and are reported from there" $?
rm -rf "$SBDIR"

printf 'selftest: --hostile really uses a hostile path\n'
run_harness --shells sh --hostile --keep "$CASES/test_selftest_pass.sh"
cond "$HARNESS_RC" = 0; check "hostile run exits 0 (got $HARNESS_RC)" $?
contains "$HARNESS_OUT" "zenv sb/it's"
check "sandbox paths contain a space and an apostrophe" $?
contains "$HARNESS_OUT" 'hostile sandbox paths'; check "and the mode is announced" $?
lacks "$HARNESS_OUT" 'refusing to remove'
check "teardown still recognises a hostile sandbox path" $?

printf 'selftest: the same file runs under every available shell\n'
ZENV_SELFTEST_LOG="$WORK/shells.log"
export ZENV_SELFTEST_LOG
: >"$ZENV_SELFTEST_LOG"
run_harness "$CASES/test_selftest_shellid.sh"
cond "$HARNESS_RC" = 0; check "multi-shell run exits 0 (got $HARNESS_RC)" $?
n_shells=0
for want in sh bash zsh; do
    command -v "$want" >/dev/null 2>&1 || continue
    n_shells=$((n_shells + 1))
    matches "$HARNESS_OUT" "^=== $want \(/"
    check "$want section is present" $?
done
n_ok=$(printf '%s\n' "$HARNESS_OUT" | grep -cE ' +ok$')
cond "$n_ok" = "$n_shells"
check "the case ran once per shell ($n_ok runs, $n_shells shells)" $?
# The zsh leg once ran zero cases because zsh rebinds $0 in a sourced file, so
# the banner alone is not evidence. The log is written from inside the case.
shell_log=$(cat "$ZENV_SELFTEST_LOG")
n_logged=$(printf '%s\n' "$shell_log" | grep -c 'ran under')
cond "$n_logged" = "$n_shells"
check "every shell reached the case body ($n_logged of $n_shells)" $?
if command -v zsh >/dev/null 2>&1; then
    contains "$shell_log" 'ran under zsh'
    check "zsh really executed the case, not just printed a banner" $?
fi
contains "$shell_log" 'ran under bash'; check "bash really executed it" $?
lacks "$HARNESS_OUT" 'no test_* functions found'
check "no shell silently discovered zero cases" $?

printf 'selftest: harness reports failures\n'
run_harness --shells sh "$CASES/test_selftest_fails.sh"
cond "$HARNESS_RC" = 1; check "a failing file exits 1 (got $HARNESS_RC)" $?
contains "$HARNESS_OUT" 'test_deliberate_assert_eq_failure'
check "the failing case is named" $?
matches "$HARNESS_OUT" '^  test_deliberate_assert_eq_failure +FAIL$'
check "the failing case is marked FAIL, not ok" $?
contains "$HARNESS_OUT" 'this failure is intentional'
check "the assertion message is shown" $?
contains "$HARNESS_OUT" 'expected: [expected-value]'
check "expected value is shown" $?
contains "$HARNESS_OUT" 'actual:   [actual-value]'
check "actual value is shown" $?
contains "$HARNESS_OUT" 'intentional missing-file failure'
check "assert_file failure is shown" $?
contains "$HARNESS_OUT" 'exited 7 with no assertion failure'
check "a bare nonzero return is caught" $?
matches "$HARNESS_OUT" '^  test_this_one_passes_anyway +ok$'
check "a passing case in a failing file still passes" $?
contains "$HARNESS_OUT" '3 failed'; check "the tally counts 3 failures" $?
contains "$HARNESS_OUT" '1 passed'; check "the tally counts 1 pass" $?
contains "$HARNESS_OUT" 'escape guard: clean'
check "assertion failures do not trip the guard" $?
lacks "$HARNESS_OUT" 'all tests passed'
check "a failing run does not claim success" $?

printf 'selftest: escape guard trips on a new path\n'
run_harness --shells sh "$CASES/test_selftest_escape_new.sh"
cond "$HARNESS_RC" = 3; check "an escaping file exits 3 (got $HARNESS_RC)" $?
contains "$HARNESS_OUT" 'ESCAPE GUARD'; check "the guard announces itself" $?
contains "$HARNESS_OUT" 'the set of real paths changed'
check "the path-set arm fires" $?
contains "$HARNESS_OUT" 'intruder'; check "the offending path is named" $?
lacks "$HARNESS_OUT" 'escape guard: clean'
check "a tripped guard does not also report clean" $?
cond -f "$FAKE_HOME/zeek/share/zeek/site/packages/intruder"
check "the case really did escape (so the guard was needed)" $?
rm -f "$FAKE_HOME/zeek/share/zeek/site/packages/intruder"

printf 'selftest: escape guard trips on an in-place modification\n'
before=$(snap)
run_harness --shells sh "$CASES/test_selftest_escape_modify.sh"
cond "$HARNESS_RC" = 3; check "an in-place clobber exits 3 (got $HARNESS_RC)" $?
contains "$HARNESS_OUT" 'modified under'; check "the mtime arm fires" $?
contains "$HARNESS_OUT" 'packages.zeek'; check "the modified file is named" $?
cond "$before" = "$(snap)"
check "the path set was unchanged, so only mtime could catch it" $?
cond "$(cat "$FAKE_HOME/zeek/share/zeek/site/packages/packages.zeek")" = clobbered
check "the case really did clobber the file" $?
printf 'original\n' >"$FAKE_HOME/zeek/share/zeek/site/packages/packages.zeek"

printf 'selftest: the guard separates outside activity from an escape\n'
before=$(snap)
run_harness --shells sh "$CASES/test_selftest_external_touch.sh"
cond "$HARNESS_RC" = 0
check "activity the suite cannot produce does not fail the run (got $HARNESS_RC)" $?
contains "$HARNESS_OUT" 'GUARD NOTE'; check "but it is still reported" $?
contains "$HARNESS_OUT" 'not touched by the suite'
check "and the verdict says whose it was" $?
lacks "$HARNESS_OUT" 'ESCAPE GUARD'; check "and it is not called an escape" $?
cond "$before" = "$(snap)"
check "the path set was unchanged, so only mtime saw it" $?
cond "$(cat "$FAKE_HOME/.zkg/clones/source/zeek/.git/index")" = idx2
check "the case really did touch the clone (so the guard saw something)" $?
printf 'idx1\n' >"$FAKE_HOME/.zkg/clones/source/zeek/.git/index"

printf 'selftest: bad invocations fail loudly\n'
run_harness --shells sh "$CASES/test_nope.sh"
cond "$HARNESS_RC" = 1; check "a nonexistent file fails the run (got $HARNESS_RC)" $?
contains "$HARNESS_OUT" 'no such test file'; check "and says so" $?

printf '#!/bin/sh\n. "$REPO_ROOT/tests/lib.sh"\nrun_cases\n' \
    >"$CASES/test_selftest_empty.sh"
run_harness --shells sh "$CASES/test_selftest_empty.sh"
cond "$HARNESS_RC" = 1; check "an empty test file fails the run (got $HARNESS_RC)" $?
contains "$HARNESS_OUT" 'no test_* functions found'; check "and says why" $?

run_harness --shells sh --bogus-flag "$CASES/test_selftest_pass.sh"
cond "$HARNESS_RC" = 2; check "an unknown option exits 2 (got $HARNESS_RC)" $?

printf 'selftest: an inherited ZENV_ROOT cannot leak into the sandbox\n'
HARNESS_TMP="$WORK/tmp.leak"; mkdir -p "$HARNESS_TMP"
HARNESS_OUT=$(HOME="$FAKE_HOME" TMPDIR="$HARNESS_TMP" \
    ZENV_ROOT="$FAKE_HOME/zenv" \
    "$RUN" --shells sh "$CASES/test_selftest_pass.sh" 2>&1)
HARNESS_RC=$?
cond "$HARNESS_RC" = 0; check "run survives a hostile inherited ZENV_ROOT" $?
lacks "$HARNESS_OUT" 'GUARD'; check "and it is not used (no guard trip)" $?
cond ! -e "$FAKE_HOME/zenv"; check "the inherited root was never created" $?

printf '\nselftest: %s checks, %s failed\n' "$checks" "$fails"
[ "$fails" = 0 ]
