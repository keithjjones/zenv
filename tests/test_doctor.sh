#!/bin/sh
# Step F's gate: `zenv doctor` and `zenv status`.
#
# Covers plan test 10 -- the mismatched baked prefix, the stale manifest.json,
# ZEEK_BUILD_DIR set in the environment, and each of the five zeek_dist states
# with only *drifted* raising a warning -- plus the exit-code contract that makes
# doctor usable from a script: 0 clean, 1 warnings, 2 errors.
#
# Two rules run through the whole file. First, doctor must never invoke zkg:
# constructing zkg's Manager is itself the relocation-and-delete hazard doctor
# exists to report, so a diagnostic that triggered it would be worse than no
# diagnostic. Every case that has a zkg available asserts it stayed unused.
# Second, severity is a promise, not a mood: a warning means "works, but know
# this", an error means "this will fail or destroy state".
#
# shellcheck disable=SC2016
#   Single-quoted `$` in this file is shell code for another shell to expand,
#   or the literal text an assertion looks for. Expanding it in this process is
#   the bug these cases exist to catch.
#
# shellcheck disable=SC2119,SC2120
#   The assert_* helpers take an optional extra message that is normally absent;
#   "referenced but never passed" is the cost of a label only attached when there
#   is something extra to say, and shellcheck cannot see it as optional.

. "$REPO_ROOT/tests/lib.sh"

# ---------------------------------------------------------------------------
# Local helpers
# ---------------------------------------------------------------------------

# The interpreter running this file, so emitted code is eval'd by the shell the
# case is exercising. Mirrors test_shell.sh's copy.
_probe_shell() {
    if [ -n "${ZSH_VERSION:-}" ]; then
        command -v zsh
    elif [ -n "${BASH_VERSION:-}" ]; then
        command -v bash
    else
        printf '/bin/sh\n'
    fi
}
PROBE_SHELL=$(_probe_shell)
sh_probe() { probe "$PROBE_SHELL" "$1"; }
act_line() { printf 'eval "$("$ZENV_BIN" shell activate %s)"' "$1"; }

# An environment with a fake install in it.
# Usage: mkenv <name> [mkprefix key=value ...]
mkenv() {
    _men=$1
    shift
    zenv new "$_men" >/dev/null 2>&1 || {
        fail "mkenv: zenv new $_men failed"
        return 1
    }
    mkprefix "$ZENV_ROOT/$_men/zeek" "$@"
}

# An environment with its zkg wired up by zenv itself, using the env's own
# bundled zkg -- what a doctor-clean environment looks like. The stub's log is
# truncated afterwards so the "doctor invoked no zkg" assertions see only what
# doctor did, not what the fixture did.
# Usage: mkwired <name> [mkprefix key=value ...]
mkwired() {
    _mwn=$1
    shift
    mkenv "$_mwn" "$@" || return 1
    mkzkgstub "$ZENV_ROOT/$_mwn/zeek/bin/zkg"
    zenv autoconfig "$_mwn" >/dev/null 2>&1 \
        || fail "mkwired: zenv autoconfig $_mwn failed"
    : >"$ZKG_STUB_LOG"
}

# Run doctor keeping both streams and the exit code: REPORT is the report itself
# (stdout), ERR anything it said on stderr, DSTATUS the contract's exit code.
doctor() {
    if capture zenv doctor "$@"; then
        DSTATUS=0
    else
        DSTATUS=$?
    fi
    REPORT=$OUT
    return 0
}

# A key's value in an env's zkg config.
cfg_get() { zenv_lib 'printf "%s" "$(_ini_get "$1" "$2")"' "$1" "$2"; }

# Rewrite one key in an env's zkg config.
cfg_set() {
    zenv_lib '_ini_set "$1" paths "$2" "$3"' "$1" "$2" "$3"
}

# Write a manifest.json with the three path keys set as given.
mkmanifest() {
    _mmf=$1
    mkdir -p "$(dirname "$_mmf")"
    {
        printf '{\n'
        printf '    "manifest_version": 1,\n'
        printf '    "installed_packages": [],\n'
        printf '    "script_dir": "%s",\n' "$2"
        printf '    "plugin_dir": "%s",\n' "$3"
        printf '    "bin_dir": "%s"\n' "$4"
        printf '}\n'
    } >"$_mmf"
}

# The manifest an env's own config implies: zkg appends /packages to the script
# and plugin directories and stores bin_dir as it is.
mkmanifest_agreeing() {
    _man=$ZENV_ROOT/$1/zkg/manifest.json
    _mac=$ZENV_ROOT/$1/zkg/config
    cfg_get "$_mac" script_dir
    _mas=$OUT
    cfg_get "$_mac" plugin_dir
    _map=$OUT
    cfg_get "$_mac" bin_dir
    _mab=$OUT
    mkmanifest "$_man" "$_mas/packages" "$_map/packages" "$_mab"
}

# A python3 on PATH that answers doctor's import probe as told and defers every
# other call to the real interpreter, so manifest reading still works.
# Usage: mkpython ok|fail
mkpython() {
    # Resolved without $SANDBOX/bin on PATH, so a second call could never point
    # the wrapper at itself. The system part of the case PATH is what the harness
    # gives every case, and reading manifest.json already depends on it.
    _mpreal=$(PATH=/usr/bin:/bin:/usr/sbin:/sbin command -v python3 2>/dev/null) \
        || _mpreal=
    [ -n "$_mpreal" ] || {
        fail "mkpython: no python3 in /usr/bin or /bin"
        return 1
    }
    {
        printf '#!/bin/sh\n'
        printf 'if [ "${1:-}" = "-c" ] && [ "${2:-}" = "import git, semantic_version" ]; then\n'
        if [ "$1" = ok ]; then
            printf '    exit 0\n'
        else
            printf '    echo "ModuleNotFoundError: No module named git" >&2\n'
            printf '    exit 1\n'
        fi
        printf 'fi\n'
        printf 'exec %s "$@"\n' "$(quote_sh "$_mpreal")"
    } >"$SANDBOX/bin/python3"
    chmod +x "$SANDBOX/bin/python3"
}

# Replace a script's shebang line, leaving the body alone.
setshebang() {
    { printf '%s\n' "$2"; tail -n +2 "$1"; } >"$1.new" \
        && mv "$1.new" "$1"
    chmod +x "$1"
}

# Stubs for every build tool, to prove behaviourally that no zenv command runs
# one. Mirrors test_links.sh's copy.
mkbuildstubs() {
    BUILD_STUB_LOG="$SANDBOX/buildtools.log"
    export BUILD_STUB_LOG
    for _t in configure make gmake cmake ninja cc gcc clang c++ g++ clang++; do
        {
            printf '#!/bin/sh\n'
            printf 'printf "%%s %%s\\n" %s "$*" >>"$BUILD_STUB_LOG"\n' "$(quote_sh "$_t")"
            printf 'exit 0\n'
        } >"$SANDBOX/bin/$_t"
        chmod +x "$SANDBOX/bin/$_t"
    done
}

assert_no_build_tool_ran() {
    if [ ! -f "$BUILD_STUB_LOG" ]; then return 0; fi
    fail "${1:-a build tool was executed}"
    fail_detail "log: $(cat "$BUILD_STUB_LOG")"
    return 1
}

# No line of the report may carry a severity higher than the case allows.
assert_no_findings() {
    assert_not_contains "$REPORT" 'WARN ' "${1:-no warnings}"
    assert_not_contains "$REPORT" 'ERROR ' "${1:-no errors}"
}

# ---------------------------------------------------------------------------
# The exit-code contract
# ---------------------------------------------------------------------------

test_doctor_on_a_clean_environment_exits_zero() {
    mkwired a || return 1
    doctor a
    assert_eq 0 "$DSTATUS" "a clean environment is exit 0"
    assert_contains "$REPORT" 'all checks passed'
    assert_no_findings
}

test_doctor_exits_one_for_warnings_only() {
    mkwired a || return 1
    rm -f "$ZENV_ROOT/a/zkg/config"
    doctor a
    assert_eq 1 "$DSTATUS" "warnings alone are exit 1"
    assert_contains "$REPORT" 'warnings only'
    assert_not_contains "$REPORT" 'ERROR '
}

test_doctor_exits_two_for_errors() {
    mkwired a || return 1
    cfg_set "$ZENV_ROOT/a/zkg/config" state_dir "$SANDBOX/elsewhere"
    doctor a
    assert_eq 2 "$DSTATUS" "an error is exit 2"
    assert_contains "$REPORT" 'errors found'
}

test_doctor_reports_two_when_there_are_both_warnings_and_errors() {
    mkwired a || return 1
    cfg_set "$ZENV_ROOT/a/zkg/config" state_dir "$SANDBOX/elsewhere"
    ZEEK_BUILD_DIR=/somewhere
    export ZEEK_BUILD_DIR
    doctor a
    assert_eq 2 "$DSTATUS" "an error outranks a warning"
    assert_contains "$REPORT" 'WARN '
    assert_contains "$REPORT" 'ERROR '
}

# The rule the file exists for: the command that reports finding 6 must not be
# the command that triggers it.
test_doctor_never_invokes_zkg() {
    mkwired a || return 1
    mkwired b || return 1
    # A zkg on PATH as well, so there are two ways for doctor to slip.
    mkzkgstub "$SANDBOX/bin/zkg"
    mkmanifest "$ZENV_ROOT/b/zkg/manifest.json" /wrong /wrong /wrong
    : >"$ZKG_STUB_LOG"
    doctor
    assert_eq 2 "$DSTATUS" "the planted manifest is an error"
    assert_zkg_never_ran "doctor must not run zkg -- that is the hazard it reports"
}

test_doctor_and_status_run_no_build_tool() {
    mkbuildstubs
    mkwired a || return 1
    doctor a
    capture zenv status a
    assert_no_build_tool_ran "neither doctor nor status may run a build tool"
    # And neither one hands out build advice beyond the --prefix to install into.
    assert_not_contains "$REPORT" 'make ' "doctor names no make invocation"
    assert_not_contains "$REPORT" 'cmake' "doctor names no cmake invocation"
}

# ---------------------------------------------------------------------------
# The baked prefix (finding 1)
# ---------------------------------------------------------------------------

test_doctor_accepts_a_prefix_the_install_agrees_with() {
    mkwired a || return 1
    doctor a
    assert_contains "$REPORT" "ok     baked prefix: $(realpath_p "$ZENV_ROOT/a/zeek")"
    assert_eq 0 "$DSTATUS"
}

test_doctor_warns_when_the_baked_prefix_reaches_the_env_through_a_symlink() {
    # The signature of `zenv adopt --move`: the install still names its old path,
    # which resolves here only while the compatibility symlink is in place.
    mkenv a prefix="$HOME/zeek" || return 1
    ln -s zenv/a/zeek "$HOME/zeek"
    doctor a
    assert_eq 1 "$DSTATUS" "it works, so this is a warning and not an error"
    assert_contains "$REPORT" "baked prefix is $HOME/zeek"
    assert_contains "$REPORT" "'zenv link a' is therefore"
    assert_contains "$REPORT" 'required, not optional'
    assert_not_contains "$REPORT" 'ERROR '
}

test_doctor_errors_when_the_baked_prefix_is_another_environment() {
    mkenv a || return 1
    mkenv b prefix="$ZENV_ROOT/a/zeek" || return 1
    doctor b
    assert_eq 2 "$DSTATUS"
    assert_contains "$REPORT" 'baked prefix is'
    assert_contains "$REPORT" "which is not this environment's directory"
    assert_contains "$REPORT" "belongs to environment 'a'"
}

test_doctor_warns_when_zeek_config_answers_nothing() {
    mkenv a prefix= || return 1
    doctor a
    assert_contains "$REPORT" '--prefix printed nothing'
}

# ---------------------------------------------------------------------------
# Completeness (finding 8) -- "zeek runs" is not evidence the install is usable
# ---------------------------------------------------------------------------

test_doctor_errors_when_the_subproject_headers_are_missing() {
    mkwired a || return 1
    rm -rf "$ZENV_ROOT/a/zeek/include/broker"
    doctor a
    assert_eq 2 "$DSTATUS" "an install that cannot build packages is an error"
    assert_contains "$REPORT" 'include/broker is missing'
    assert_contains "$REPORT" 'broker/expected.hh'
    # The whole point of the check: the install looks fine from the outside.
    assert_contains "$REPORT" "ok     $ZENV_ROOT/a/zeek/bin/zeek --version runs"
}

test_doctor_warns_when_the_include_dir_does_not_exist() {
    mkwired a include_dir="$SANDBOX/gone" || return 1
    doctor a
    assert_contains "$REPORT" "include dir does not exist: $SANDBOX/gone"
    assert_eq 1 "$DSTATUS"
}

test_doctor_errors_when_zeek_will_not_run() {
    mkwired a || return 1
    printf '#!/bin/sh\nexit 1\n' >"$ZENV_ROOT/a/zeek/bin/zeek"
    chmod +x "$ZENV_ROOT/a/zeek/bin/zeek"
    doctor a
    assert_eq 2 "$DSTATUS"
    assert_contains "$REPORT" 'will not run'
    assert_contains "$REPORT" 'absolute'
}

test_doctor_warns_when_there_is_no_zeek_binary() {
    mkwired a || return 1
    rm -f "$ZENV_ROOT/a/zeek/bin/zeek"
    doctor a
    assert_contains "$REPORT" 'no zeek binary at'
    assert_eq 1 "$DSTATUS"
}

# ---------------------------------------------------------------------------
# The layout, and an environment that is not built yet
# ---------------------------------------------------------------------------

test_doctor_treats_an_unbuilt_environment_as_information() {
    zenv new a >/dev/null 2>&1 || return 1
    doctor a
    assert_contains "$REPORT" "info   nothing installed at"
    assert_contains "$REPORT" "--prefix=$(realpath_p "$ZENV_ROOT/a/zeek")"
    assert_contains "$REPORT" "then run 'zenv autoconfig a'"
    assert_not_contains "$REPORT" 'ERROR ' "an unbuilt env is not an error"
}

test_doctor_errors_when_the_prefix_directory_is_gone() {
    mkwired a || return 1
    rm -rf "$ZENV_ROOT/a/zeek"
    doctor a
    assert_eq 2 "$DSTATUS"
    assert_contains "$REPORT" 'prefix directory is missing'
}

test_doctor_warns_when_the_zkg_directory_is_gone() {
    mkwired a || return 1
    rm -rf "$ZENV_ROOT/a/zkg"
    doctor a
    assert_contains "$REPORT" 'zkg directory is missing'
    # The reason it matters: zkg ignores the overrides for a directory that does
    # not exist and silently uses ~/.zkg instead.
    assert_contains "$REPORT" 'falls back to ~/.zkg'
}

# ---------------------------------------------------------------------------
# The zkg config
# ---------------------------------------------------------------------------

test_doctor_warns_when_zkg_is_not_wired_up() {
    mkenv a || return 1
    mkzkgstub "$ZENV_ROOT/a/zeek/bin/zkg"
    doctor a
    assert_eq 1 "$DSTATUS"
    assert_contains "$REPORT" 'zkg is not wired up yet'
    assert_contains "$REPORT" "run 'zenv autoconfig a'"
    assert_zkg_never_ran "doctor must not wire anything up itself"
}

test_doctor_errors_when_the_state_dir_is_not_the_envs_own() {
    mkwired a || return 1
    mkdir -p "$SANDBOX/other"
    cfg_set "$ZENV_ROOT/a/zkg/config" state_dir "$SANDBOX/other"
    doctor a
    assert_eq 2 "$DSTATUS"
    assert_contains "$REPORT" "zkg state_dir is $SANDBOX/other"
    assert_contains "$REPORT" 'reads and writes that directory'
}

# The doctor half of plan test 11.
test_doctor_errors_when_the_config_names_another_environments_directories() {
    mkwired a || return 1
    mkwired b || return 1
    _ap=$(realpath_p "$ZENV_ROOT/a/zeek")
    cfg_set "$ZENV_ROOT/b/zkg/config" script_dir "$_ap/share/zeek/site"
    cfg_set "$ZENV_ROOT/b/zkg/config" plugin_dir "$_ap/lib/zeek/plugins"
    doctor b
    assert_eq 2 "$DSTATUS"
    assert_contains "$REPORT" "zkg script_dir is outside this environment's prefix"
    assert_contains "$REPORT" "belongs to environment 'a'"
    assert_contains "$REPORT" 'move and then delete'
}

test_doctor_warns_on_an_empty_config_key() {
    mkwired a || return 1
    cfg_set "$ZENV_ROOT/a/zkg/config" plugin_dir ''
    doctor a
    assert_contains "$REPORT" 'zkg plugin_dir is empty'
    assert_eq 1 "$DSTATUS"
}

# ---------------------------------------------------------------------------
# manifest.json versus the config -- the highest-severity check (finding 6)
# ---------------------------------------------------------------------------

test_doctor_accepts_a_manifest_that_agrees_with_the_config() {
    mkwired a || return 1
    mkmanifest_agreeing a
    doctor a
    assert_eq 0 "$DSTATUS"
    assert_contains "$REPORT" 'manifest.json agrees with the config'
}

test_doctor_errors_on_a_stale_manifest() {
    mkwired a || return 1
    mkmanifest "$ZENV_ROOT/a/zkg/manifest.json" \
        "$SANDBOX/old/site/packages" "$SANDBOX/old/plugins/packages" "$SANDBOX/old/bin"
    doctor a
    assert_eq 2 "$DSTATUS" "a manifest that will cause a deletion is an error"
    assert_contains "$REPORT" 'manifest.json disagrees with the config about script_dir'
    assert_contains "$REPORT" 'deletes the destination'
    assert_contains "$REPORT" "'zenv autoconfig a --fix-paths'"
}

# zkg's Manager appends /packages to the config's script_dir before comparing, so
# a manifest holding the *unsuffixed* directory is a real disagreement -- the one
# an implementation that compares the raw keys would miss.
test_doctor_compares_the_manifest_against_script_dir_plus_packages() {
    mkwired a || return 1
    # Not _s/_p/_b: zenv_lib uses _s for its own scratch script, and cfg_get goes
    # through it, so the second call would overwrite the first answer.
    cfg_get "$ZENV_ROOT/a/zkg/config" script_dir
    _cs=$OUT
    cfg_get "$ZENV_ROOT/a/zkg/config" plugin_dir
    _cp=$OUT
    cfg_get "$ZENV_ROOT/a/zkg/config" bin_dir
    _cb=$OUT
    mkmanifest "$ZENV_ROOT/a/zkg/manifest.json" "$_cs" "$_cp" "$_cb"
    doctor a
    assert_eq 2 "$DSTATUS" "the manifest must name <script_dir>/packages"
    assert_contains "$REPORT" "config:   $_cs/packages"
}

test_doctor_errors_on_a_manifest_that_is_not_json() {
    mkwired a || return 1
    printf '{"script_dir": "/x", trunca' >"$ZENV_ROOT/a/zkg/manifest.json"
    doctor a
    assert_eq 2 "$DSTATUS"
    assert_contains "$REPORT" 'cannot read'
    assert_contains "$REPORT" 'as JSON'
}

test_doctor_says_no_manifest_yet_without_complaining() {
    mkwired a || return 1
    doctor a
    assert_contains "$REPORT" 'no manifest.json yet'
    assert_eq 0 "$DSTATUS"
}

# ---------------------------------------------------------------------------
# Shared directories between environments
# ---------------------------------------------------------------------------

test_doctor_errors_when_two_environments_share_a_script_dir() {
    mkwired a || return 1
    mkwired b || return 1
    _ap=$(realpath_p "$ZENV_ROOT/a/zeek")
    cfg_set "$ZENV_ROOT/b/zkg/config" script_dir "$_ap/share/zeek/site"
    doctor
    assert_eq 2 "$DSTATUS"
    assert_contains "$REPORT" "both use script_dir = $_ap/share/zeek/site"
    assert_contains "$REPORT" 'deletes the destination'
}

test_doctor_reports_a_collision_even_when_asked_about_one_environment() {
    mkwired a || return 1
    mkwired b || return 1
    _ap=$(realpath_p "$ZENV_ROOT/a/zeek")
    cfg_set "$ZENV_ROOT/b/zkg/config" plugin_dir "$_ap/lib/zeek/plugins"
    doctor a
    assert_eq 2 "$DSTATUS" "the collision belongs to both, so asking about one shows it"
    assert_contains "$REPORT" 'both use plugin_dir'
}

test_doctor_reports_each_colliding_pair_once() {
    mkwired a || return 1
    mkwired b || return 1
    _ap=$(realpath_p "$ZENV_ROOT/a/zeek")
    cfg_set "$ZENV_ROOT/b/zkg/config" script_dir "$_ap/share/zeek/site"
    doctor
    _n=$(printf '%s\n' "$REPORT" | grep -c 'both use script_dir')
    assert_eq 1 "$_n" "a:b and b:a are one finding, not two"
}

test_doctor_confirms_when_nothing_is_shared() {
    mkwired a || return 1
    mkwired b || return 1
    doctor
    assert_contains "$REPORT" 'no two environments share a script_dir or plugin_dir'
    assert_eq 0 "$DSTATUS"
}

# ---------------------------------------------------------------------------
# Source-tree drift: the five states, with only 'drifted' a warning
# ---------------------------------------------------------------------------

test_doctor_reports_a_verified_source_tree() {
    mkdist "$SANDBOX/tree" 9.1.0-dev.7
    mkwired a version=9.1.0-dev.7 zeek_dist="$SANDBOX/tree" || return 1
    doctor a
    assert_contains "$REPORT" "ok     source tree: $SANDBOX/tree (verified"
    assert_eq 0 "$DSTATUS"
}

test_doctor_warns_only_for_a_drifted_source_tree() {
    mkdist "$SANDBOX/tree" 9.1.0-dev.96
    mkwired a version=9.1.0-dev.7 zeek_dist="$SANDBOX/tree" || return 1
    doctor a
    assert_eq 1 "$DSTATUS" "drift is the one state that warns"
    assert_contains "$REPORT" 'source tree has drifted'
    assert_contains "$REPORT" '9.1.0-dev.96'
    assert_contains "$REPORT" 'version guard'
}

test_doctor_reports_an_unbuilt_source_tree_as_information() {
    mkdist "$SANDBOX/tree" 9.1.0-dev.7 --no-build
    mkwired a version=9.1.0-dev.7 zeek_dist="$SANDBOX/tree" || return 1
    doctor a
    assert_contains "$REPORT" 'source tree: unbuilt'
    assert_eq 0 "$DSTATUS" "a --builddir build is not a fault"
}

test_doctor_reports_a_source_tree_that_is_gone_as_information() {
    mkwired a zeek_dist="$SANDBOX/never-existed" || return 1
    doctor a
    assert_contains "$REPORT" 'source tree: gone'
    assert_eq 0 "$DSTATUS"
}

test_doctor_reports_no_source_tree_as_information() {
    mkwired a || return 1
    doctor a
    assert_contains "$REPORT" 'source tree: none'
    assert_contains "$REPORT" 'binary-packaged'
    assert_eq 0 "$DSTATUS"
}

test_doctor_uses_the_envs_src_override_for_the_tree() {
    mkdist "$SANDBOX/asserted" 9.1.0-dev.7
    zenv new a --src "$SANDBOX/asserted" >/dev/null 2>&1 || return 1
    mkprefix "$ZENV_ROOT/a/zeek" version=9.1.0-dev.7 zeek_dist="$SANDBOX/ignored"
    mkzkgstub "$ZENV_ROOT/a/zeek/bin/zkg"
    zenv autoconfig a >/dev/null 2>&1
    doctor a
    assert_contains "$REPORT" "$SANDBOX/asserted (verified"
    assert_not_contains "$REPORT" "$SANDBOX/ignored" "the env's own src wins"
}

# ---------------------------------------------------------------------------
# The build commit
#
# Version matching says whether the tree still fits the install; the recorded
# commit says which one to check out again. A tree checked out elsewhere is only
# counted against the exit code once the install has drifted from it -- otherwise
# a shared checkout moving between commits of the same version would make an
# otherwise-clean environment fail doctor.
# ---------------------------------------------------------------------------

# A wired environment whose tree is a git checkout, with the build commit
# recorded by autoconfig. Prints the commit.
mkwired_git() {
    mkdist "$2" "$3"
    _mwgsha=$(mkgit "$2") || return 1
    mkwired "$1" version="$3" zeek_dist="$2" || return 1
    printf '%s' "$_mwgsha"
}

test_doctor_confirms_a_tree_still_on_the_build_commit() {
    have_git || return 0
    sha=$(mkwired_git a "$SANDBOX/tree" 9.1.0-dev.7) || return 1
    doctor a
    assert_contains "$REPORT" "ok     build commit: $SANDBOX/tree is on $(printf '%.12s' "$sha")"
    assert_contains "$REPORT" "the commit 'a' was built from"
    assert_eq 0 "$DSTATUS"
}

test_doctor_names_the_commit_to_check_out_for_a_drifted_tree() {
    have_git || return 0
    sha=$(mkwired_git a "$SANDBOX/tree" 9.1.0-dev.7) || return 1
    mkdist "$SANDBOX/tree" 9.1.0-dev.96
    mkgit_move "$SANDBOX/tree" >/dev/null || return 1

    doctor a
    assert_eq 1 "$DSTATUS" "drift plus a moved checkout is a warning"
    assert_contains "$REPORT" "but 'a' was built from $(printf '%.12s' "$sha")"
    assert_contains "$REPORT" "git -C $SANDBOX/tree checkout $sha"
}

test_doctor_reports_a_moved_checkout_that_still_verifies_as_information() {
    have_git || return 0
    sha=$(mkwired_git a "$SANDBOX/tree" 9.1.0-dev.7) || return 1
    # A commit that does not touch VERSION or build/: the install still matches
    # the tree, so a package built against it would still load.
    mkgit_move "$SANDBOX/tree" >/dev/null || return 1

    doctor a
    assert_eq 0 "$DSTATUS" "still verified, so not a fault"
    assert_contains "$REPORT" "but 'a' was built from $(printf '%.12s' "$sha")"
    assert_contains "$REPORT" 'info'
}

test_doctor_reports_a_recorded_commit_the_tree_no_longer_has() {
    have_git || return 0
    sha=$(mkwired_git a "$SANDBOX/tree" 9.1.0-dev.7) || return 1
    # A re-clone, or rewritten history: the record survives, the commit does not.
    # The rewrite is dated a day earlier, or an instant re-init could hash to the
    # *same* commit object -- identical tree, author and message in the same
    # second produce an identical sha, which would silently undo the rewrite.
    rm -rf "$SANDBOX/tree/.git"
    GIT_AUTHOR_DATE=2020-01-01T00:00:00Z GIT_COMMITTER_DATE=2020-01-01T00:00:00Z \
        mkgit "$SANDBOX/tree" >/dev/null || return 1

    doctor a
    assert_contains "$REPORT" "a commit $SANDBOX/tree does not have"
    assert_contains "$REPORT" 'fetch it, or rebuild'
    assert_not_contains "$REPORT" "checkout $sha" "no unusable command is offered"
}

test_doctor_says_how_to_record_a_missing_build_commit() {
    have_git || return 0
    mkwired_git a "$SANDBOX/tree" 9.1.0-dev.7 >/dev/null || return 1
    zenv_lib '_kv_set "$1" src_commit ""' "$ZENV_ROOT/a/env"

    doctor a
    assert_contains "$REPORT" "no build commit recorded for 'a'"
    assert_contains "$REPORT" "'zenv autoconfig a' records it"
    assert_eq 0 "$DSTATUS" "not knowing yet is not a fault"
}

test_doctor_discounts_a_build_commit_recorded_for_another_version() {
    have_git || return 0
    mkwired_git a "$SANDBOX/tree" 9.1.0-dev.7 >/dev/null || return 1
    # What a reinstall looks like: the recorded commit belongs to the version
    # that was installed then, and says nothing about the one installed now.
    zenv_lib '_kv_set "$1" src_version 9.1.0-dev.1' "$ZENV_ROOT/a/env"

    doctor a
    assert_contains "$REPORT" "recorded for '9.1.0-dev.1', this install is '9.1.0-dev.7'"
    assert_contains "$REPORT" 'no longer evidence about this install'
    assert_eq 0 "$DSTATUS"
}

test_doctor_says_nothing_about_commits_for_a_tree_that_is_not_a_checkout() {
    mkdist "$SANDBOX/tree" 9.1.0-dev.7
    mkwired a version=9.1.0-dev.7 zeek_dist="$SANDBOX/tree" || return 1
    doctor a
    assert_contains "$REPORT" 'source tree' "the tree itself is still reported"
    assert_not_contains "$REPORT" 'build commit' "a tarball has no commit to name"
    assert_eq 0 "$DSTATUS"
}

test_doctor_reports_an_empty_zeek_dist_key_as_irrelevant() {
    mkwired a || return 1
    doctor a
    assert_contains "$REPORT" 'zkg zeek_dist is empty'
    assert_contains "$REPORT" 'two index packages'
}

# ---------------------------------------------------------------------------
# The two variables zenv deliberately never sets (finding 5b)
# ---------------------------------------------------------------------------

test_doctor_warns_when_zeek_build_dir_is_set_in_the_environment() {
    mkwired a || return 1
    ZEEK_BUILD_DIR=$SANDBOX/some-build
    export ZEEK_BUILD_DIR
    doctor a
    assert_eq 1 "$DSTATUS"
    assert_contains "$REPORT" "ZEEK_BUILD_DIR is set in your environment: $SANDBOX/some-build"
    assert_contains "$REPORT" '--zeek-dist'
}

test_doctor_confirms_zeek_build_dir_is_unset() {
    mkwired a || return 1
    doctor a
    assert_contains "$REPORT" 'ok     ZEEK_BUILD_DIR is not set'
}

test_doctor_reports_zeek_dist_as_inert_information() {
    mkwired a || return 1
    ZEEK_DIST=$SANDBOX/tree
    export ZEEK_DIST
    doctor a
    assert_eq 0 "$DSTATUS" "an exported ZEEK_DIST is harmless, so not a warning"
    assert_contains "$REPORT" 'ZEEK_DIST is set in your environment'
    assert_contains "$REPORT" 'no effect'
}

# ---------------------------------------------------------------------------
# The compatibility symlinks
# ---------------------------------------------------------------------------

test_doctor_names_the_environment_a_link_points_at() {
    mkwired a || return 1
    zenv link a >/dev/null 2>&1
    doctor a
    assert_contains "$REPORT" "$HOME/zeek -> zenv/a/zeek (environment 'a')"
    assert_contains "$REPORT" "$HOME/.zkg -> zenv/a/zkg (environment 'a')"
    assert_eq 0 "$DSTATUS"
}

test_doctor_warns_on_a_dangling_link() {
    mkwired a || return 1
    zenv link a >/dev/null 2>&1
    rm -rf "$ZENV_ROOT/a/zeek"
    doctor a
    assert_contains "$REPORT" "$HOME/zeek -> zenv/a/zeek dangles"
    assert_contains "$REPORT" "'zenv unlink' removes it"
}

test_doctor_notes_a_link_that_disagrees_with_this_shell() {
    mkwired a || return 1
    mkwired b || return 1
    zenv link a >/dev/null 2>&1
    ZENV=b
    export ZENV
    doctor
    assert_contains "$REPORT" "this shell has 'b' active instead"
    assert_contains "$REPORT" 'activation is shell-local'
    assert_eq 0 "$DSTATUS" "shell-local activation makes this harmless"
}

test_doctor_reports_a_real_directory_as_none_of_its_business() {
    mkwired a || return 1
    mkdir -p "$HOME/zeek"
    doctor a
    assert_contains "$REPORT" "$HOME/zeek: a real directory zenv did not create"
    assert_contains "$REPORT" "'zenv adopt <name>'"
    assert_eq 0 "$DSTATUS"
}

test_doctor_reports_a_link_out_of_the_root_without_claiming_it() {
    mkwired a || return 1
    mkdir -p "$SANDBOX/elsewhere"
    ln -s "$SANDBOX/elsewhere" "$HOME/zeek"
    doctor a
    assert_contains "$REPORT" 'zenv did not create it'
    assert_eq 0 "$DSTATUS"
}

# ---------------------------------------------------------------------------
# Which zkg, and whether it can run at all
# ---------------------------------------------------------------------------

test_doctor_prefers_the_environments_own_zkg() {
    mkwired a || return 1
    mkzkgstub "$SANDBOX/bin/zkg"
    doctor a
    assert_contains "$REPORT" "zkg: $ZENV_ROOT/a/zeek/bin/zkg (this environment's own)"
}

test_doctor_notes_a_zkg_that_comes_from_path() {
    mkenv a || return 1
    mkzkgstub "$SANDBOX/bin/zkg"
    zenv autoconfig a >/dev/null 2>&1
    doctor a
    assert_contains "$REPORT" "zkg: $SANDBOX/bin/zkg (from PATH"
    assert_contains "$REPORT" 'ZEEK_ZKG_'
}

test_doctor_warns_when_there_is_no_zkg_anywhere() {
    mkenv a || return 1
    doctor a
    assert_contains "$REPORT" 'no zkg found'
    assert_contains "$REPORT" "'zenv autoconfig a' needs one"
    assert_eq 1 "$DSTATUS"
}

test_doctor_checks_that_the_zkg_interpreter_can_import_what_zkg_needs() {
    mkwired a || return 1
    mkpython ok || return 1
    setshebang "$ZENV_ROOT/a/zeek/bin/zkg" '#!/usr/bin/env python3'
    doctor a
    assert_contains "$REPORT" 'can import git and semantic_version'
    assert_eq 0 "$DSTATUS"
}

test_doctor_errors_when_the_zkg_interpreter_cannot_import() {
    mkwired a || return 1
    mkpython fail || return 1
    setshebang "$ZENV_ROOT/a/zeek/bin/zkg" '#!/usr/bin/env python3'
    doctor a
    assert_eq 2 "$DSTATUS" "zkg cannot run at all, so every zkg command fails"
    assert_contains "$REPORT" 'cannot import git and semantic_version'
    assert_contains "$REPORT" 'GitPython and semantic-version'
}

test_doctor_says_so_rather_than_guessing_for_a_non_python_zkg() {
    mkwired a || return 1
    doctor a
    assert_contains "$REPORT" 'cannot tell which python'
    assert_eq 0 "$DSTATUS" "not knowing is not a fault"
}

# ---------------------------------------------------------------------------
# Scope, the root, and arguments
# ---------------------------------------------------------------------------

test_doctor_with_no_name_checks_every_environment() {
    mkwired a || return 1
    mkwired b || return 1
    doctor
    assert_contains "$REPORT" 'environment a'
    assert_contains "$REPORT" 'environment b'
    assert_eq 0 "$DSTATUS"
}

test_doctor_with_a_name_checks_only_that_environment() {
    mkwired a || return 1
    mkwired b || return 1
    doctor b
    assert_contains "$REPORT" 'environment b'
    assert_not_contains "$REPORT" 'environment a'
}

test_doctor_all_is_the_same_as_no_name() {
    mkwired a || return 1
    doctor --all
    assert_contains "$REPORT" 'environment a'
    assert_eq 0 "$DSTATUS"
}

test_doctor_names_the_root_and_where_it_came_from() {
    mkwired a || return 1
    doctor a
    assert_contains "$REPORT" "root: $ZENV_ROOT (from the environment)"
}

test_doctor_reports_an_empty_root() {
    doctor
    assert_contains "$REPORT" "'zenv new <name>' creates one"
    assert_eq 0 "$DSTATUS" "no environments is not a fault"
}

test_doctor_notes_an_active_environment_that_no_longer_exists() {
    mkwired a || return 1
    ZENV=removed
    export ZENV
    doctor a
    assert_eq 1 "$DSTATUS"
    assert_contains "$REPORT" "ZENV='removed' active, but there is no such environment"
    assert_contains "$REPORT" "'zenv deactivate' clears it"
}

test_doctor_says_which_environment_is_active() {
    mkwired a || return 1
    ZENV=a
    export ZENV
    doctor a
    assert_contains "$REPORT" "ok     this shell has 'a' active"
}

test_doctor_refuses_an_unknown_environment_and_bad_options() {
    mkwired a || return 1
    capture zenv doctor nosuch && fail "doctor must refuse an unknown env"
    assert_contains "$ERR" 'no such environment: nosuch'
    capture zenv doctor --nope && fail "doctor must refuse an unknown option"
    assert_contains "$ERR" "unknown option '--nope'"
    capture zenv doctor a b && fail "doctor takes one name"
    assert_contains "$ERR" 'only one name'
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

test_status_prints_the_paths_and_the_version() {
    mkwired a version=9.1.0-dev.42 || return 1
    capture zenv status a || fail "status should succeed"
    assert_contains "$OUT" 'name:       a'
    assert_contains "$OUT" "prefix:     $(realpath_p "$ZENV_ROOT/a/zeek")"
    assert_contains "$OUT" "zkg dir:    $(realpath_p "$ZENV_ROOT/a/zkg")"
    assert_contains "$OUT" "root:       $ZENV_ROOT (from the environment)"
    assert_contains "$OUT" 'installed:  9.1.0-dev.42'
}

# The anti-drift assertion: status must show the values a real shell would get,
# because it is produced by evaluating activation's own output.
test_status_shows_exactly_what_activation_sets() {
    mkwired a || return 1
    capture zenv status a || return 1
    _st=$OUT
    sh_probe "$(act_line a)"
    for _v in ZENV ZENV_PREFIX ZENV_ZKG_DIR PATH PYTHONPATH MANPATH \
        ZEEKPATH ZEEK_PLUGIN_PATH ZKG_CONFIG_FILE ZEEK_ZKG_CONFIG_DIR \
        ZEEK_ZKG_STATE_DIR; do
        _want=$(probe_var "$_v")
        _got=$(printf '%s\n' "$_st" | sed -n "s/^  $_v  *//p" | head -1)
        assert_eq "$_want" "$_got" "status must agree with activation about $_v"
    done
}

test_status_shows_the_prompt_it_would_set() {
    mkwired a || return 1
    capture zenv status a
    assert_contains "$OUT" '(zenv:a) $PS1'
}

test_status_marks_the_active_environment() {
    mkwired a || return 1
    mkwired b || return 1
    ZENV=a
    export ZENV
    capture zenv status a
    assert_contains "$OUT" 'active:     yes, in this shell'
    capture zenv status b
    assert_contains "$OUT" "active:     no (this shell has 'a')"
}

test_status_defaults_to_the_active_environment() {
    mkwired a || return 1
    ZENV=a
    export ZENV
    capture zenv status
    assert_contains "$OUT" 'name:       a'
}

test_status_shows_the_zkg_config_without_running_zkg() {
    mkwired a || return 1
    mkmanifest_agreeing a
    mkzkgstub "$SANDBOX/bin/zkg"
    : >"$ZKG_STUB_LOG"
    capture zenv status a
    assert_contains "$OUT" "state_dir   $(realpath_p "$ZENV_ROOT/a/zkg")"
    assert_contains "$OUT" 'script_dir  '
    assert_contains "$OUT" 'packages    0'
    assert_zkg_never_ran "status must read the config, not ask zkg for it"
}

test_status_says_when_zkg_is_not_wired_up() {
    mkenv a || return 1
    capture zenv status a
    assert_contains "$OUT" 'not wired up yet'
    assert_contains "$OUT" "'zenv autoconfig a'"
}

test_status_reports_the_source_tree_verification_state() {
    mkdist "$SANDBOX/tree" 9.1.0-dev.96
    mkwired a version=9.1.0-dev.7 || return 1
    cfg_set "$ZENV_ROOT/a/zkg/config" zeek_dist "$SANDBOX/tree"
    capture zenv status a
    assert_contains "$OUT" 'zeek_dist   drifted'
}

test_status_reports_the_link_state() {
    mkwired a || return 1
    mkwired b || return 1
    zenv link b >/dev/null 2>&1
    capture zenv status b
    assert_contains "$OUT" "linked:     $HOME/zeek -> zenv/b/zeek (this environment)"
    capture zenv status a
    assert_contains "$OUT" "environment 'b'"
}

test_status_says_when_nothing_is_installed() {
    zenv new a >/dev/null 2>&1 || return 1
    capture zenv status a || fail "status must work for an unbuilt env"
    assert_contains "$OUT" 'installed:  no'
}

test_status_shows_the_two_variables_it_leaves_alone() {
    mkwired a || return 1
    ZEEK_DIST=$SANDBOX/tree
    export ZEEK_DIST
    capture zenv status a
    assert_contains "$OUT" 'left exactly as they are'
    assert_contains "$OUT" "ZEEK_DIST       $SANDBOX/tree"
    assert_contains "$OUT" 'ZEEK_BUILD_DIR  <unset>'
}

test_status_names_the_zkg_user_escape_hatch() {
    mkwired a || return 1
    capture zenv status a
    assert_contains "$OUT" "'zkg --user'"
    # shellcheck disable=SC2088  # the tilde is text zenv printed, not a path to expand
    assert_contains "$OUT" '~/.zkg'
}

test_status_does_not_wire_zkg_up_as_a_side_effect() {
    mkenv a || return 1
    mkzkgstub "$SANDBOX/bin/zkg"
    capture zenv status a
    assert_zkg_never_ran "status is read-only"
    assert_missing "$ZENV_ROOT/a/zkg/config" "and writes no config"
}

test_status_refuses_an_unknown_environment_and_bad_options() {
    capture zenv status nosuch && fail "status must refuse an unknown env"
    assert_contains "$ERR" 'no such environment: nosuch'
    capture zenv status --nope && fail "status must refuse an unknown option"
    assert_contains "$ERR" "unknown option '--nope'"
    capture zenv status && fail "status with no name and nothing active must refuse"
    assert_contains "$ERR" 'no environment given'
}

test_help_lists_doctor_and_status() {
    capture zenv help || fail "help should succeed"
    assert_contains "$OUT" 'doctor [name]'
    assert_contains "$OUT" 'status [name]'
    assert_contains "$OUT" '0 clean, 1 warnings, 2 errors'
}

run_cases
