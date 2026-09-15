#!/bin/sh
# Step D's gate: `zenv autoconfig`, the finding-6 safety gate, and the file
# editing both depend on.
#
# Covers plan tests 11 and 12, the recording-stub assertions, the INI one-line
# delta, the manifest.json round trip, and the five zeek_dist states.
#
# The rule the whole file exists to enforce: a single zkg invocation past the
# gate can move and delete another environment's installed packages, so every
# refusal case asserts zkg was never invoked at all -- not that it did nothing.
#
# shellcheck disable=SC2016
#   Single-quoted `$` in this file is shell code for another shell to expand,
#   or the literal text an assertion looks for. Expanding it in this process is
#   the bug these cases exist to catch.

. "$REPO_ROOT/tests/lib.sh"

# ---------------------------------------------------------------------------
# Local helpers
# ---------------------------------------------------------------------------

# An environment with a fake install in it. Mirrors test_shell.sh's copy.
mkenv() {
    _men=$1
    shift
    zenv new "$_men" >/dev/null 2>&1 || {
        fail "mkenv: zenv new $_men failed"
        return 1
    }
    mkprefix "$ZENV_ROOT/$_men/zeek" "$@"
}

# The recording zkg stub, on PATH where `command -v zkg` finds it.
mkzkg() { mkzkgstub "$SANDBOX/bin/zkg"; }

# A zkg that records what the manifest said *at the moment it was invoked*, then
# behaves like the normal stub. The only way to prove --fix-paths rewrote the
# manifest before zkg ran rather than after.
mkzkg_manifest_watcher() {
    mkzkgstub "$SANDBOX/bin/zkg.real"
    cat >"$SANDBOX/bin/zkg" <<'EOF'
#!/bin/sh
m=${ZEEK_ZKG_STATE_DIR:-}/manifest.json
if [ -f "$m" ]; then
    printf 'manifest-at-invocation: %s\n' "$(tr -d '\n' <"$m")" >>"$ZKG_STUB_LOG"
else
    printf 'manifest-at-invocation: <none>\n' >>"$ZKG_STUB_LOG"
fi
exec "$SANDBOX/bin/zkg.real" "$@"
EOF
    chmod +x "$SANDBOX/bin/zkg"
}

# A zkg that writes the manifest its *no-config fallback* would produce before
# doing its job, the way the real one does: zkg builds its Manager before it
# writes the config, so on a first-ever wiring there is no config to read yet and
# it records state_dir/{script_dir,plugin_dir,bin} in manifest.json -- then names
# the install in the config a moment later. Reproducing that ordering is the only
# way to test the shape a real first wiring actually leaves behind.
mkzkg_scaffold_writer() {
    mkzkgstub "$SANDBOX/bin/zkg.real"
    cat >"$SANDBOX/bin/zkg" <<'EOF'
#!/bin/sh
s=${ZEEK_ZKG_STATE_DIR:-}
if [ -d "$s" ] && [ ! -f "$s/manifest.json" ]; then
    cat >"$s/manifest.json" <<JSON
{
    "manifest_version": 1,
    "installed_packages": [],
    "script_dir": "$s/script_dir/packages",
    "plugin_dir": "$s/plugin_dir/packages",
    "bin_dir": "$s/bin"
}
JSON
fi
exec "$SANDBOX/bin/zkg.real" "$@"
EOF
    chmod +x "$SANDBOX/bin/zkg"
}

# A zkg that must never run: it says so in the log and fails.
mkzkg_poison() {
    cat >"$SANDBOX/bin/zkg" <<'EOF'
#!/bin/sh
printf 'POISON ran: %s\n' "$*" >>"${ZKG_STUB_LOG:-/dev/null}"
exit 1
EOF
    chmod +x "$SANDBOX/bin/zkg"
}

# Write a manifest.json with the three path keys set as given. A fifth argument
# names a package to record as installed, which is what distinguishes a state dir
# with something to lose from zkg's own empty scaffold.
mkmanifest() {
    _mmf=$1
    mkdir -p "$(dirname "$_mmf")"
    {
        printf '{\n'
        printf '    "manifest_version": 1,\n'
        if [ -n "${5:-}" ]; then
            printf '    "installed_packages": [{"package": {"name": "%s"}}],\n' "$5"
        else
            printf '    "installed_packages": [],\n'
        fi
        printf '    "script_dir": "%s",\n' "$2"
        printf '    "plugin_dir": "%s",\n' "$3"
        printf '    "bin_dir": "%s"\n' "$4"
        printf '}\n'
    } >"$_mmf"
}

# The value of one key in an env's zkg config.
cfg_get() { zenv_lib 'printf "%s" "$(_ini_get "$1" "$2")"' "$1" "$2"; }

# A sample config in zkg's own shape, with a comment and two other sections that
# must survive any edit.
mksampleconfig() {
    {
        printf '# zkg configuration file\n'
        printf '[sources]\n'
        printf 'zeek = https://github.com/zeek/packages\n'
        printf '\n'
        printf '[paths]\n'
        printf 'state_dir = /old/state\n'
        printf 'script_dir = /old/site\n'
        printf 'plugin_dir = /old/plugins\n'
        printf 'bin_dir = /old/bin\n'
        printf 'zeek_dist = /old/tree\n'
        printf '\n'
        printf '[templates]\n'
        printf 'default = https://github.com/zeek/package-template\n'
    } >"$1"
}

# ---------------------------------------------------------------------------
# INI editing: one key changes, everything else survives byte for byte
# ---------------------------------------------------------------------------

test_ini_set_rewrites_one_key_and_changes_exactly_one_line() {
    cfg=$SANDBOX/config
    mksampleconfig "$cfg"
    cp "$cfg" "$SANDBOX/before"

    zenv_lib '_ini_set "$1" paths state_dir "$2"' "$cfg" "$SANDBOX/newstate"

    d=$(diff "$SANDBOX/before" "$cfg" | grep -c '^[<>]')
    assert_eq 2 "$d" "one line replaced means one - and one + line"

    # And the rest is not merely equivalent, it is identical.
    grep -v '^state_dir' "$SANDBOX/before" >"$SANDBOX/b1"
    grep -v '^state_dir' "$cfg" >"$SANDBOX/b2"
    if ! cmp -s "$SANDBOX/b1" "$SANDBOX/b2"; then
        fail "every other line must survive byte for byte"
        fail_detail "$(diff "$SANDBOX/b1" "$SANDBOX/b2")"
    fi

    cfg_get "$cfg" state_dir
    assert_eq "$SANDBOX/newstate" "$OUT" "the new value is readable"
}

test_ini_set_keeps_the_sources_and_templates_sections() {
    cfg=$SANDBOX/config
    mksampleconfig "$cfg"
    zenv_lib '_ini_set "$1" paths zeek_dist ""' "$cfg"

    body=$(cat "$cfg")
    assert_contains "$body" '[sources]' "the default source section survives"
    assert_contains "$body" 'zeek = https://github.com/zeek/packages' \
        "and the source itself, which zkg only writes once"
    assert_contains "$body" '[templates]' "the templates section survives"
    assert_contains "$body" '# zkg configuration file' "comments survive"

    cfg_get "$cfg" zeek_dist
    assert_eq '' "$OUT" "an emptied key reads back empty"
}

test_ini_set_inserts_a_missing_key_under_its_own_section() {
    cfg=$SANDBOX/config
    {
        printf '[paths]\n'
        printf 'script_dir = /old/site\n'
        printf '\n'
        printf '[templates]\n'
        printf 'default = x\n'
    } >"$cfg"

    zenv_lib '_ini_set "$1" paths state_dir /new/state' "$cfg"

    # Under [paths], not after the blank line where [templates] would claim it.
    first=$(sed -n '2p' "$cfg")
    assert_eq 'state_dir = /new/state' "$first" \
        "insertion goes directly under the section header"
    zenv_lib 'if _ini_has "$1" templates state_dir; then printf wrong; else printf right; fi' "$cfg"
    assert_eq right "$OUT" "and not into the next section"
}

test_ini_set_appends_a_section_that_is_not_there_yet() {
    cfg=$SANDBOX/config
    printf '[sources]\nzeek = x\n' >"$cfg"
    zenv_lib '_ini_set "$1" paths state_dir /new/state' "$cfg"
    body=$(cat "$cfg")
    assert_contains "$body" '[paths]' "the missing section is appended"
    cfg_get "$cfg" state_dir
    assert_eq /new/state "$OUT"
    assert_contains "$body" 'zeek = x' "the existing section is untouched"
}

test_ini_set_creates_a_config_that_does_not_exist() {
    cfg=$SANDBOX/brand-new
    zenv_lib '_ini_set "$1" paths state_dir /s' "$cfg"
    assert_file "$cfg" "a missing file is created, not an error"
    cfg_get "$cfg" state_dir
    assert_eq /s "$OUT"
}

test_ini_has_is_section_aware_where_ini_get_is_not() {
    cfg=$SANDBOX/config
    printf '[a]\nk = 1\n[b]\nother = 2\n' >"$cfg"
    zenv_lib 'if _ini_has "$1" a k; then printf yes; else printf no; fi' "$cfg"
    assert_eq yes "$OUT" "k is in section a"
    zenv_lib 'if _ini_has "$1" b k; then printf yes; else printf no; fi' "$cfg"
    assert_eq no "$OUT" "k is not in section b"
    zenv_lib 'printf "%s" "$(_ini_get "$1" k)"' "$cfg"
    assert_eq 1 "$OUT" "_ini_get reads it without caring which section"
}

test_ini_values_containing_spaces_and_quotes_round_trip() {
    cfg=$SANDBOX/config
    printf '[paths]\nstate_dir = /old\n' >"$cfg"
    weird="$SANDBOX/it's here/state dir"
    zenv_lib '_ini_set "$1" paths state_dir "$2"' "$cfg" "$weird"
    cfg_get "$cfg" state_dir
    assert_eq "$weird" "$OUT" "a value with a space and a quote survives"
}

# ---------------------------------------------------------------------------
# manifest.json editing: python3's json module, never sed
# ---------------------------------------------------------------------------

test_manifest_set_changes_three_keys_and_round_trips_everything_else() {
    m=$SANDBOX/manifest.json
    cat >"$m" <<'EOF'
{
    "manifest_version": 1,
    "installed_packages": [
        {"package": {"name": "ja3", "url": "https://x/é"},
         "status": {"is_loaded": true, "tracking_method": "version"}}
    ],
    "script_dir": "/old/site/packages",
    "plugin_dir": "/old/plugins/packages",
    "bin_dir": "/old/bin",
    "note": "héllo ☃"
}
EOF
    zenv_lib '_manifest_set "$1" "$2" "$3" "$4"' \
        "$m" /new/site/packages /new/plugins/packages /new/bin

    for k in script_dir:/new/site/packages plugin_dir:/new/plugins/packages \
        bin_dir:/new/bin; do
        key=${k%%:*}
        want=${k#*:}
        zenv_lib 'printf "%s" "$(_manifest_get "$1" "$2")"' "$m" "$key"
        assert_eq "$want" "$OUT" "$key was rewritten"
    done

    # Nesting, unicode and key count all intact -- read back through json, since
    # json.dump escapes non-ASCII and a grep would be testing the encoding.
    got=$(python3 - "$m" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
p = d["installed_packages"][0]
print(d["note"], p["package"]["name"], p["package"]["url"],
      p["status"]["is_loaded"], len(d))
PY
)
    assert_eq "héllo ☃ ja3 https://x/é True 6" "$got" \
        "everything else round-trips and no key is added"
}

test_manifest_count_reads_the_installed_package_list() {
    m=$SANDBOX/manifest.json
    printf '{"installed_packages": [{"a": 1}, {"b": 2}], "script_dir": "/s"}\n' >"$m"
    zenv_lib 'printf "%s" "$(_manifest_count "$1")"' "$m"
    assert_eq 2 "$OUT"

    printf '{"installed_packages": []}\n' >"$m"
    zenv_lib 'printf "%s" "$(_manifest_count "$1")"' "$m"
    assert_eq 0 "$OUT" "an empty list is 0, not an error"

    zenv_lib 'if _manifest_count "$1"; then printf yes; else printf no; fi' \
        "$SANDBOX/nope.json"
    assert_eq no "$OUT" "a missing manifest fails rather than printing 0"
}

test_a_corrupt_manifest_is_an_error_not_a_silent_zero() {
    m=$SANDBOX/manifest.json
    printf 'this is not json\n' >"$m"
    zenv_lib 'if _manifest_get "$1" script_dir; then printf "\nyes"; else printf "\nno"; fi' "$m"
    assert_contains "$OUT" no "reading invalid JSON fails"
}

# ---------------------------------------------------------------------------
# Source-tree verification: the five states of finding 5b
# ---------------------------------------------------------------------------

test_the_version_mangling_matches_the_guard_symbol_spelling() {
    zenv_lib 'printf "%s" "$(_mangle_version "$1")"' 9.1.0-dev.75
    assert_eq 9_1_0_dev_75 "$OUT"
    zenv_lib 'printf "%s" "$(_mangle_version "$1")"' 8.0.0
    assert_eq 8_0_0 "$OUT"
    zenv_lib 'printf "%s" "$(_mangle_version "$1")"' ''
    assert_eq '' "$OUT" "an empty version mangles to nothing rather than hanging"
}

dist_state() {
    zenv_lib '_dist_state "$1" "$2"; printf "%s\n%s" "$_DIST_STATE" "$_DIST_WHY"' \
        "$1" "$2"
    printf '%s\n' "$OUT" | sed -n 1p
}

test_dist_state_reports_each_of_the_five_states() {
    mkdist "$SANDBOX/good" 9.1.0-dev.75
    assert_eq verified "$(dist_state "$SANDBOX/good" 9.1.0-dev.75)" \
        "VERSION and the built guard symbol both match"

    mkdist "$SANDBOX/other" 9.1.0-dev.96
    assert_eq drifted "$(dist_state "$SANDBOX/other" 9.1.0-dev.75)" \
        "a tree that moved on is drifted"

    mkdist "$SANDBOX/nobuild" 9.1.0-dev.75 --no-build
    assert_eq unbuilt "$(dist_state "$SANDBOX/nobuild" 9.1.0-dev.75)" \
        "no build/ is unbuilt, not drifted"

    assert_eq gone "$(dist_state "$SANDBOX/never-existed" 9.1.0-dev.75)"
    assert_eq none "$(dist_state '' 9.1.0-dev.75)" \
        "no tree at all is normal for a packaged Zeek"
}

test_dist_state_catches_a_tree_rebuilt_for_another_version() {
    # VERSION says the right thing but build/ was made for something else: the
    # case a VERSION-only comparison would call verified.
    mkdist "$SANDBOX/t" 9.1.0-dev.75
    printf '#define ZEEK_VERSION_FUNCTION zeek_version_9_1_0_dev_96_plugin_7\n' \
        >"$SANDBOX/t/build/zeek-version.h"
    assert_eq drifted "$(dist_state "$SANDBOX/t" 9.1.0-dev.75)"
}

# The regression the on-machine run found, and the reason mkdist now writes the
# whole header instead of the one line zenv reads: a real zeek-version.h names
# ZEEK_VERSION_FUNCTION twice -- the #define that spells the symbol out, and four
# lines later an `extern const char* ZEEK_VERSION_FUNCTION();` declaration that
# carries no version at all. Keeping the *last* line that mentions the name finds
# the declaration and reports every correctly built tree as drifted, which is
# exactly what `zenv doctor default` did against the real dev.75 install.
test_dist_state_verifies_a_header_that_also_declares_the_function() {
    mkdist "$SANDBOX/t" 9.1.0-dev.75
    assert_contains "$(cat "$SANDBOX/t/build/zeek-version.h")" \
        'extern const char* ZEEK_VERSION_FUNCTION();' \
        'the stub must carry the declaration a real header has'
    assert_eq verified "$(dist_state "$SANDBOX/t" 9.1.0-dev.75)" \
        'a declaration after the #define must not mask it'

    # And in the other order, so the fix cannot be "read the first line" either.
    mkdir -p "$SANDBOX/u/build"
    printf '9.1.0-dev.75\n' >"$SANDBOX/u/VERSION"
    {
        printf 'extern const char* ZEEK_VERSION_FUNCTION();\n'
        printf '#define ZEEK_VERSION_FUNCTION zeek_version_9_1_0_dev_75_plugin_7\n'
    } >"$SANDBOX/u/build/zeek-version.h"
    assert_eq verified "$(dist_state "$SANDBOX/u" 9.1.0-dev.75)" \
        'nor a declaration before it'

    # A header with the declaration and no matching #define is still drifted:
    # the symbol, not the name, is what a dlopen would check.
    mkdir -p "$SANDBOX/v/build"
    printf '9.1.0-dev.75\n' >"$SANDBOX/v/VERSION"
    printf 'extern const char* ZEEK_VERSION_FUNCTION();\n' \
        >"$SANDBOX/v/build/zeek-version.h"
    assert_eq drifted "$(dist_state "$SANDBOX/v" 9.1.0-dev.75)" \
        'the name alone proves nothing'
}

# ---------------------------------------------------------------------------
# The finding-6 gate: no zkg process may exist until it passes
# ---------------------------------------------------------------------------

test_autoconfig_refuses_when_the_install_reports_another_envs_directories() {
    mkzkg
    mkenv a
    # Exactly what a tree configured with a's --prefix, or installed through a
    # symlink, reports about itself.
    mkenv b \
        prefix="$ZENV_ROOT/a/zeek" \
        site_dir="$ZENV_ROOT/a/zeek/share/zeek/site" \
        plugin_dir="$ZENV_ROOT/a/zeek/lib/zeek/plugins"

    sentinel=$ZENV_ROOT/a/zeek/share/zeek/site/packages/sentinel
    mkdir -p "$(dirname "$sentinel")"
    printf 'a package installed under a\n' >"$sentinel"

    assert_status 1 zenv autoconfig b
    assert_contains "$OUT" "'b'" "the refusal names the env being wired"
    assert_contains "$OUT" "'a'" "and the env whose packages were at risk"
    assert_contains "$OUT" '--prefix' "and how to fix it"
    assert_contains "$OUT" 'no zkg command was run' "and says nothing ran"
    assert_zkg_never_ran "one zkg call here would have deleted a's packages"
    assert_file "$sentinel" "a's installed package is untouched"
    assert_missing "$ZENV_ROOT/b/zkg/config" "and b got no config"
}

test_the_gate_refuses_a_directory_outside_every_env_too() {
    mkzkg
    mkenv b site_dir="$SANDBOX/elsewhere/site"
    assert_status 1 zenv autoconfig b
    assert_contains "$OUT" "$SANDBOX/elsewhere/site" "the offending path is named"
    assert_contains "$OUT" 'outside its own prefix'
    assert_zkg_never_ran
}

test_the_gate_refuses_when_another_envs_config_already_claims_the_dirs() {
    mkzkg
    mkenv a
    mkenv b

    # b's install is honest about itself; a's config is what collides.
    mkdir -p "$ZENV_ROOT/a/zkg"
    {
        printf '[paths]\n'
        printf 'state_dir = %s\n' "$ZENV_ROOT/a/zkg"
        printf 'script_dir = %s\n' "$ZENV_ROOT/b/zeek/share/zeek/site"
        printf 'plugin_dir = %s\n' "$ZENV_ROOT/a/zeek/lib/zeek/plugins"
    } >"$ZENV_ROOT/a/zkg/config"

    assert_status 1 zenv autoconfig b
    assert_contains "$OUT" "'a'" "the colliding env is named"
    assert_contains "$OUT" script_dir "and which directory collides"
    assert_zkg_never_ran
}

test_autoconfig_refuses_a_stale_manifest_until_fix_paths_is_passed() {
    mkzkg_manifest_watcher
    mkenv a
    mkenv b

    # b's manifest points at a's directories: the disagreement that makes the
    # next zkg call move one tree onto the other and delete the destination.
    mkmanifest "$ZENV_ROOT/b/zkg/manifest.json" \
        "$ZENV_ROOT/a/zeek/share/zeek/site/packages" \
        "$ZENV_ROOT/a/zeek/lib/zeek/plugins/packages" \
        "$ZENV_ROOT/a/zeek/bin"

    assert_status 1 zenv autoconfig b
    assert_contains "$OUT" '--fix-paths' "the way out is named"
    assert_contains "$OUT" "$ZENV_ROOT/a/zeek/share/zeek/site/packages" \
        "and what the manifest currently claims"
    assert_zkg_never_ran "the manifest is compared before zkg is started"

    assert_status 0 zenv autoconfig b --fix-paths
    assert_eq 1 "$(zkg_invocations)" "with --fix-paths, zkg runs once"

    # The rewrite has to have happened *before* the invocation, or zkg would have
    # relocated on the old values first.
    seen=$(zkg_log | sed -n 's/^manifest-at-invocation: //p')
    assert_contains "$seen" "\"script_dir\": \"$ZENV_ROOT/b/zeek/share/zeek/site/packages\"" \
        "zkg saw the corrected manifest, not the stale one"
    assert_not_contains "$seen" "$ZENV_ROOT/a/zeek/share/zeek/site/packages" \
        "a's paths were gone before zkg started"
}

test_a_manifest_that_already_agrees_needs_no_fix_paths() {
    mkzkg
    mkenv a
    # The suffix rule: the manifest's script_dir and plugin_dir are the config's
    # plus /packages, its bin_dir is the config's unchanged.
    mkmanifest "$ZENV_ROOT/a/zkg/manifest.json" \
        "$ZENV_ROOT/a/zeek/share/zeek/site/packages" \
        "$ZENV_ROOT/a/zeek/lib/zeek/plugins/packages" \
        "$ZENV_ROOT/a/zeek/bin"

    assert_status 0 zenv autoconfig a
    assert_eq 1 "$(zkg_invocations)" "an agreeing manifest is not an obstacle"
}

# ---------------------------------------------------------------------------
# The scaffold manifest zkg leaves behind on a first wiring.
#
# Found on the real machine: `zenv autoconfig dev` against a freshly built
# environment succeeded, then refused at the very last step because the manifest
# zkg had just written from its own no-config fallback disagreed with the config
# zkg wrote immediately afterwards. Every new environment hit it, and the only way
# forward was a second run with --fix-paths -- for a manifest recording no
# packages at all. Correcting that shape is safe; correcting any other is not.
# ---------------------------------------------------------------------------

test_autoconfig_corrects_the_scaffold_manifest_zkg_writes_during_a_first_wiring() {
    mkzkg_scaffold_writer
    mkenv a

    # A first wiring must not end on a refusal.
    assert_status 0 zenv autoconfig a
    assert_eq 1 "$(zkg_invocations)" "zkg ran once"
    assert_contains "$OUT" 'manifest' "and says the manifest was corrected"

    # Corrected to the install, in the manifest's own suffix convention: the two
    # directory keys carry /packages, bin_dir does not.
    m=$ZENV_ROOT/a/zkg/manifest.json
    for k in "script_dir:$ZENV_ROOT/a/zeek/share/zeek/site/packages" \
        "plugin_dir:$ZENV_ROOT/a/zeek/lib/zeek/plugins/packages" \
        "bin_dir:$ZENV_ROOT/a/zeek/bin"; do
        key=${k%%:*}
        want=${k#*:}
        zenv_lib 'printf "%s" "$(_manifest_get "$1" "$2")"' "$m" "$key"
        assert_eq "$want" "$OUT" "$key now names the install"
    done

    # A second run is then a no-op rather than another correction.
    assert_status 0 zenv autoconfig a
    assert_not_contains "$OUT" 'rewritten' 'the correction happens once'
}

test_autoconfig_corrects_a_scaffold_manifest_that_predates_the_run() {
    # The same shape, but already on disk before zenv starts -- the step-4 check
    # rather than the step-9 re-check. It must be corrected before zkg runs.
    mkzkg_manifest_watcher
    mkenv a
    mkmanifest "$ZENV_ROOT/a/zkg/manifest.json" \
        "$ZENV_ROOT/a/zkg/script_dir/packages" \
        "$ZENV_ROOT/a/zkg/plugin_dir/packages" \
        "$ZENV_ROOT/a/zkg/bin"

    # No --fix-paths needed for an empty scaffold.
    assert_status 0 zenv autoconfig a
    seen=$(zkg_log | sed -n 's/^manifest-at-invocation: //p')
    assert_contains "$seen" "\"script_dir\": \"$ZENV_ROOT/a/zeek/share/zeek/site/packages\"" \
        'zkg saw the corrected manifest, so the rewrite preceded it'
}

test_autoconfig_still_refuses_a_scaffold_manifest_that_has_a_package_in_it() {
    # Paths inside the state dir, but something recorded as installed. Now there
    # is something for a relocation to move, so the refusal stands.
    mkzkg_poison
    mkenv a
    mkmanifest "$ZENV_ROOT/a/zkg/manifest.json" \
        "$ZENV_ROOT/a/zkg/script_dir/packages" \
        "$ZENV_ROOT/a/zkg/plugin_dir/packages" \
        "$ZENV_ROOT/a/zkg/bin" \
        zeek/salesforce/ja3

    assert_status 1 zenv autoconfig a
    assert_contains "$OUT" '--fix-paths' 'the way out is still named'
    assert_zkg_never_ran 'and nothing was run'
}

test_autoconfig_still_refuses_an_empty_manifest_naming_another_install() {
    # Empty, but pointing outside the state dir at another environment's install:
    # the finding-6 shape, which stays a refusal no matter how empty it is.
    mkzkg_poison
    mkenv a
    mkenv b
    mkmanifest "$ZENV_ROOT/b/zkg/manifest.json" \
        "$ZENV_ROOT/a/zeek/share/zeek/site/packages" \
        "$ZENV_ROOT/a/zeek/lib/zeek/plugins/packages" \
        "$ZENV_ROOT/a/zeek/bin"

    assert_status 1 zenv autoconfig b
    assert_contains "$OUT" "$ZENV_ROOT/a/zeek/share/zeek/site/packages" \
        'the paths it would have clobbered are named'
    assert_zkg_never_ran 'emptiness alone does not make a rewrite safe'
}

test_new_never_seeds_an_env_with_another_manifest() {
    mkzkg
    mkenv a
    mkmanifest "$ZENV_ROOT/a/zkg/manifest.json" /s/packages /p/packages /b

    assert_status 0 zenv new b
    assert_missing "$ZENV_ROOT/b/zkg/manifest.json" \
        "a new env starts with an empty state dir, never a copy"
    assert_zkg_never_ran "and 'new' runs no zkg at all"
}

# ---------------------------------------------------------------------------
# Plan test 12: ordering. The ZEEK_ZKG_* overrides are ignored unless the
# directory already exists, so creating it after invoking zkg would silently
# operate on the real ~/.zkg.
# ---------------------------------------------------------------------------

test_autoconfig_creates_the_zkg_dir_before_invoking_zkg() {
    mkzkg
    mkenv a
    rm -rf "$ZENV_ROOT/a/zkg"
    assert_missing "$ZENV_ROOT/a/zkg" "the state dir starts absent"

    assert_status 0 zenv autoconfig a

    log=$(zkg_log)
    assert_contains "$log" "isdir $ZENV_ROOT/a/zkg: yes" \
        "zkg saw an existing state dir, so its override was honoured"
    assert_contains "$log" "ZEEK_ZKG_CONFIG_DIR: $ZENV_ROOT/a/zkg"
    assert_contains "$log" "ZEEK_ZKG_STATE_DIR: $ZENV_ROOT/a/zkg"
    assert_file "$ZENV_ROOT/a/zkg/config" "and the config landed in the env"
    assert_missing "$HOME/.zkg" "nothing fell back to the home directory"
}

test_autoconfig_unsets_zkg_config_file_and_puts_the_env_first_on_path() {
    mkzkg
    mkenv a
    ZKG_CONFIG_FILE=$SANDBOX/somewhere/else/config
    export ZKG_CONFIG_FILE

    assert_status 0 zenv autoconfig a

    log=$(zkg_log)
    assert_contains "$log" 'ZKG_CONFIG_FILE: <unset>' \
        "an inherited config file must not win over the env being wired"
    assert_contains "$log" "PATH: $ZENV_ROOT/a/zeek/bin:" \
        "the env's own zeek-config is the one zkg interrogates"
    assert_contains "$log" 'argv: autoconfig --force'
}

test_autoconfig_prefers_the_envs_own_zkg_over_one_on_path() {
    mkzkg_poison
    mkenv a
    mkzkgstub "$ZENV_ROOT/a/zeek/bin/zkg"

    assert_status 0 zenv autoconfig a
    assert_not_contains "$(zkg_log)" POISON \
        "the bundled zkg wins: its baked python dir matches this build"
    assert_eq 1 "$(zkg_invocations)"
}

test_autoconfig_needs_no_zkg_dir_to_exist_and_says_so_when_zkg_is_missing() {
    mkenv a
    assert_status 1 zenv autoconfig a
    assert_contains "$OUT" 'no zkg found'
    assert_contains "$OUT" "$ZENV_ROOT/a/zeek/bin/zkg" "both places it looked"
}

# ---------------------------------------------------------------------------
# What the config ends up saying
# ---------------------------------------------------------------------------

test_autoconfig_writes_the_envs_own_paths_and_prints_the_config() {
    mkzkg
    mkenv a

    capture zenv autoconfig a || fail "autoconfig should succeed"
    assert_eq "$ZENV_ROOT/a/zkg/config" "$OUT" \
        "stdout is the config path and nothing else"
    assert_contains "$ERR" 'wiring zkg' "the chatter goes to stderr"

    cfg=$ZENV_ROOT/a/zkg/config
    cfg_get "$cfg" state_dir
    assert_eq "$ZENV_ROOT/a/zkg" "$OUT"
    cfg_get "$cfg" script_dir
    assert_eq "$ZENV_ROOT/a/zeek/share/zeek/site" "$OUT"
    cfg_get "$cfg" plugin_dir
    assert_eq "$ZENV_ROOT/a/zeek/lib/zeek/plugins" "$OUT"
    cfg_get "$cfg" bin_dir
    assert_eq "$ZENV_ROOT/a/zeek/bin" "$OUT"
}

test_autoconfig_reasserts_a_state_dir_that_drifted() {
    mkzkg
    mkenv a
    # zkg autoconfig never writes state_dir, so a stale one survives its --force.
    mkdir -p "$ZENV_ROOT/a/zkg"
    {
        printf '[sources]\nzeek = x\n\n[paths]\n'
        printf 'state_dir = %s\n' "$SANDBOX/somewhere-stale"
        printf 'script_dir = /old\nplugin_dir = /old\nbin_dir = /old\nzeek_dist = \n'
        printf '\n[templates]\ndefault = y\n'
    } >"$ZENV_ROOT/a/zkg/config"

    capture zenv autoconfig a || fail "autoconfig should succeed"
    assert_contains "$ERR" 'state_dir' "the correction is reported"

    cfg_get "$ZENV_ROOT/a/zkg/config" state_dir
    assert_eq "$ZENV_ROOT/a/zkg" "$OUT" "state_dir is re-asserted by zenv"
    assert_contains "$(cat "$ZENV_ROOT/a/zkg/config")" '[sources]' \
        "and the sections zkg only writes once are preserved"
}

test_a_verified_tree_is_written_to_zeek_dist_unchanged() {
    mkzkg
    mkdist "$SANDBOX/src" 9.1.0-dev.42
    mkenv a version=9.1.0-dev.42 zeek_dist="$SANDBOX/src"

    capture zenv autoconfig a || fail "autoconfig should succeed"
    assert_contains "$ERR" 'verified'
    cfg_get "$ZENV_ROOT/a/zkg/config" zeek_dist
    assert_eq "$SANDBOX/src" "$OUT"
}

test_an_unverified_tree_makes_zeek_dist_empty_and_names_the_failed_check() {
    mkzkg
    mkdist "$SANDBOX/src" 9.1.0-dev.96
    mkenv a version=9.1.0-dev.42 zeek_dist="$SANDBOX/src"

    capture zenv autoconfig a || fail "autoconfig should succeed"
    cfg_get "$ZENV_ROOT/a/zkg/config" zeek_dist
    assert_eq '' "$OUT" "empty fails fast; stale builds against the wrong sources"
    assert_contains "$ERR" drifted "the state is named"
    assert_contains "$ERR" 9.1.0-dev.96 "and the check that decided it"
}

test_the_env_src_override_beats_what_the_install_reports() {
    mkzkg
    mkdist "$SANDBOX/asserted" 9.1.0-dev.42
    mkenv a version=9.1.0-dev.42 zeek_dist="$SANDBOX/baked-and-gone"
    printf 'src = %s\n' "$SANDBOX/asserted" >>"$ZENV_ROOT/a/env"

    capture zenv autoconfig a || fail "autoconfig should succeed"
    cfg_get "$ZENV_ROOT/a/zkg/config" zeek_dist
    assert_eq "$SANDBOX/asserted" "$OUT" "src is used -- after being verified"
}

# ---------------------------------------------------------------------------
# The build commit: what makes a shared checkout manageable
#
# Verification can tell you the tree no longer matches; only a recorded commit
# can tell you which one to check out again. autoconfig is the only honest moment
# to record it -- the tree matches the install right then -- and a drifted tree
# must never overwrite it, because drift is when it is needed.
# ---------------------------------------------------------------------------

test_autoconfig_records_the_commit_a_verified_tree_was_on() {
    have_git || return 0
    mkzkg
    mkdist "$SANDBOX/src" 9.1.0-dev.42
    sha=$(mkgit "$SANDBOX/src") || return 1
    mkenv a version=9.1.0-dev.42 zeek_dist="$SANDBOX/src"

    capture zenv autoconfig a || fail "autoconfig should succeed"
    body=$(cat "$ZENV_ROOT/a/env")
    assert_contains "$body" "src_commit=$sha" "the full sha, not an abbreviation"
    assert_contains "$body" 'src_version=9.1.0-dev.42' \
        "recorded with the version it verified against"
    assert_contains "$ERR" "$(printf '%.12s' "$sha")" "and reported"
}

test_autoconfig_records_no_commit_for_a_tree_that_is_not_a_checkout() {
    mkzkg
    mkdist "$SANDBOX/src" 9.1.0-dev.42
    mkenv a version=9.1.0-dev.42 zeek_dist="$SANDBOX/src"

    capture zenv autoconfig a || fail "a tarball tree is not a fault"
    assert_contains "$ERR" verified "the tree still verifies"
    zenv_lib '_env_get "$1" src_commit || printf unset' a
    assert_eq unset "$OUT" "nothing to record, so nothing recorded"
}

test_autoconfig_records_no_commit_for_an_unverified_tree() {
    have_git || return 0
    mkzkg
    mkdist "$SANDBOX/src" 9.1.0-dev.96
    mkgit "$SANDBOX/src" >/dev/null || return 1
    mkenv a version=9.1.0-dev.42 zeek_dist="$SANDBOX/src"

    capture zenv autoconfig a || fail "autoconfig should succeed"
    assert_contains "$ERR" drifted
    zenv_lib '_env_get "$1" src_commit || printf unset' a
    assert_eq unset "$OUT" \
        "an unverified tree is no evidence about what was built"
}

test_a_recorded_commit_survives_a_later_autoconfig_on_a_drifted_tree() {
    have_git || return 0
    mkzkg
    mkdist "$SANDBOX/src" 9.1.0-dev.42
    sha=$(mkgit "$SANDBOX/src") || return 1
    mkenv a version=9.1.0-dev.42 zeek_dist="$SANDBOX/src"
    capture zenv autoconfig a || fail "the first wiring should succeed"
    assert_contains "$(cat "$ZENV_ROOT/a/env")" "src_commit=$sha" || return 1

    # The shared tree moves on to another version, and something re-runs
    # autoconfig. Clearing the record here would throw away the one fact that
    # can name the commit to come back to.
    mkdist "$SANDBOX/src" 9.1.0-dev.96
    mkgit_move "$SANDBOX/src" >/dev/null || return 1
    capture zenv autoconfig a || fail "autoconfig should still succeed"

    cfg_get "$ZENV_ROOT/a/zkg/config" zeek_dist
    assert_eq '' "$OUT" "the drifted tree is still blanked"
    body=$(cat "$ZENV_ROOT/a/env")
    assert_contains "$body" "src_commit=$sha" "the build commit is kept"
    assert_contains "$body" 'src_version=9.1.0-dev.42' "with the version it was for"
}

test_running_autoconfig_twice_changes_nothing_the_second_time() {
    mkzkg
    mkenv a
    assert_status 0 zenv autoconfig a
    cp "$ZENV_ROOT/a/zkg/config" "$SANDBOX/first"
    assert_status 0 zenv autoconfig a
    if ! cmp -s "$SANDBOX/first" "$ZENV_ROOT/a/zkg/config"; then
        fail "a second autoconfig must be a no-op"
        fail_detail "$(diff "$SANDBOX/first" "$ZENV_ROOT/a/zkg/config")"
    fi
}

test_autoconfig_refuses_an_env_with_nothing_installed() {
    mkzkg
    assert_status 0 zenv new a
    assert_status 1 zenv autoconfig a
    assert_contains "$OUT" 'nothing installed'
    assert_contains "$OUT" '--prefix' "it points at the prefix you install into"
    assert_zkg_never_ran
}

test_autoconfig_rejects_unknown_options_and_a_second_name() {
    mkzkg
    mkenv a
    assert_status 1 zenv autoconfig a --nope
    assert_contains "$OUT" "unknown option"
    assert_status 1 zenv autoconfig a b
    assert_contains "$OUT" 'only one name'
    assert_zkg_never_ran
}

# ---------------------------------------------------------------------------
# dist, list, and the activation hook
# ---------------------------------------------------------------------------

test_dist_prints_a_verified_tree_and_nothing_otherwise() {
    mkdist "$SANDBOX/src" 9.1.0-dev.42
    mkenv a version=9.1.0-dev.42 zeek_dist="$SANDBOX/src"

    capture zenv dist a || fail "dist should succeed for a verified tree"
    assert_eq "$SANDBOX/src" "$OUT"

    mkenv b version=9.1.0-dev.42 zeek_dist="$SANDBOX/src-gone"
    if capture zenv dist b; then
        fail "dist must fail when it cannot vouch for the tree"
    fi
    assert_eq '' "$OUT" "--zeek-dist=\$(zenv dist) is empty rather than wrong"
    assert_contains "$ERR" gone "and stderr says which state it is in"
}

test_dist_needs_an_install_to_compare_against() {
    zenv new a >/dev/null 2>&1
    if capture zenv dist a; then fail "dist must fail with nothing installed"; fi
    assert_eq '' "$OUT"
    assert_contains "$ERR" 'nothing installed'
}

test_list_shows_the_package_count_from_the_envs_own_manifest() {
    mkenv a
    mkenv b
    printf '{"installed_packages": [{"x": 1}, {"y": 2}, {"z": 3}]}\n' \
        >"$ZENV_ROOT/a/zkg/manifest.json"

    capture zenv list || fail "list should succeed"
    a_pkgs=$(printf '%s\n' "$OUT" | awk '$1 == "a" { print $4 }')
    b_pkgs=$(printf '%s\n' "$OUT" | awk '$1 == "b" { print $4 }')
    assert_eq 3 "$a_pkgs" "counted without running zkg"
    assert_eq - "$b_pkgs" "no manifest is '-', not 0"
    assert_contains "$OUT" PKGS "the column is labelled"
}

test_activate_wires_zkg_when_the_env_has_no_config_yet() {
    mkzkg
    mkenv a
    assert_missing "$ZENV_ROOT/a/zkg/config"

    capture zenv shell activate a || fail "activate should succeed"
    assert_file "$ZENV_ROOT/a/zkg/config" "the missing config is written"
    assert_eq 1 "$(zkg_invocations)"

    # And the wiring is reflected in the code it emits.
    assert_not_contains "$OUT" 'zkg stub: wrote' \
        "none of zkg's own output reached the code stdout"
    assert_contains "$ERR" 'wiring zkg' "which means it went to stderr"

    # The emitted code quotes every path, so what it says has to be checked by
    # running it rather than by looking for a literal. The config exists by now,
    # so this second activation wires nothing again.
    probe /bin/sh 'eval "$("$ZENV_BIN" shell activate a)"'
    assert_eq "$ZENV_ROOT/a/zkg/config" "$(probe_var ZKG_CONFIG_FILE)" \
        "the shell points zkg at the config that was just created"
    assert_contains "$(probe_var ZEEKPATH)" "$ZENV_ROOT/a/zeek/share/zeek/site" \
        "and zkg's script_dir is in the search path"
}

test_activate_does_not_rerun_autoconfig_when_a_config_exists() {
    mkzkg
    mkenv a
    assert_status 0 zenv autoconfig a
    capture zenv shell activate a || fail "activate should succeed"
    assert_eq 1 "$(zkg_invocations)" "still just the explicit autoconfig"
}

test_no_autoconfig_skips_the_wiring_and_still_activates() {
    mkzkg
    mkenv a
    capture zenv shell activate a --no-autoconfig || fail "activate should succeed"
    assert_zkg_never_ran "--no-autoconfig means no zkg at all"
    assert_missing "$ZENV_ROOT/a/zkg/config"
    assert_contains "$OUT" 'ZENV=' "the env is still activated"
}

test_activation_survives_an_autoconfig_that_refuses() {
    # No zkg anywhere: wiring cannot happen, but activating is still correct --
    # a config-less state dir uses zkg's self-contained defaults, which name no
    # install prefix and so cannot trigger the relocation the gate prevents.
    mkenv a
    capture zenv shell activate a || fail "activate must not fail with no zkg"
    assert_contains "$OUT" 'ZENV=' "the environment is set"
    assert_contains "$ERR" 'could not wire zkg' "and the failure is reported"
    assert_contains "$ERR" 'zenv autoconfig a' "with the command to retry"
}

test_activation_does_not_wire_an_env_with_nothing_installed() {
    mkzkg
    zenv new a >/dev/null 2>&1
    capture zenv shell activate a || fail "a bare env still activates"
    assert_zkg_never_ran "there is no install to wire zkg to yet"
    assert_contains "$OUT" 'ZENV='
}

test_autoconfig_and_dist_appear_in_the_help() {
    capture zenv help || fail "help should succeed"
    assert_contains "$OUT" 'autoconfig'
    assert_contains "$OUT" '--fix-paths'
    assert_contains "$OUT" 'dist [name]'
}

run_cases
