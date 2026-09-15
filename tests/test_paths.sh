#!/bin/sh
# Step B's gate: root resolution, _realpath, key=value parsing, and the
# root / prefix / zkgdir / new / list commands.
#
# Covers plan tests 1, 2 and 2b, name validation, the _realpath unit matrix and
# the malformed-`env` matrix.
#
# shellcheck disable=SC2016
#   Single-quoted `$` in this file is shell code for another shell to expand,
#   or the literal text an assertion looks for. Expanding it in this process is
#   the bug these cases exist to catch.

. "$REPO_ROOT/tests/lib.sh"

# ---------------------------------------------------------------------------
# Local helpers
# ---------------------------------------------------------------------------

# zenv_lib (loading bin/zenv's functions without dispatching) lives in lib.sh:
# step C's tests need it too.

# A copy of bin/zenv with the baked default rewritten, exactly the one-line edit
# install.sh --root will make. Proves the line is mechanically rewritable now,
# well before install.sh exists to do it.
mkzenv_baked() {
    _dst=$1
    _baked=$2
    sed "s|^ZENV_ROOT_DEFAULT=.*|ZENV_ROOT_DEFAULT=\"$_baked\"|" "$ZENV_BIN" >"$_dst"
    chmod +x "$_dst"
}

# Stubs for every build tool, so "zenv never builds Zeek" is asserted by
# behaviour rather than by grepping for words the help text legitimately uses.
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
    # ./configure is invoked by path, not through PATH, so shadow it in the cwd.
    cp "$SANDBOX/bin/configure" "$SANDBOX/configure"
}

assert_no_build_tool_ran() {
    if [ ! -f "$BUILD_STUB_LOG" ]; then return 0; fi
    fail "${1:-zenv executed a build tool}"
    fail_detail "log: $(cat "$BUILD_STUB_LOG")"
    return 1
}

# ---------------------------------------------------------------------------
# Plan test 1 -- `zenv new` and the layout
# ---------------------------------------------------------------------------

test_new_creates_the_layout() {
    assert_status 0 zenv new a || return 1
    assert_dir "$ZENV_ROOT/a" "the env dir"
    assert_dir "$ZENV_ROOT/a/zeek" "the install prefix"
    assert_dir "$ZENV_ROOT/a/zkg" "the zkg state dir"
    assert_file "$ZENV_ROOT/a/env" "the metadata file"
    assert_file "$ZENV_ROOT/a/activate" "the source-able stub"
}

test_new_prints_the_prefix_on_stdout() {
    capture zenv new a
    assert_eq "$ZENV_ROOT/a/zeek" "$OUT" "stdout should be the prefix alone"
    assert_contains "$ERR" "created environment 'a'" "guidance goes to stderr"
}

test_prefix_and_zkgdir_print_the_env_paths() {
    zenv new a >/dev/null 2>&1
    capture zenv prefix a
    assert_eq "$ZENV_ROOT/a/zeek" "$OUT" "zenv prefix a"
    capture zenv zkgdir a
    assert_eq "$ZENV_ROOT/a/zkg" "$OUT" "zenv zkgdir a"
}

# Finding 1: an env must be installed to its own *real* path. If `zenv prefix`
# handed back a path through a symlink, every env would bake an identical
# prefix and their zkg configs would collide.
test_prefix_is_the_real_path_not_the_symlink() {
    real="$SANDBOX/real-root"
    link="$SANDBOX/link-root"
    mkdir -p "$real"
    ln -s "$real" "$link"
    ZENV_ROOT=$link
    export ZENV_ROOT

    capture zenv new a
    assert_eq "$real/a/zeek" "$OUT" "new should print the physical prefix"
    capture zenv prefix a
    assert_eq "$real/a/zeek" "$OUT" "prefix should resolve through the symlink"
    assert_not_contains "$OUT" "link-root" "no symlink component may survive"
    capture zenv zkgdir a
    assert_eq "$real/a/zkg" "$OUT" "zkgdir should resolve too"
    capture zenv root
    assert_eq "$real" "$OUT" "and the root itself is reported physically"
}

# Metadata beside the prefix, never inside it, so `make install` into the prefix
# can never collide with zenv's own files.
test_metadata_sits_beside_the_prefix_not_inside_it() {
    zenv new a >/dev/null 2>&1
    assert_missing "$ZENV_ROOT/a/zeek/env"
    assert_missing "$ZENV_ROOT/a/zeek/activate"
    left=$(find "$ZENV_ROOT/a/zeek" -mindepth 1 | wc -l | tr -d ' ')
    assert_eq 0 "$left" "the prefix must be left completely empty"
}

test_new_writes_readable_metadata() {
    zenv new a >/dev/null 2>&1
    body=$(cat "$ZENV_ROOT/a/env")
    assert_contains "$body" "name=a"
    assert_contains "$body" "prefix=$ZENV_ROOT/a/zeek"
    assert_contains "$body" "zkg_dir=$ZENV_ROOT/a/zkg"
    assert_contains "$body" "created="
}

test_new_refuses_to_overwrite_an_existing_env() {
    zenv new a >/dev/null 2>&1
    printf 'sentinel\n' >"$ZENV_ROOT/a/zeek/keep-me"
    assert_status 1 zenv new a || return 1
    assert_contains "$OUT" "already exists" "the error should say why"
    assert_file "$ZENV_ROOT/a/zeek/keep-me" "the existing env must be untouched"
}

test_new_refuses_a_directory_that_is_not_an_env() {
    mkdir -p "$ZENV_ROOT/a"
    printf 'not mine\n' >"$ZENV_ROOT/a/something"
    assert_status 1 zenv new a || return 1
    assert_contains "$OUT" "not a zenv environment"
    assert_file "$ZENV_ROOT/a/something" "the directory must be left alone"
}

test_new_records_a_validated_src() {
    tree="$SANDBOX/src-tree"
    mkdir -p "$tree"
    zenv new a --src "$tree" >/dev/null 2>&1
    assert_contains "$(cat "$ZENV_ROOT/a/env")" "src=$tree"

    assert_status 1 zenv new b --src "$SANDBOX/nope" || return 1
    assert_contains "$OUT" "not a directory"
    assert_missing "$ZENV_ROOT/b"

    assert_status 1 zenv new c --src relative/path || return 1
    assert_contains "$OUT" "absolute"
}

# Finding 6: a new env's state dir must start empty, never seeded from another
# env's manifest -- that disagreement is what makes zkg relocate and delete.
test_new_never_seeds_a_manifest() {
    zenv new a >/dev/null 2>&1
    printf '{"installed_packages": ["x"]}\n' >"$ZENV_ROOT/a/zkg/manifest.json"
    zenv new b >/dev/null 2>&1
    assert_missing "$ZENV_ROOT/b/zkg/manifest.json"
    left=$(find "$ZENV_ROOT/b/zkg" -mindepth 1 | wc -l | tr -d ' ')
    assert_eq 0 "$left" "a new zkg dir must be empty"
}

# ---------------------------------------------------------------------------
# Plan test 2 -- zenv never builds Zeek
# ---------------------------------------------------------------------------

test_no_command_executes_a_build_tool() {
    mkbuildstubs
    zenv new a >/dev/null 2>&1
    zenv new b --src "$SANDBOX" >/dev/null 2>&1
    zenv root >/dev/null 2>&1
    zenv root --source >/dev/null 2>&1
    zenv prefix a >/dev/null 2>&1
    zenv zkgdir a >/dev/null 2>&1
    zenv list >/dev/null 2>&1
    zenv list --names >/dev/null 2>&1
    zenv help >/dev/null 2>&1
    zenv version >/dev/null 2>&1
    assert_no_build_tool_ran "no zenv command may run configure/make/cmake"
}

# The build hint zenv prints is guidance, not an invocation -- and it has to
# match the loop a human actually uses, or they will ignore it.
test_new_tells_you_where_to_install_without_building() {
    capture zenv new dev
    assert_contains "$ERR" "zenv does not build Zeek"
    assert_contains "$ERR" '--prefix="$(zenv prefix dev)"' "the prefix hint"
    assert_contains "$ERR" "zenv autoconfig dev" "the follow-up step"
    # --with-prefix does not exist; zeek's configure exits 1 on unknown options.
    assert_not_contains "$ERR" "--with-prefix"
}

# ---------------------------------------------------------------------------
# Plan test 2b -- root resolution precedence
# ---------------------------------------------------------------------------

test_root_comes_from_the_environment() {
    capture zenv root
    assert_eq "$ZENV_ROOT" "$OUT" "stdout is the path alone, so \$(zenv root) works"
    assert_contains "$ERR" "environment" "stderr names the source"
    capture zenv root --source
    assert_eq "environment" "$OUT"
}

test_root_falls_back_to_the_builtin_default() {
    unset ZENV_ROOT
    capture zenv root
    assert_eq "$HOME/zenv" "$OUT"
    capture zenv root --source
    assert_eq "built-in default" "$OUT"
}

test_root_uses_the_baked_installed_default() {
    baked="$SANDBOX/baked-root"
    mkzenv_baked "$SANDBOX/bin/zenv-baked" "$baked"
    unset ZENV_ROOT
    capture "$SANDBOX/bin/zenv-baked" root
    assert_eq "$baked" "$OUT"
    capture "$SANDBOX/bin/zenv-baked" root --source
    assert_eq "installed default" "$OUT"
}

test_environment_root_beats_the_baked_default() {
    baked="$SANDBOX/baked-root"
    mkzenv_baked "$SANDBOX/bin/zenv-baked" "$baked"
    ZENV_ROOT="$SANDBOX/chosen"
    export ZENV_ROOT
    capture "$SANDBOX/bin/zenv-baked" root
    assert_eq "$SANDBOX/chosen" "$OUT"
    capture "$SANDBOX/bin/zenv-baked" root --source
    assert_eq "environment" "$OUT"
    # And the baked value is genuinely there, so the test is not vacuous.
    assert_contains "$(cat "$SANDBOX/bin/zenv-baked")" "$baked"
}

# install.sh will rewrite exactly one line. Assert that shape now, so the
# installer cannot be written against a moving target.
test_the_baked_default_is_one_rewritable_line() {
    n=$(grep -c '^ZENV_ROOT_DEFAULT=' "$ZENV_BIN")
    assert_eq 1 "$n" "exactly one assignment to rewrite"
    mkzenv_baked "$SANDBOX/rewritten" "$SANDBOX/somewhere"
    delta=$(diff "$ZENV_BIN" "$SANDBOX/rewritten" | grep -c '^[<>]')
    assert_eq 2 "$delta" "a whole-file diff of one changed line (one <, one >)"
}

test_an_empty_root_is_an_error_not_a_silent_fallback() {
    ZENV_ROOT=""
    export ZENV_ROOT
    assert_status 1 zenv root || return 1
    assert_contains "$OUT" "set but empty"
    assert_missing "$HOME/zenv" "it must not quietly fall back to \$HOME/zenv"
}

test_a_relative_root_is_an_error() {
    ZENV_ROOT="relative/root"
    export ZENV_ROOT
    assert_status 1 zenv root || return 1
    assert_contains "$OUT" "absolute"
    assert_missing "$SANDBOX/relative"
}

test_a_root_of_slash_is_refused() {
    ZENV_ROOT="/"
    export ZENV_ROOT
    assert_status 1 zenv root || return 1
    assert_contains "$OUT" "must not be /"
}

test_trailing_slashes_on_the_root_are_normalised() {
    ZENV_ROOT="$SANDBOX/troot///"
    export ZENV_ROOT
    capture zenv root
    assert_eq "$SANDBOX/troot" "$OUT"
}

# The root is created by `zenv new`, never by merely asking about it.
test_the_root_is_not_created_until_new() {
    assert_missing "$ZENV_ROOT" "the harness must not pre-create it"
    zenv root >/dev/null 2>&1
    zenv root --source >/dev/null 2>&1
    zenv list >/dev/null 2>&1
    zenv version >/dev/null 2>&1
    assert_missing "$ZENV_ROOT" "inspection must not create the root"
    zenv new a >/dev/null 2>&1
    assert_dir "$ZENV_ROOT" "new creates it"
}

test_a_deep_root_path_is_created() {
    ZENV_ROOT="$SANDBOX/x/y/z/zenv"
    export ZENV_ROOT
    assert_status 0 zenv new a || return 1
    assert_dir "$ZENV_ROOT/a/zeek"
}

# The PATH-surgery table's "no regex interpretation" hazard, applied to the root
# itself: a name full of glob and regex metacharacters plus a space.
test_a_root_with_metacharacters_and_a_space_works() {
    ZENV_ROOT="$SANDBOX/zenv.d+x[1] root"
    export ZENV_ROOT
    assert_status 0 zenv new a || return 1
    assert_dir "$ZENV_ROOT/a/zeek"
    capture zenv prefix a
    assert_eq "$ZENV_ROOT/a/zeek" "$OUT"
    capture zenv list --names
    assert_eq "a" "$OUT"
    capture zenv root
    assert_eq "$ZENV_ROOT" "$OUT"
}

# ---------------------------------------------------------------------------
# Name validation
# ---------------------------------------------------------------------------

test_new_rejects_invalid_names() {
    for bad in 'a/b' '.hidden' '..' '.' 'config' 'a b' 'a*' 'a?' 'a;touch x' \
               'a$b' 'a|b' 'a:b' 'a"b' "a'b" '_lead' 'a\\b' '../escape'; do
        if ! assert_status 1 zenv new "$bad"; then
            fail_detail "name that should have been rejected: [$bad]"
            continue
        fi
        assert_contains "$OUT" "zenv:" "an error message for [$bad]"
    done
    # Nothing may have been created by any of them.
    if [ -d "$ZENV_ROOT" ]; then
        left=$(find "$ZENV_ROOT" -mindepth 1 | wc -l | tr -d ' ')
        assert_eq 0 "$left" "a rejected name must create nothing"
    fi
}

test_new_rejects_the_reserved_name_config() {
    assert_status 1 zenv new config || return 1
    assert_contains "$OUT" "reserved" "say why, not just 'invalid'"
    assert_missing "$ZENV_ROOT/config"
}

test_new_requires_a_name() {
    assert_status 1 zenv new || return 1
    assert_contains "$OUT" "name is required"
}

test_new_rejects_a_leading_dash_as_an_option() {
    assert_status 1 zenv new -x || return 1
    assert_contains "$OUT" "unknown option"
}

test_new_rejects_two_names() {
    assert_status 1 zenv new a b || return 1
    assert_contains "$OUT" "only one name"
    assert_missing "$ZENV_ROOT/a"
}

# Names that differ only in case are deliberately absent: on a case-insensitive
# filesystem (macOS APFS by default) they are the same directory, which the case
# below pins down separately.
test_new_accepts_reasonable_names() {
    for good in a Beta Z9 dev zeek8 x_y-z.w 9.1.0-dev.75 0; do
        if ! assert_status 0 zenv new "$good"; then
            fail_detail "name that should have been accepted: [$good]"
            continue
        fi
        assert_dir "$ZENV_ROOT/$good/zeek" "prefix for [$good]"
    done
}

# An env name is a directory name, so case sensitivity is the filesystem's call,
# not zenv's. Either outcome is acceptable; silently *sharing* one env between
# two names is not.
test_names_differing_only_in_case_never_silently_share() {
    zenv new dev >/dev/null 2>&1
    printf 'sentinel\n' >"$ZENV_ROOT/dev/zeek/marker"
    if zenv new DEV >/dev/null 2>&1; then
        # Case-sensitive filesystem: two genuinely separate envs.
        assert_missing "$ZENV_ROOT/DEV/zeek/marker" \
            "a second env must not inherit the first one's prefix"
        capture zenv prefix DEV
        assert_ne "$(cd -P "$ZENV_ROOT/dev/zeek" && pwd -P)" "$OUT" \
            "the two prefixes must be different directories"
    else
        # Case-insensitive filesystem: refused, with the reason named.
        assert_status 1 zenv new DEV || return 1
        assert_contains "$OUT" "already exists"
        assert_file "$ZENV_ROOT/dev/zeek/marker" "and the first env is untouched"
    fi
}

test_prefix_rejects_an_invalid_name_before_touching_the_disk() {
    assert_status 1 zenv prefix 'a/../b' || return 1
    assert_contains "$OUT" "invalid environment name"
}

test_a_missing_env_gives_a_clear_error() {
    assert_status 1 zenv prefix nope || return 1
    assert_contains "$OUT" "no such environment: nope"
    assert_contains "$OUT" "zenv list" "point at how to find out what exists"
    assert_contains "$OUT" "zenv new nope" "and at how to create it"
}

# ---------------------------------------------------------------------------
# The active environment as the default argument
# ---------------------------------------------------------------------------

test_prefix_defaults_to_the_active_env() {
    zenv new a >/dev/null 2>&1
    zenv new b >/dev/null 2>&1
    ZENV=b
    export ZENV
    capture zenv prefix
    assert_eq "$ZENV_ROOT/b/zeek" "$OUT"
    capture zenv zkgdir
    assert_eq "$ZENV_ROOT/b/zkg" "$OUT"
    # An explicit name still wins over the active one.
    capture zenv prefix a
    assert_eq "$ZENV_ROOT/a/zeek" "$OUT"
}

test_prefix_without_a_name_or_an_active_env_errors() {
    zenv new a >/dev/null 2>&1
    assert_status 1 zenv prefix || return 1
    assert_contains "$OUT" "none is active"
}

test_a_stale_active_env_errors_rather_than_guessing() {
    ZENV=ghost
    export ZENV
    assert_status 1 zenv prefix || return 1
    assert_contains "$OUT" "no such environment: ghost"
}

# ---------------------------------------------------------------------------
# `zenv list`
# ---------------------------------------------------------------------------

test_list_on_an_empty_root_says_so_and_exits_zero() {
    capture zenv list
    assert_eq 0 $? "an empty root is not an error"
    assert_eq "" "$OUT" "nothing machine-readable to print"
    assert_contains "$ERR" "no environments"
    assert_contains "$ERR" "zenv new"
}

test_list_names_is_machine_readable_and_sorted() {
    for n in beta alpha gamma; do zenv new "$n" >/dev/null 2>&1; done
    capture zenv list --names
    assert_eq "alpha
beta
gamma" "$OUT" "one name per line, sorted, nothing else"
}

test_list_reports_installed_and_version() {
    zenv new a >/dev/null 2>&1
    zenv new b >/dev/null 2>&1
    mkprefix "$ZENV_ROOT/a/zeek" version=9.1.0-dev.42
    capture zenv list
    assert_contains "$OUT" "NAME" "a header row"
    line_a=$(printf '%s\n' "$OUT" | grep '^a ')
    line_b=$(printf '%s\n' "$OUT" | grep '^b ')
    assert_contains "$line_a" "9.1.0-dev.42" "a's version comes from zeek-config"
    assert_contains "$line_a" "yes" "a is installed"
    assert_contains "$line_b" "no" "b is not installed"
}

test_list_marks_the_active_env() {
    zenv new a >/dev/null 2>&1
    zenv new b >/dev/null 2>&1
    ZENV=b
    export ZENV
    capture zenv list
    line_a=$(printf '%s\n' "$OUT" | grep '^a ')
    line_b=$(printf '%s\n' "$OUT" | grep '^b ')
    # ACTIVE is the last column.
    assert_eq "no" "${line_a##* }" "a is not active"
    assert_eq "yes" "${line_b##* }" "b is active"
}

# "config or a stray regular file sitting in the root -- zenv list must skip,
# not crash."
test_list_skips_strays_in_the_root() {
    zenv new a >/dev/null 2>&1
    printf 'zeek_link=%s/zeek\n' "$HOME" >"$ZENV_ROOT/config"
    printf 'junk\n' >"$ZENV_ROOT/loose-file"
    mkdir -p "$ZENV_ROOT/half-made/zeek"
    mkdir -p "$ZENV_ROOT/.hidden"
    ln -s "$SANDBOX" "$ZENV_ROOT/a-symlink"

    capture zenv list
    assert_eq 0 $? "strays must not be fatal"
    capture zenv list --names
    assert_eq "a" "$OUT" "only real envs are listed"
}

test_an_env_dir_without_metadata_is_not_an_env() {
    mkdir -p "$ZENV_ROOT/b/zeek"
    assert_status 1 zenv prefix b || return 1
    assert_contains "$OUT" "no such environment: b"
    assert_contains "$OUT" "$ZENV_ROOT/b/env" "name the file it looked for"
}

test_list_survives_a_zeek_config_that_fails() {
    zenv new a >/dev/null 2>&1
    mkdir -p "$ZENV_ROOT/a/zeek/bin"
    printf '#!/bin/sh\nexit 3\n' >"$ZENV_ROOT/a/zeek/bin/zeek-config"
    chmod +x "$ZENV_ROOT/a/zeek/bin/zeek-config"
    capture zenv list
    assert_eq 0 $? "a broken install must not break list"
    assert_contains "$OUT" "a " "the env is still listed"
}

test_list_rejects_unknown_options() {
    assert_status 1 zenv list --bogus || return 1
    assert_contains "$OUT" "unknown option"
}

test_an_unknown_command_exits_two() {
    assert_status 2 zenv frobnicate || return 1
    assert_contains "$OUT" "unknown command"
    assert_contains "$OUT" "zenv help"
}

test_help_and_version_work_without_a_root() {
    unset ZENV_ROOT
    HOME=/nonexistent-home-for-this-case
    export HOME
    capture zenv version
    assert_eq 0 $? "version must not need a root"
    assert_ne "" "$OUT" "version prints something"
    capture zenv help
    assert_eq 0 $? "help must not need a root"
    assert_contains "$OUT" "never builds Zeek"
}

# ---------------------------------------------------------------------------
# _realpath -- the unit matrix
#
# realpath(1) and `readlink -f` are not portable, so zenv has its own. The
# nonexistent-leaf case is the one that forces a hand-rolled version: `zenv new`
# resolves a prefix before anything exists there.
# ---------------------------------------------------------------------------

RP='_realpath "$1"'
RP_RC='_realpath "$1"; printf "rc=%s\n" "$?"'

test_realpath_resolves_a_plain_directory() {
    mkdir -p "$SANDBOX/plain"
    zenv_lib "$RP" "$SANDBOX/plain"
    assert_eq "$SANDBOX/plain" "$OUT"
}

test_realpath_follows_a_symlink_chain_two_deep() {
    mkdir -p "$SANDBOX/target"
    ln -s "$SANDBOX/target" "$SANDBOX/mid"
    ln -s "$SANDBOX/mid" "$SANDBOX/top"
    zenv_lib "$RP" "$SANDBOX/top"
    assert_eq "$SANDBOX/target" "$OUT" "two hops must both be followed"
}

test_realpath_collapses_dotdot_components() {
    mkdir -p "$SANDBOX/one/two"
    zenv_lib "$RP" "$SANDBOX/one/two/../two"
    assert_eq "$SANDBOX/one/two" "$OUT"
    zenv_lib "$RP" "$SANDBOX/one/../one"
    assert_eq "$SANDBOX/one" "$OUT"
}

test_realpath_strips_trailing_slashes() {
    mkdir -p "$SANDBOX/slash"
    zenv_lib "$RP" "$SANDBOX/slash/"
    assert_eq "$SANDBOX/slash" "$OUT"
    zenv_lib "$RP" "$SANDBOX/slash///"
    assert_eq "$SANDBOX/slash" "$OUT" "several trailing slashes too"
}

test_realpath_handles_a_nonexistent_leaf() {
    mkdir -p "$SANDBOX/exists"
    zenv_lib "$RP" "$SANDBOX/exists/not-yet"
    assert_eq "$SANDBOX/exists/not-yet" "$OUT" "the leaf is kept verbatim"
}

test_realpath_resolves_the_parent_of_a_nonexistent_leaf() {
    mkdir -p "$SANDBOX/target"
    ln -s "$SANDBOX/target" "$SANDBOX/via"
    zenv_lib "$RP" "$SANDBOX/via/not-yet"
    assert_eq "$SANDBOX/target/not-yet" "$OUT" \
        "the existing parent is resolved even though the leaf is missing"
}

test_realpath_fails_when_the_parent_is_missing() {
    zenv_lib "$RP_RC" "$SANDBOX/no/such/parent/leaf"
    assert_contains "$OUT" "rc=1" "an unresolvable path must fail, not guess"
}

test_realpath_handles_slash_and_a_dangling_symlink() {
    zenv_lib "$RP" /
    assert_eq "/" "$OUT" "the root directory"
    ln -s "$SANDBOX/gone" "$SANDBOX/dangling"
    zenv_lib "$RP" "$SANDBOX/dangling"
    assert_eq "$SANDBOX/dangling" "$OUT" "a dangling link keeps its own path"
}

test_realpath_handles_relative_paths_and_metacharacters() {
    mkdir -p "$SANDBOX/rel.d+x[1]"
    zenv_lib 'cd "$1" && _realpath "$2"' "$SANDBOX" 'rel.d+x[1]'
    assert_eq "$SANDBOX/rel.d+x[1]" "$OUT" "relative, with glob metacharacters"
    zenv_lib 'cd "$1" && _realpath "$2"' "$SANDBOX" 'no-such-thing'
    assert_eq "$SANDBOX/no-such-thing" "$OUT" "relative nonexistent leaf"
}

test_realpath_rejects_an_empty_path() {
    zenv_lib "$RP_RC" ''
    assert_eq "rc=1" "$OUT" "empty in, failure out, nothing printed"
}

test_realpath_handles_a_path_with_a_space_and_a_quote() {
    mkdir -p "$SANDBOX/a dir/it's"
    zenv_lib "$RP" "$SANDBOX/a dir/it's/"
    assert_eq "$SANDBOX/a dir/it's" "$OUT"
}

# ---------------------------------------------------------------------------
# key=value parsing -- `config` and `env`
#
# Parsed with a read loop, never `.`/source, so a stray value cannot execute
# code. That is the property the first case here pins down.
# ---------------------------------------------------------------------------

_write_kv() { printf '%s' "$1" >"$SANDBOX/kv"; }

# _kv_get <file> <key>, with the file passed as an argument.
KV_GET='_kv_get "$1" "$2"'
KV_GET_RC='_kv_get "$1" "$2"; printf "|rc=%s\n" "$?"'

test_kv_never_executes_a_value() {
    _write_kv 'prefix=$(touch '"$SANDBOX"'/pwned)
other=`touch '"$SANDBOX"'/pwned2`
'
    zenv_lib "$KV_GET" "$SANDBOX/kv" prefix
    assert_eq '$(touch '"$SANDBOX"'/pwned)' "$OUT" "the value is data, verbatim"
    assert_missing "$SANDBOX/pwned" "command substitution must not run"
    assert_missing "$SANDBOX/pwned2" "backticks must not run either"
}

test_kv_tolerates_the_malformed_matrix() {
    # CRLF, blank lines, a comment, an indented comment, surrounding spaces, an
    # unknown key, a line with no '=', a value containing '=', and a duplicate.
    {
        printf 'name=a\r\n'
        printf '\n'
        printf '# a comment\n'
        printf '   # an indented comment\n'
        printf '  prefix  =   /p/refix  \n'
        printf 'unknown_key=ignored\n'
        printf 'a line with no equals sign\n'
        printf 'weird=/x/y=z\n'
        printf 'zkg_dir=/first\n'
        printf 'zkg_dir=/last\n'
    } >"$SANDBOX/kv"

    zenv_lib "$KV_GET" "$SANDBOX/kv" name
    assert_eq "a" "$OUT" "a CRLF line ending is stripped"
    zenv_lib "$KV_GET" "$SANDBOX/kv" prefix
    assert_eq "/p/refix" "$OUT" "spaces around key and value are trimmed"
    zenv_lib "$KV_GET" "$SANDBOX/kv" weird
    assert_eq "/x/y=z" "$OUT" "only the first '=' separates"
    zenv_lib "$KV_GET" "$SANDBOX/kv" zkg_dir
    assert_eq "/last" "$OUT" "on a duplicate key the last one wins"
    zenv_lib "$KV_GET_RC" "$SANDBOX/kv" '# a comment'
    assert_eq "|rc=1" "$OUT" "a comment is not a key"
}

test_kv_distinguishes_absent_from_empty() {
    _write_kv 'empty=
'
    zenv_lib "$KV_GET_RC" "$SANDBOX/kv" empty
    assert_eq "|rc=0" "$OUT" "a present-but-empty key succeeds with no value"
    zenv_lib "$KV_GET_RC" "$SANDBOX/kv" absent
    assert_eq "|rc=1" "$OUT" "an absent key fails"
    zenv_lib "$KV_GET_RC" "$SANDBOX/nofile" any
    assert_eq "|rc=1" "$OUT" "a missing file fails rather than erroring"
}

test_kv_reads_a_final_line_with_no_newline() {
    printf 'prefix=/no/trailing/newline' >"$SANDBOX/kv"
    zenv_lib "$KV_GET" "$SANDBOX/kv" prefix
    assert_eq "/no/trailing/newline" "$OUT"
}

# The one-line-delta property the INI edits in step D will also need.
test_kv_set_preserves_everything_else() {
    _write_kv '# leading comment
name=a

prefix=/old
zkg_dir=/z
# trailing comment
'
    cp "$SANDBOX/kv" "$SANDBOX/kv.before"
    zenv_lib '_kv_set "$1" prefix /new' "$SANDBOX/kv"
    delta=$(diff "$SANDBOX/kv.before" "$SANDBOX/kv" | grep -c '^[<>]')
    assert_eq 2 "$delta" "exactly one line changed"
    body=$(cat "$SANDBOX/kv")
    assert_contains "$body" "prefix=/new"
    assert_contains "$body" "# leading comment" "comments survive"
    assert_contains "$body" "# trailing comment"
    # Key order must survive too.
    order=$(grep -n '^[a-z_]*=' "$SANDBOX/kv" | sed 's/:.*//' | tr '\n' ' ')
    assert_eq "2 4 5 " "$order" "keys stay on their original lines"
}

test_kv_set_appends_a_missing_key_and_creates_a_missing_file() {
    _write_kv 'name=a
'
    zenv_lib '_kv_set "$1" src /tree' "$SANDBOX/kv"
    assert_contains "$(cat "$SANDBOX/kv")" "src=/tree"
    zenv_lib '_kv_set "$1" name b; cat "$1"' "$SANDBOX/fresh"
    assert_eq "name=b" "$OUT"
}

test_kv_set_leaves_no_temp_file_behind() {
    _write_kv 'name=a
'
    zenv_lib '_kv_set "$1" name b' "$SANDBOX/kv"
    strays=$(find "$SANDBOX" -maxdepth 1 -name 'kv.zenv.*' | wc -l | tr -d ' ')
    assert_eq 0 "$strays" "the rewrite must be atomic, not littered"
}

# ---------------------------------------------------------------------------
# The malformed-`env` matrix, end to end through the commands
# ---------------------------------------------------------------------------

test_a_malformed_env_file_still_drives_the_commands() {
    mkdir -p "$ZENV_ROOT/a"
    {
        printf '# hand-edited\r\n'
        printf '\r\n'
        printf '  name = a \r\n'
        printf 'prefix=%s/a/elsewhere\r\n' "$ZENV_ROOT"
        printf 'stray line\r\n'
        printf 'zkg_dir=/first\r\n'
        printf 'zkg_dir=%s/a/zkgstate\r\n' "$ZENV_ROOT"
    } >"$ZENV_ROOT/a/env"
    mkdir -p "$ZENV_ROOT/a/elsewhere" "$ZENV_ROOT/a/zkgstate"

    capture zenv prefix a
    assert_eq "$ZENV_ROOT/a/elsewhere" "$OUT" "the recorded prefix is honoured"
    capture zenv zkgdir a
    assert_eq "$ZENV_ROOT/a/zkgstate" "$OUT" "last duplicate wins here too"
    capture zenv list --names
    assert_eq "a" "$OUT"
}

# An `env` file missing a key must fall back to the layout default rather than
# yielding an empty path a caller would splice into a command line.
test_a_key_missing_from_env_falls_back_to_the_layout() {
    mkdir -p "$ZENV_ROOT/a/zeek" "$ZENV_ROOT/a/zkg"
    printf 'name=a\n' >"$ZENV_ROOT/a/env"
    capture zenv prefix a
    assert_eq "$ZENV_ROOT/a/zeek" "$OUT"
    capture zenv zkgdir a
    assert_eq "$ZENV_ROOT/a/zkg" "$OUT"
}

test_an_empty_env_file_is_still_an_env() {
    mkdir -p "$ZENV_ROOT/a/zeek" "$ZENV_ROOT/a/zkg"
    : >"$ZENV_ROOT/a/env"
    capture zenv prefix a
    assert_eq "$ZENV_ROOT/a/zeek" "$OUT" "defaults carry a contentless env file"
    capture zenv list --names
    assert_eq "a" "$OUT"
}

# ---------------------------------------------------------------------------
# The `activate` stub
#
# Only its shape is asserted here; what it evaluates to is step C's business.
# ---------------------------------------------------------------------------

test_the_activate_stub_is_syntactically_valid_and_names_its_env() {
    zenv new dev >/dev/null 2>&1
    stub="$ZENV_ROOT/dev/activate"
    assert_file "$stub" || return 1
    assert_status 0 /bin/sh -n "$stub" || return 1
    body=$(cat "$stub")
    assert_contains "$body" "shell activate 'dev'" "it must name its own env"
    assert_contains "$body" "command zenv" \
        "and go through 'command' so the shell function cannot recurse"
}

run_cases

