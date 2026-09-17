#!/bin/sh
# Validates tests/lib.sh's own facilities: the fake prefix, the recording zkg
# stub, the shell probe and the small helpers. Everything from step D onward
# asserts against these, so a stub that lies is worse than no stub at all.
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
# Fake prefix
# ---------------------------------------------------------------------------

test_mkprefix_builds_the_directories_a_real_install_has() {
    mkprefix "$SANDBOX/p"
    assert_file "$SANDBOX/p/bin/zeek-config"
    assert_file "$SANDBOX/p/bin/zeek"
    assert_dir "$SANDBOX/p/lib/zeek/python"
    assert_dir "$SANDBOX/p/lib/zeek/plugins"
    assert_dir "$SANDBOX/p/share/zeek/site"
    assert_dir "$SANDBOX/p/share/man/man1"
    assert_dir "$SANDBOX/p/share/zeek/cmake"
    assert_dir "$SANDBOX/p/etc/zeek"
    # Finding 8: a usable install has broker's headers. doctor checks for this.
    assert_file "$SANDBOX/p/include/broker/expected.hh"
    [ -x "$SANDBOX/p/bin/zeek-config" ] || fail "zeek-config not executable"
}

test_zeek_config_defaults_all_derive_from_the_prefix() {
    mkprefix "$SANDBOX/p"
    zc="$SANDBOX/p/bin/zeek-config"
    assert_eq "$SANDBOX/p" "$("$zc" --prefix)" "--prefix"
    assert_eq "$SANDBOX/p/share/zeek/site" "$("$zc" --site_dir)" "--site_dir"
    assert_eq "$SANDBOX/p/lib/zeek/plugins" "$("$zc" --plugin_dir)" "--plugin_dir"
    assert_eq "$SANDBOX/p/share/zeek" "$("$zc" --script_dir)" "--script_dir"
    assert_eq "$SANDBOX/p/lib/zeek/python" "$("$zc" --python_dir)" "--python_dir"
    assert_eq "$SANDBOX/p" "$("$zc" --broker_root)" "--broker_root"
    assert_eq "9.1.0-dev.1" "$("$zc" --version)" "--version"
    # Finding 5b: empty zeek_dist is the normal binary-packaged state.
    assert_eq "" "$("$zc" --zeek_dist)" "--zeek_dist defaults empty"
}

test_zeek_config_answers_several_flags_in_argument_order() {
    # zkg autoconfig relies on this: one invocation, one line per flag, in the
    # order given. A stub that only handles a single flag would hide bugs.
    mkprefix "$SANDBOX/p" version=9.9.9 zeek_dist=/some/tree
    got=$("$SANDBOX/p/bin/zeek-config" --site_dir --plugin_dir --prefix --zeek_dist)
    want="$SANDBOX/p/share/zeek/site
$SANDBOX/p/lib/zeek/plugins
$SANDBOX/p
/some/tree"
    assert_eq "$want" "$got" "four flags, one invocation, in order"
}

test_mkprefix_overrides_let_a_prefix_lie_about_itself() {
    # This is the shape of the finding-6 hazard: b's zeek-config reports a's
    # directories, which is what a copied or symlink-installed tree does.
    mkprefix "$SANDBOX/a"
    mkprefix "$SANDBOX/b" \
        site_dir="$SANDBOX/a/share/zeek/site" \
        plugin_dir="$SANDBOX/a/lib/zeek/plugins"
    assert_eq "$SANDBOX/a/share/zeek/site" \
        "$("$SANDBOX/b/bin/zeek-config" --site_dir)" "b lies about site_dir"
    assert_eq "$SANDBOX/b" \
        "$("$SANDBOX/b/bin/zeek-config" --prefix)" "but reports its own prefix"
}

test_zeek_config_rejects_an_unknown_flag() {
    mkprefix "$SANDBOX/p"
    assert_status 1 "$SANDBOX/p/bin/zeek-config" --nonsense
    assert_contains "$OUT" "unknown option" "should explain the rejection"
}

test_mkprefix_survives_a_prefix_path_with_a_space_and_a_quote() {
    d="$SANDBOX/awkward dir/it's here"
    mkdir -p "$d"
    mkprefix "$d/p"
    assert_eq "$d/p" "$("$d/p/bin/zeek-config" --prefix)" "quoting in generated stub"
    assert_eq "$d/p/share/zeek/site" "$("$d/p/bin/zeek-config" --site_dir)" "site_dir"
}

test_zeek_stub_reports_its_own_prefix_and_version() {
    mkprefix "$SANDBOX/p" version=8.0.0
    out=$("$SANDBOX/p/bin/zeek" --version)
    assert_contains "$out" "8.0.0" "version"
    assert_contains "$out" "$SANDBOX/p" "prefix"
}

test_mkdist_builds_a_verifiable_source_tree() {
    # Finding 5b's verification: VERSION plus a build/zeek-version.h whose
    # ZEEK_VERSION_FUNCTION matches.
    mkdist "$SANDBOX/src" 9.1.0-dev.75
    assert_eq "9.1.0-dev.75" "$(cat "$SANDBOX/src/VERSION")" "VERSION"
    assert_file "$SANDBOX/src/build/zeek-version.h"
    assert_contains "$(cat "$SANDBOX/src/build/zeek-version.h")" \
        "zeek_version_9_1_0_dev_75_plugin_7" "mangled version guard symbol"
    # The stub has to be as hard to satisfy as the real header, which mentions
    # ZEEK_VERSION_FUNCTION a second time without any version attached. A stub
    # carrying only the #define hid a bug that called every real install drifted.
    assert_contains "$(cat "$SANDBOX/src/build/zeek-version.h")" \
        'extern const char* ZEEK_VERSION_FUNCTION();' \
        "the declaration the real header has, after the #define"
}

test_mkdist_no_build_is_the_unbuilt_state() {
    mkdist "$SANDBOX/src" 9.1.0-dev.75 --no-build
    assert_file "$SANDBOX/src/VERSION"
    assert_missing "$SANDBOX/src/build"
}

# ---------------------------------------------------------------------------
# Recording zkg stub
# ---------------------------------------------------------------------------

test_zkg_stub_records_nothing_until_invoked() {
    mkzkgstub "$SANDBOX/bin/zkg"
    assert_eq 0 "$(zkg_invocations)" "no invocations yet"
    assert_zkg_never_ran
}

test_zkg_stub_records_argv_and_the_environment_it_saw() {
    mkprefix "$SANDBOX/p"
    mkzkgstub "$SANDBOX/bin/zkg"
    mkdir -p "$SANDBOX/zkgdir"
    ZEEK_ZKG_CONFIG_DIR="$SANDBOX/zkgdir" \
    ZEEK_ZKG_STATE_DIR="$SANDBOX/zkgdir" \
    PATH="$SANDBOX/p/bin:$PATH" \
        "$SANDBOX/bin/zkg" autoconfig --force >/dev/null 2>&1

    assert_eq 1 "$(zkg_invocations)" "exactly one invocation"
    log=$(zkg_log)
    assert_contains "$log" "argv: autoconfig --force" "argv recorded"
    assert_contains "$log" "ZEEK_ZKG_CONFIG_DIR: $SANDBOX/zkgdir" "config dir recorded"
    assert_contains "$log" "ZEEK_ZKG_STATE_DIR: $SANDBOX/zkgdir" "state dir recorded"
    assert_contains "$log" "ZKG_CONFIG_FILE: <unset>" "unset is distinguishable"
    assert_contains "$log" "$SANDBOX/p/bin" "the PATH it saw is recorded"
    # Test 12's invariant: the dirs must already exist when zkg runs.
    assert_contains "$log" "isdir $SANDBOX/zkgdir: yes" "dir existed at invocation"
}

test_zkg_stub_writes_a_complete_config_on_first_run() {
    mkprefix "$SANDBOX/p"
    mkzkgstub "$SANDBOX/bin/zkg"
    mkdir -p "$SANDBOX/zkgdir"
    ZEEK_ZKG_CONFIG_DIR="$SANDBOX/zkgdir" \
    ZEEK_ZKG_STATE_DIR="$SANDBOX/zkgdir" \
    PATH="$SANDBOX/p/bin:$PATH" \
        "$SANDBOX/bin/zkg" autoconfig --force >/dev/null 2>&1

    cfg="$SANDBOX/zkgdir/config"
    assert_file "$cfg"
    body=$(cat "$cfg")
    # Finding 3: a first-run config must carry sources and templates.
    assert_contains "$body" "[sources]" "sources section"
    assert_contains "$body" "[templates]" "templates section"
    assert_contains "$body" "script_dir = $SANDBOX/p/share/zeek/site" "script_dir"
    assert_contains "$body" "plugin_dir = $SANDBOX/p/lib/zeek/plugins" "plugin_dir"
    assert_contains "$body" "bin_dir = $SANDBOX/p/bin" "bin_dir"
    assert_contains "$body" "state_dir = $SANDBOX/zkgdir" "state_dir"
}

test_zkg_stub_rewrites_only_autoconfigs_four_keys_on_a_rerun() {
    # The real `zkg autoconfig --force` preserves [sources]/[templates] and
    # never writes state_dir. Step 7 of zenv autoconfig depends on that.
    mkprefix "$SANDBOX/a"
    mkprefix "$SANDBOX/b"
    mkzkgstub "$SANDBOX/bin/zkg"
    mkdir -p "$SANDBOX/zkgdir"

    ZEEK_ZKG_CONFIG_DIR="$SANDBOX/zkgdir" ZEEK_ZKG_STATE_DIR="$SANDBOX/zkgdir" \
        PATH="$SANDBOX/a/bin:$PATH" "$SANDBOX/bin/zkg" autoconfig --force >/dev/null 2>&1
    cp "$SANDBOX/zkgdir/config" "$SANDBOX/before"

    ZEEK_ZKG_CONFIG_DIR="$SANDBOX/zkgdir" ZEEK_ZKG_STATE_DIR="$SANDBOX/zkgdir" \
        PATH="$SANDBOX/b/bin:$PATH" "$SANDBOX/bin/zkg" autoconfig --force >/dev/null 2>&1

    body=$(cat "$SANDBOX/zkgdir/config")
    assert_contains "$body" "script_dir = $SANDBOX/b/share/zeek/site" "repointed"
    assert_contains "$body" "[sources]" "sources preserved"
    assert_contains "$body" "[templates]" "templates preserved"
    # state_dir untouched, and only the four keys changed.
    delta=$(diff "$SANDBOX/before" "$SANDBOX/zkgdir/config" | grep -c '^[<>]' || true)
    assert_eq 6 "$delta" "3 changed keys => 6 diff lines (bin_dir differs, zeek_dist empty both)"
}

test_zkg_stub_falls_back_to_home_zkg_when_the_dir_does_not_exist() {
    # zkg:77-89 -- the override is ignored unless it is an existing directory.
    # This is the silent-fallback trap the stub must reproduce for test 12.
    mkprefix "$SANDBOX/p"
    mkzkgstub "$SANDBOX/bin/zkg"
    ZEEK_ZKG_CONFIG_DIR="$SANDBOX/absent" \
    ZEEK_ZKG_STATE_DIR="$SANDBOX/absent" \
    PATH="$SANDBOX/p/bin:$PATH" \
        "$SANDBOX/bin/zkg" autoconfig --force >/dev/null 2>&1

    assert_missing "$SANDBOX/absent/config"
    assert_file "$HOME/.zkg/config" "it must land in \$HOME/.zkg, reproducing the trap"
    assert_contains "$(zkg_log)" "isdir $SANDBOX/absent: no" "recorded as nonexistent"
}

test_zkg_stub_fails_without_a_zeek_config_on_path() {
    mkzkgstub "$SANDBOX/bin/zkg"
    mkdir -p "$SANDBOX/zkgdir"
    assert_status 1 env ZEEK_ZKG_CONFIG_DIR="$SANDBOX/zkgdir" \
        ZEEK_ZKG_STATE_DIR="$SANDBOX/zkgdir" "$SANDBOX/bin/zkg" autoconfig
    assert_contains "$OUT" "no zeek-config" "should say why"
}

test_zkg_stub_reports_config_values() {
    mkprefix "$SANDBOX/p"
    mkzkgstub "$SANDBOX/bin/zkg"
    mkdir -p "$SANDBOX/zkgdir"
    ZEEK_ZKG_CONFIG_DIR="$SANDBOX/zkgdir" ZEEK_ZKG_STATE_DIR="$SANDBOX/zkgdir" \
        PATH="$SANDBOX/p/bin:$PATH" "$SANDBOX/bin/zkg" autoconfig --force >/dev/null 2>&1
    got=$(ZEEK_ZKG_CONFIG_DIR="$SANDBOX/zkgdir" "$SANDBOX/bin/zkg" config state_dir)
    assert_eq "$SANDBOX/zkgdir" "$got" "zkg config state_dir"
}

test_zkg_stub_exits_nonzero_on_an_unhandled_command() {
    mkzkgstub "$SANDBOX/bin/zkg"
    assert_status 3 "$SANDBOX/bin/zkg" install some/package
    assert_status 2 "$SANDBOX/bin/zkg"
}

# ---------------------------------------------------------------------------
# Shell probe
# ---------------------------------------------------------------------------

test_probe_distinguishes_unset_from_empty() {
    probe /bin/sh 'ZEEKPATH=""; export ZEEKPATH; unset ZEEK_PLUGIN_PATH'
    assert_eq "" "$(probe_var ZEEKPATH)" "empty is empty"
    assert_eq "<unset>" "$(probe_var ZEEK_PLUGIN_PATH)" "unset is <unset>"
}

test_probe_reports_values_verbatim() {
    probe /bin/sh 'ZEEKPATH="/a:/b c:/d"; export ZEEKPATH'
    assert_eq "/a:/b c:/d" "$(probe_var ZEEKPATH)" "spaces survive"
}

test_probe_runs_the_requested_shell() {
    for s in /bin/sh /bin/bash; do
        probe "$s" 'ZENV=probed; export ZENV'
        assert_eq "probed" "$(probe_var ZENV)" "under $s"
    done
    if command -v zsh >/dev/null 2>&1; then
        probe "$(command -v zsh)" 'ZENV=probed; export ZENV'
        assert_eq "probed" "$(probe_var ZENV)" "under zsh"
    fi
}

test_probe_sees_a_shell_local_ps1() {
    probe /bin/sh 'PS1="(zenv:a) $ "'
    assert_eq '(zenv:a) $ ' "$(probe_var PS1)" "PS1 need not be exported"
}

test_probe_covers_every_variable_activate_touches() {
    probe /bin/sh ':'
    for v in PATH PYTHONPATH MANPATH ZEEKPATH ZEEK_PLUGIN_PATH ZKG_CONFIG_FILE \
             ZEEK_ZKG_CONFIG_DIR ZEEK_ZKG_STATE_DIR ZEEK_DIST ZEEK_BUILD_DIR \
             ZENV ZENV_PREFIX ZENV_ZKG_DIR PS1; do
        # Braces are required: zsh parses "$v[...]" as a parameter subscript and
        # evaluates the subscript as arithmetic.
        if ! printf '%s\n' "$OUT" | grep -q "^${v}[=<]"; then
            fail "probe does not report $v"
        fi
    done
}

test_probe_does_not_leak_the_harness_shells_options() {
    # zsh does not word-split unquoted parameters; lib.sh enables shwordsplit
    # for itself, and that must not reach the probed shell.
    if [ -z "${ZSH_VERSION:-}" ]; then
        return 0
    fi
    probe "$(command -v zsh)" 'v="a b"; set -- $v; ZENV=$#; export ZENV'
    assert_eq "1" "$(probe_var ZENV)" "probed zsh must have default options"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

test_quote_sh_round_trips_hostile_strings() {
    for s in "plain" "with space" "it's" "a'b'c" 'dollar$var' 'back\slash' \
             'semi;colon' 'star*glob' 'tick`cmd`'; do
        got=$(eval "printf '%s' $(quote_sh "$s")")
        assert_eq "$s" "$got" "round trip of [$s]"
    done
}

test_realpath_p_resolves_symlinks_and_dots() {
    mkdir -p "$SANDBOX/real/sub"
    ln -s "$SANDBOX/real" "$SANDBOX/link"
    assert_eq "$SANDBOX/real" "$(realpath_p "$SANDBOX/link")" "symlinked dir"
    assert_eq "$SANDBOX/real" "$(realpath_p "$SANDBOX/real/sub/..")" "dot dot"
    assert_eq "$SANDBOX/real/sub" "$(realpath_p "$SANDBOX/link/sub")" "through a link"
}

test_realpath_p_handles_a_nonexistent_leaf() {
    # zenv new resolves a prefix before it exists, so this case matters.
    assert_eq "$SANDBOX/nope" "$(realpath_p "$SANDBOX/nope")" "missing leaf"
}

test_split_lines_iterates_under_every_shell() {
    n=0
    seen=
    for line in $(split_lines "a
b
c"); do
        n=$((n + 1))
        seen=$seen$line
    done
    assert_eq 3 "$n" "three lines"
    assert_eq abc "$seen" "in order, one line per iteration"
}

# ---------------------------------------------------------------------------
# Sandbox contract
# ---------------------------------------------------------------------------

test_sandbox_isolates_home_and_zenv_root() {
    assert_eq "$SANDBOX/home" "$HOME" "HOME inside sandbox"
    assert_eq "$SANDBOX/home/zenv" "$ZENV_ROOT" "ZENV_ROOT inside sandbox"
    assert_ne "$REAL_HOME" "$HOME" "not the real home"
    assert_missing "$ZENV_ROOT" "the root is not created for us"
}

test_sandbox_path_cannot_reach_the_real_install() {
    assert_not_contains "$PATH" "$REAL_HOME/zeek/bin" "real zeek must not be on PATH"
    if command -v zeek >/dev/null 2>&1; then
        fail "a zeek is reachable from the sandbox PATH: $(command -v zeek)"
    fi
    if command -v zkg >/dev/null 2>&1; then
        fail "a zkg is reachable from the sandbox PATH: $(command -v zkg)"
    fi
}

test_sandbox_starts_with_no_zenv_or_zeek_variables_set() {
    for v in ZENV ZENV_PREFIX ZENV_ZKG_DIR ZEEKPATH ZEEK_PLUGIN_PATH \
             ZKG_CONFIG_FILE ZEEK_ZKG_CONFIG_DIR ZEEK_ZKG_STATE_DIR \
             ZEEK_DIST ZEEK_BUILD_DIR; do
        eval "isset=\${$v+yes}"
        if [ -n "${isset:-}" ]; then
            eval "val=\$$v"
            fail "$v should start unset, is [${val-}]"
        fi
    done
}

test_each_case_gets_a_fresh_sandbox() {
    # Paired with the next case: neither may see the other's file.
    assert_missing "$SANDBOX/../shared-marker"
    : >"$SANDBOX/marker-from-case-one"
    assert_file "$SANDBOX/marker-from-case-one"
}

test_each_case_gets_a_fresh_sandbox_two() {
    assert_missing "$SANDBOX/marker-from-case-one"
}

run_cases
