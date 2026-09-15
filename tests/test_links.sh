#!/bin/sh
# Step E's gate: `link`, `unlink`, `adopt`, `remove` and `exec`.
#
# Covers plan tests 7, 8 and 9, the symlink-swap matrix, and `exec`'s argument
# and exit-code contract.
#
# Two rules shape most of the cases. The symlinks are the only thing zenv puts
# outside its own root, so every case that touches one asserts what happened to
# a path zenv did *not* create as well: a real ~/zeek is never replaced, a
# symlink pointing elsewhere is never removed, and a symlink standing in for an
# environment directory is never followed. And removal is an `rm -rf`, so every
# refusal asserts the target is still there afterwards rather than just that the
# exit status was non-zero.
#
# shellcheck disable=SC2016
#   Single-quoted `$` in this file is shell code for another shell to expand,
#   or the literal text an assertion looks for. Expanding it in this process is
#   the bug these cases exist to catch.

. "$REPO_ROOT/tests/lib.sh"

# ---------------------------------------------------------------------------
# Local helpers
# ---------------------------------------------------------------------------

# An environment with a fake install in it.
mkenv() {
    _men=$1
    shift
    zenv new "$_men" >/dev/null 2>&1 || {
        fail "mkenv: zenv new $_men failed"
        return 1
    }
    mkprefix "$ZENV_ROOT/$_men/zeek" "$@"
}

# The recording zkg stub, where `command -v zkg` finds it.
mkzkg() { mkzkgstub "$SANDBOX/bin/zkg"; }

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

# A zkg state dir in the shape `zenv adopt` will find on this machine: a config
# whose paths name the install, a manifest agreeing with it, and a file zenv has
# no business touching.
mkzkgstate() {
    _zsd=$1
    _zspfx=$2
    mkdir -p "$_zsd/clones/package"
    {
        printf '# zkg configuration file\n'
        printf '[sources]\n'
        printf 'zeek = https://github.com/zeek/packages\n'
        printf '\n'
        printf '[paths]\n'
        printf 'state_dir = %s\n' "$_zsd"
        printf 'script_dir = %s/share/zeek/site\n' "$_zspfx"
        printf 'plugin_dir = %s/lib/zeek/plugins\n' "$_zspfx"
        printf 'bin_dir = %s/bin\n' "$_zspfx"
        printf 'zeek_dist = \n'
        printf '\n'
        printf '[templates]\n'
        printf 'default = https://github.com/zeek/package-template\n'
    } >"$_zsd/config"
    mkmanifest "$_zsd/manifest.json" \
        "$_zspfx/share/zeek/site/packages" \
        "$_zspfx/lib/zeek/plugins/packages" \
        "$_zspfx/bin"
    printf 'do not touch me\n' >"$_zsd/clones/package/sentinel"
}

# One key out of an env's zkg config.
cfg_get() { zenv_lib 'printf "%s" "$(_ini_get "$1" "$2")"' "$1" "$2"; }

# One key out of the root's config file.
root_cfg() { zenv_lib 'printf "%s" "$(_kv_get "$1" "$2")"' "$ZENV_ROOT/config" "$1"; }

# A command that prints its arguments unambiguously, one bracketed line each.
mkargprint() {
    {
        printf '#!/bin/sh\n'
        printf 'for a in "$@"; do printf "[%%s]\\n" "$a"; done\n'
    } >"$SANDBOX/bin/argprint"
    chmod +x "$SANDBOX/bin/argprint"
}

# Stubs for every build tool, so "zenv never builds Zeek" keeps being asserted
# by behaviour rather than by grepping for words the output legitimately uses.
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

# The LINKED and ACTIVE columns of `zenv list` for one environment.
list_col() { printf '%s\n' "$1" | awk -v n="$2" -v c="$3" '$1 == n { print $c }'; }

# ---------------------------------------------------------------------------
# Plan test 7 -- link and unlink
# ---------------------------------------------------------------------------

test_link_creates_two_relative_symlinks() {
    mkenv a
    capture zenv link a || fail "link should succeed"
    assert_symlink_to "$HOME/zeek" "zenv/a/zeek" "the compatibility prefix link"
    assert_symlink_to "$HOME/.zkg" "zenv/a/zkg" "the compatibility state link"
    # Relative, so moving $HOME does not break them -- and readlink shows that.
    assert_not_contains "$(readlink "$HOME/zeek")" "$HOME" "the target stays relative"
    assert_eq "" "$OUT" "link writes nothing to stdout"
}

test_link_records_where_it_put_them() {
    mkenv a
    zenv link a >/dev/null 2>&1 || fail "link should succeed"
    # The keys are what `zenv uninstall` will use to find them again.
    root_cfg zeek_link
    assert_eq "$HOME/zeek" "$OUT" "zeek_link"
    root_cfg zkg_link
    assert_eq "$HOME/.zkg" "$OUT" "zkg_link"
}

test_link_refuses_a_real_zeek_directory_and_names_adopt() {
    mkenv a
    mkdir -p "$HOME/zeek/bin"
    printf 'mine\n' >"$HOME/zeek/sentinel"

    capture zenv link a && fail "link must refuse a real directory"
    assert_contains "$ERR" 'real directory' "says what is in the way"
    assert_contains "$ERR" 'zenv adopt' "and names the command that handles it"
    assert_file "$HOME/zeek/sentinel" "the real directory is untouched"
    assert_missing "$HOME/.zkg" "and the second link was never made"
}

test_link_checks_both_paths_before_swapping_either() {
    mkenv a
    # Only the *second* path is in the way. Nothing may be swapped.
    mkdir -p "$HOME/.zkg"
    printf 'mine\n' >"$HOME/.zkg/sentinel"

    capture zenv link a && fail "link must refuse"
    assert_contains "$ERR" 'real directory'
    assert_missing "$HOME/zeek" "the first link must not be left behind"
    assert_file "$HOME/.zkg/sentinel"
}

test_link_refuses_a_path_that_is_not_a_directory() {
    mkenv a
    printf 'a file\n' >"$HOME/zeek"

    capture zenv link a && fail "link must refuse a regular file"
    assert_contains "$ERR" 'neither a directory nor a symlink'
    assert_eq "a file" "$(cat "$HOME/zeek")" "the file is untouched"
}

test_link_swaps_from_one_env_to_another() {
    mkenv a
    mkenv b
    zenv link a >/dev/null 2>&1
    capture zenv link b || fail "relinking should succeed"
    assert_symlink_to "$HOME/zeek" "zenv/b/zeek"
    assert_symlink_to "$HOME/.zkg" "zenv/b/zkg"
    assert_dir "$ZENV_ROOT/a/zeek" "the env it used to point at is untouched"
}

test_link_is_idempotent() {
    mkenv a
    zenv link a >/dev/null 2>&1
    capture zenv link a || fail "linking twice should succeed"
    assert_symlink_to "$HOME/zeek" "zenv/a/zeek"
    assert_symlink_to "$HOME/.zkg" "zenv/a/zkg"
}

test_link_replaces_a_dangling_symlink() {
    mkenv a
    mkenv b
    zenv link a >/dev/null 2>&1
    # The env the links point at goes away underneath them.
    rm -rf "$ZENV_ROOT/a"
    assert_symlink "$HOME/zeek" "still a symlink, now dangling"

    capture zenv link b || fail "a dangling link is not an obstacle"
    assert_symlink_to "$HOME/zeek" "zenv/b/zeek"
}

test_link_replaces_a_symlink_to_a_path_outside_the_root() {
    mkenv a
    mkdir -p "$SANDBOX/elsewhere"
    ln -s "$SANDBOX/elsewhere" "$HOME/zeek"

    # Replacing a symlink loses nothing, so this is allowed -- unlike *removing*
    # one, which `unlink` refuses for exactly this case.
    capture zenv link a || fail "link should succeed"
    assert_symlink_to "$HOME/zeek" "zenv/a/zeek"
    assert_dir "$SANDBOX/elsewhere" "the directory it pointed at is untouched"
}

test_link_warns_when_the_env_has_nothing_installed() {
    zenv new a >/dev/null 2>&1
    capture zenv link a || fail "link should still succeed"
    assert_contains "$ERR" 'nothing installed' "the warning"
    assert_symlink "$HOME/zeek" "and the links are made anyway"
}

test_link_defaults_to_the_active_env() {
    mkenv a
    ZENV=a capture zenv link || fail "link with no name should use \$ZENV"
    assert_symlink_to "$HOME/zeek" "zenv/a/zeek"
}

test_link_refuses_an_unknown_env() {
    capture zenv link nope && fail "link must refuse an unknown name"
    assert_contains "$ERR" 'no such environment'
    assert_missing "$HOME/zeek"
}

test_link_rejects_a_second_name_and_unknown_options() {
    mkenv a
    mkenv b
    capture zenv link a b && fail "two names is an error"
    assert_contains "$ERR" 'only one name'
    capture zenv link --wat a && fail "an unknown option is an error"
    assert_contains "$ERR" "unknown option '--wat'"
    assert_missing "$HOME/zeek"
}

test_unlink_removes_both_and_leaves_the_envs_alone() {
    mkenv a
    printf 'installed\n' >"$ZENV_ROOT/a/zeek/share/zeek/site/marker"
    zenv link a >/dev/null 2>&1

    capture zenv unlink || fail "unlink should succeed"
    assert_missing "$HOME/zeek"
    assert_missing "$HOME/.zkg"
    assert_file "$ZENV_ROOT/a/zeek/share/zeek/site/marker" "the install is untouched"
    assert_dir "$ZENV_ROOT/a/zkg" "and so is the state dir"
    assert_file "$ZENV_ROOT/a/env" "and the metadata"
}

test_unlink_leaves_a_symlink_it_did_not_create() {
    mkdir -p "$SANDBOX/elsewhere"
    ln -s "$SANDBOX/elsewhere" "$HOME/zeek"

    capture zenv unlink || fail "unlink should succeed"
    assert_symlink "$HOME/zeek" "a symlink pointing outside the root stays"
    assert_contains "$ERR" 'points outside'
    assert_contains "$ERR" 'zenv did not create it'
}

test_unlink_leaves_a_real_directory_alone() {
    mkdir -p "$HOME/zeek"
    printf 'mine\n' >"$HOME/zeek/sentinel"

    capture zenv unlink || fail "unlink should succeed"
    assert_file "$HOME/zeek/sentinel"
    assert_contains "$ERR" 'real directory'
}

test_unlink_with_nothing_linked_is_clean() {
    capture zenv unlink || fail "unlink with nothing to do should exit 0"
    assert_contains "$ERR" 'nothing there'
}

test_unlink_removes_a_dangling_link_of_its_own() {
    mkenv a
    zenv link a >/dev/null 2>&1
    rm -rf "$ZENV_ROOT/a"

    # The link text still names the root, which is how zenv knows it is its own
    # even though the destination is gone.
    capture zenv unlink || fail "unlink should succeed"
    assert_missing "$HOME/zeek"
    assert_missing "$HOME/.zkg"
}

test_unlink_rejects_an_argument() {
    capture zenv unlink a && fail "unlink takes no arguments"
    assert_contains "$ERR" 'unexpected argument'
}

test_list_shows_which_env_is_linked() {
    mkenv a
    mkenv b
    zenv link b >/dev/null 2>&1
    capture zenv list || fail "list should succeed"
    assert_eq no "$(list_col "$OUT" a 5)" "a is not linked"
    assert_eq yes "$(list_col "$OUT" b 5)" "b is"
}

# ---------------------------------------------------------------------------
# The symlink swap: the path is never missing, not even for an instant
# ---------------------------------------------------------------------------

test_the_swap_never_leaves_the_path_missing() {
    mkenv a
    mkenv b
    zenv link a >/dev/null 2>&1

    misses=$SANDBOX/misses
    : >"$misses"
    (
        while [ ! -f "$SANDBOX/watch.done" ]; do
            [ -L "$HOME/zeek" ] || printf 'missing\n' >>"$misses"
        done
    ) &
    watcher=$!

    i=0
    while [ "$i" -lt 12 ]; do
        zenv link b >/dev/null 2>&1
        zenv link a >/dev/null 2>&1
        i=$((i + 1))
    done

    : >"$SANDBOX/watch.done"
    wait "$watcher" 2>/dev/null || true

    n=$(wc -l <"$misses" | tr -d ' ')
    assert_eq 0 "$n" "the path must be a symlink at every instant during a swap"
    assert_symlink_to "$HOME/zeek" "zenv/a/zeek" "and it ends up where it should"
}

test_the_swap_leaves_no_temporary_behind() {
    # The whole sandbox, not just $HOME: `mv` onto a symlink-to-a-directory
    # follows it by default, so a botched swap hides its temporary *inside* the
    # env it was pointing at rather than beside the link.
    mkenv a
    mkenv b
    zenv link a >/dev/null 2>&1
    zenv link b >/dev/null 2>&1
    zenv link a >/dev/null 2>&1
    stray=$(find "$SANDBOX" -name '*.zenv-link.*' | wc -l | tr -d ' ')
    assert_eq 0 "$stray" "no .zenv-link.PID files may survive anywhere"
    assert_symlink_to "$HOME/zeek" zenv/a/zeek "and the last link won"
}

# ---------------------------------------------------------------------------
# Plan test 8 -- adopt --move
# ---------------------------------------------------------------------------

test_adopt_move_relocates_both_trees_and_symlinks_them() {
    mkprefix "$HOME/zeek"
    mkzkgstate "$HOME/.zkg" "$HOME/zeek"
    printf 'installed\n' >"$HOME/zeek/share/zeek/site/marker"

    capture zenv adopt default || fail "adopt should succeed"
    assert_eq "$ZENV_ROOT/default/zeek" "$OUT" "stdout is the new prefix"

    assert_file "$ZENV_ROOT/default/zeek/bin/zeek-config" "the install moved"
    assert_file "$ZENV_ROOT/default/zeek/share/zeek/site/marker" "with its contents"
    assert_file "$ZENV_ROOT/default/zkg/config" "the state dir moved"
    assert_file "$ZENV_ROOT/default/zkg/clones/package/sentinel" "with its contents"
    assert_file "$ZENV_ROOT/default/env" "the metadata was written"
    assert_file "$ZENV_ROOT/default/activate" "and the activation stub"

    assert_symlink_to "$HOME/zeek" "zenv/default/zeek" "the old path still resolves"
    assert_symlink_to "$HOME/.zkg" "zenv/default/zkg"
}

test_adopt_move_rewrites_state_dir_and_nothing_else() {
    mkprefix "$HOME/zeek"
    mkzkgstate "$HOME/.zkg" "$HOME/zeek"
    cp "$HOME/.zkg/config" "$SANDBOX/before"

    zenv adopt default >/dev/null 2>&1 || fail "adopt should succeed"

    cfg=$ZENV_ROOT/default/zkg/config
    cfg_get "$cfg" state_dir
    assert_eq "$ZENV_ROOT/default/zkg" "$OUT" "state_dir now names the env"

    # script_dir, plugin_dir and bin_dir must keep naming the *old* path: they
    # resolve through the symlink to the same directories the manifest names,
    # which is what keeps the next zkg invocation from relocating anything.
    cfg_get "$cfg" script_dir
    assert_eq "$HOME/zeek/share/zeek/site" "$OUT" "script_dir is left alone"

    d=$(diff "$SANDBOX/before" "$cfg" | grep -c '^[<>]')
    assert_eq 2 "$d" "exactly one line changed"
}

test_an_adopted_and_moved_env_passes_the_autoconfig_gate() {
    # The point of the symlink, and of finding 6's realpath comparison: the
    # install's baked paths name ~/zeek, the manifest names ~/zeek, and both
    # resolve into the env -- so nothing looks like a relocation and zkg is
    # allowed to run.
    mkzkg
    mkprefix "$HOME/zeek"
    mkzkgstate "$HOME/.zkg" "$HOME/zeek"
    zenv adopt default >/dev/null 2>&1 || fail "adopt should succeed"

    capture zenv autoconfig default || {
        fail "autoconfig must not refuse an adopted-and-moved env"
        fail_detail "$ERR"
    }
    assert_eq 1 "$(zkg_invocations)" "zkg ran exactly once"
    assert_not_contains "$ERR" 'fix-paths' "and no repair was demanded"
}

test_adopt_move_with_no_zkg_state_creates_an_empty_one() {
    mkprefix "$HOME/zeek"

    capture zenv adopt default || fail "adopt should succeed"
    assert_dir "$ZENV_ROOT/default/zkg" "an empty state dir, as zenv new leaves"
    assert_missing "$ZENV_ROOT/default/zkg/config"
    # Nothing was there, so there is nothing to keep working.
    assert_missing "$HOME/.zkg" "no symlink is invented for a path that never existed"
    assert_symlink "$HOME/zeek" "the prefix link is still made"
}

test_adopt_move_names_the_symlink_as_mandatory() {
    mkprefix "$HOME/zeek"
    capture zenv adopt default || fail "adopt should succeed"
    assert_contains "$ERR" 'Keep those symlinks' "the caveat is stated"
    assert_contains "$ERR" 'resolves *through* the symlink'
    assert_contains "$ERR" 'zenv prefix default' "and the way out is named"
}

test_adopt_move_refuses_a_symlink() {
    mkprefix "$SANDBOX/opt/zeek"
    ln -s "$SANDBOX/opt/zeek" "$HOME/zeek"

    capture zenv adopt default && fail "there is nothing to move"
    assert_contains "$ERR" 'is a symlink'
    assert_symlink "$HOME/zeek" "the symlink is untouched"
    assert_missing "$ZENV_ROOT/default" "and no half-made env is left behind"
}

test_adopt_move_works_for_a_tree_elsewhere() {
    mkprefix "$SANDBOX/opt/zeek"
    capture zenv adopt other --from "$SANDBOX/opt/zeek" --move \
        || fail "adopt --move should succeed"
    assert_file "$ZENV_ROOT/other/zeek/bin/zeek-config" "the tree moved"
    assert_symlink "$SANDBOX/opt/zeek" "and its old path is now a symlink"
    assert_missing "$HOME/zeek" "the system default is not touched"
}

# ---------------------------------------------------------------------------
# adopt --link
# ---------------------------------------------------------------------------

test_adopt_defaults_to_link_for_a_tree_elsewhere() {
    mkprefix "$SANDBOX/opt/zeek"
    capture zenv adopt other --from "$SANDBOX/opt/zeek" || fail "adopt should succeed"

    assert_symlink_to "$ZENV_ROOT/other/zeek" "$SANDBOX/opt/zeek" "the prefix points at it"
    assert_dir "$ZENV_ROOT/other/zkg" "and gets its own state dir"
    assert_missing "$ZENV_ROOT/other/zkg/config"
    assert_file "$ZENV_ROOT/other/env"
    assert_missing "$HOME/zeek" "no compatibility symlink is made"
    assert_missing "$HOME/.zkg" "and ~/.zkg is not adopted behind your back"
}

test_prefix_of_a_linked_env_resolves_to_the_install() {
    mkprefix "$SANDBOX/opt/zeek"
    zenv adopt other --from "$SANDBOX/opt/zeek" >/dev/null 2>&1
    capture zenv prefix other || fail "prefix should succeed"
    assert_eq "$SANDBOX/opt/zeek" "$OUT" "one real path per env, finding 1"
}

test_adopt_link_shares_an_explicit_zkg_dir_and_says_so() {
    mkprefix "$SANDBOX/opt/zeek"
    mkzkgstate "$SANDBOX/state" "$SANDBOX/opt/zeek"

    capture zenv adopt other --from "$SANDBOX/opt/zeek" --zkg "$SANDBOX/state" \
        || fail "adopt should succeed"
    assert_symlink_to "$ZENV_ROOT/other/zkg" "$SANDBOX/state"
    assert_contains "$ERR" 'shared with' "sharing a state dir is called out"
    assert_file "$SANDBOX/state/clones/package/sentinel" "and nothing was moved"
}

test_adopt_link_refuses_a_missing_zkg_dir() {
    mkprefix "$SANDBOX/opt/zeek"
    capture zenv adopt other --from "$SANDBOX/opt/zeek" --zkg "$SANDBOX/nope" \
        && fail "adopt must refuse a --zkg that is not there"
    assert_contains "$ERR" 'no directory at'
}

# ---------------------------------------------------------------------------
# adopt: refusals and argument handling
# ---------------------------------------------------------------------------

test_adopt_refuses_an_existing_env_name() {
    mkenv a
    mkprefix "$HOME/zeek"
    capture zenv adopt a && fail "adopt must not overwrite an env"
    assert_contains "$ERR" "already exists"
    assert_dir "$HOME/zeek" "and nothing was moved"
}

test_adopt_refuses_a_path_inside_the_root() {
    mkenv a
    capture zenv adopt b --from "$ZENV_ROOT/a/zeek" \
        && fail "adopt must refuse a path already inside the root"
    assert_contains "$ERR" 'already inside'
    assert_dir "$ZENV_ROOT/a/zeek" "the env is untouched"
    assert_missing "$ZENV_ROOT/b"
}

test_adopt_refuses_a_missing_directory() {
    capture zenv adopt default && fail "adopt must refuse a missing install"
    assert_contains "$ERR" 'no directory at'
    assert_contains "$ERR" '--from'
    assert_missing "$ZENV_ROOT/default"
}

test_adopt_requires_absolute_paths() {
    capture zenv adopt default --from relative/path \
        && fail "adopt must refuse a relative path"
    assert_contains "$ERR" 'must be absolute'
}

test_adopt_warns_when_it_does_not_look_like_an_install() {
    mkdir -p "$HOME/zeek"
    capture zenv adopt default || fail "adopt should still succeed"
    assert_contains "$ERR" 'does not look like a Zeek install'
    assert_dir "$ZENV_ROOT/default/zeek" "it is adopted anyway"
}

test_adopt_validates_the_name() {
    mkprefix "$HOME/zeek"
    capture zenv adopt config && fail "'config' is reserved"
    assert_contains "$ERR" 'reserved'
    capture zenv adopt 'a/b' && fail "a name may not contain a slash"
    assert_contains "$ERR" 'invalid environment name'
    capture zenv adopt && fail "a name is required"
    assert_contains "$ERR" 'name is required'
    assert_dir "$HOME/zeek" "nothing was moved by any of that"
}

test_adopt_rejects_contradictory_and_unknown_options() {
    mkprefix "$HOME/zeek"
    capture zenv adopt default --move --link && fail "--move and --link conflict"
    assert_contains "$ERR" 'opposites'
    capture zenv adopt default --wat && fail "unknown option"
    assert_contains "$ERR" "unknown option '--wat'"
    capture zenv adopt default --from && fail "--from needs a value"
    assert_contains "$ERR" 'needs a directory'
    capture zenv adopt a b && fail "two names"
    assert_contains "$ERR" 'only one name'
}

test_an_adopted_env_activates_like_any_other() {
    mkprefix "$HOME/zeek" version=9.1.0-dev.75
    zenv adopt default >/dev/null 2>&1 || fail "adopt should succeed"

    capture zenv list || fail "list should succeed"
    assert_contains "$OUT" '9.1.0-dev.75' "the version is read through the symlink"
    assert_eq yes "$(list_col "$OUT" default 3)" "and it counts as installed"

    probe /bin/sh 'eval "$("$ZENV_BIN" shell activate default 2>/dev/null)"'
    assert_eq default "$(probe_var ZENV)"
    assert_eq "$ZENV_ROOT/default/zeek" "$(probe_var ZENV_PREFIX)"
}

# ---------------------------------------------------------------------------
# Plan test 9 -- remove
# ---------------------------------------------------------------------------

test_remove_deletes_the_whole_env_dir() {
    mkenv a
    mkenv b
    capture zenv remove a --yes || fail "remove should succeed"
    assert_missing "$ZENV_ROOT/a"
    assert_dir "$ZENV_ROOT/b" "the other env is untouched"
    capture zenv list --names
    assert_eq b "$OUT" "and it is gone from the list"
}

test_remove_accepts_the_rm_alias() {
    mkenv a
    capture zenv rm a --yes || fail "rm should be remove"
    assert_missing "$ZENV_ROOT/a"
}

test_remove_refuses_a_linked_env() {
    mkenv a
    zenv link a >/dev/null 2>&1

    capture zenv remove a --yes && fail "remove must refuse the system default"
    assert_contains "$ERR" 'system default'
    assert_contains "$ERR" 'zenv unlink'
    assert_contains "$ERR" '--force'
    assert_dir "$ZENV_ROOT/a" "and the env is still there"
}

test_remove_force_removes_a_linked_env_and_warns() {
    mkenv a
    zenv link a >/dev/null 2>&1

    capture zenv remove a --yes --force || fail "--force should succeed"
    assert_missing "$ZENV_ROOT/a"
    assert_contains "$ERR" 'dangle' "the consequence is stated"
    assert_symlink "$HOME/zeek" "the symlink is left, dangling, for unlink to clear"
}

test_remove_refuses_an_active_env() {
    mkenv a
    ZENV=a capture zenv remove a --yes && fail "remove must refuse an active env"
    assert_contains "$ERR" 'active in this shell'
    assert_contains "$ERR" 'zenv deactivate'
    assert_dir "$ZENV_ROOT/a"

    ZENV=a capture zenv remove a --yes --force || fail "--force should succeed"
    assert_missing "$ZENV_ROOT/a"
}

test_remove_never_follows_a_symlink_out_of_the_root() {
    # Plan test 9's sharpest case: the env dir is a symlink to a scratch tree
    # outside the root, and `rm -rf` on it would delete somebody else's files.
    mkdir -p "$SANDBOX/scratch" "$ZENV_ROOT"
    printf 'precious\n' >"$SANDBOX/scratch/keep"
    printf 'name=c\nprefix=%s/scratch/zeek\n' "$SANDBOX" >"$SANDBOX/scratch/env"
    ln -s "$SANDBOX/scratch" "$ZENV_ROOT/c"

    capture zenv remove c --yes && fail "remove must refuse a symlinked env dir"
    assert_contains "$ERR" 'is a symlink'
    assert_file "$SANDBOX/scratch/keep" "the scratch tree is intact"
    assert_symlink "$ZENV_ROOT/c" "and the symlink itself is left for you to remove"
}

test_remove_without_yes_refuses_when_stdin_is_not_a_terminal() {
    mkenv a
    # Deliberately not interactive: an unattended `zenv remove` must never
    # delete on a prompt nobody could answer.
    OUT=$(zenv remove a 2>&1 </dev/null) && fail "remove must not proceed"
    assert_contains "$OUT" 'not a terminal'
    assert_contains "$OUT" '--yes'
    assert_dir "$ZENV_ROOT/a"
}

test_remove_keep_zkg_keeps_the_state_dir() {
    mkenv a
    printf 'pkgs\n' >"$ZENV_ROOT/a/zkg/manifest.json"

    capture zenv remove a --keep-zkg --yes || fail "remove should succeed"
    assert_dir "$ZENV_ROOT/a/zkg" "the state dir survives"
    assert_file "$ZENV_ROOT/a/zkg/manifest.json" "with its contents"
    assert_missing "$ZENV_ROOT/a/zeek" "the install is gone"
    assert_missing "$ZENV_ROOT/a/env" "and so is the metadata"
    assert_contains "$ERR" "$ZENV_ROOT/a/zkg" "the path that survived is named"

    # No metadata means it is no longer an environment.
    capture zenv list --names
    assert_eq "" "$OUT" "and zenv no longer lists it"
}

test_remove_reports_an_install_it_only_pointed_at() {
    mkprefix "$SANDBOX/opt/zeek"
    zenv adopt other --from "$SANDBOX/opt/zeek" >/dev/null 2>&1

    capture zenv remove other --yes || fail "remove should succeed"
    assert_missing "$ZENV_ROOT/other"
    assert_file "$SANDBOX/opt/zeek/bin/zeek-config" "the install is untouched"
    assert_contains "$ERR" 'was not touched' "and removal is not ambiguous about it"
}

test_remove_refuses_an_unknown_env_and_bad_options() {
    mkenv a
    capture zenv remove nope --yes && fail "unknown env"
    assert_contains "$ERR" 'no such environment'
    capture zenv remove a b --yes && fail "two names"
    assert_contains "$ERR" 'only one name'
    capture zenv remove --wat a && fail "unknown option"
    assert_contains "$ERR" "unknown option '--wat'"
    capture zenv remove --yes && fail "no name"
    assert_contains "$ERR" 'name is required'
    assert_dir "$ZENV_ROOT/a" "and the env survived all of that"
}

# ---------------------------------------------------------------------------
# exec
# ---------------------------------------------------------------------------

test_exec_runs_a_command_in_the_env() {
    mkenv a
    capture zenv exec --no-autoconfig a -- /bin/sh -c 'printf "%s|%s" "$ZENV" "$ZENV_PREFIX"' \
        || fail "exec should succeed"
    assert_eq "a|$ZENV_ROOT/a/zeek" "$OUT"
}

test_exec_puts_the_env_bin_first_on_path() {
    mkenv a
    capture zenv exec --no-autoconfig a -- /bin/sh -c 'command -v zeek-config' \
        || fail "exec should succeed"
    assert_eq "$ZENV_ROOT/a/zeek/bin/zeek-config" "$OUT"
}

test_exec_propagates_the_exit_code() {
    mkenv a
    zenv exec --no-autoconfig a -- /bin/sh -c 'exit 7' 2>/dev/null
    assert_eq 7 "$?" "the child's status is exec's status"
    zenv exec --no-autoconfig a -- /bin/sh -c 'exit 0' 2>/dev/null
    assert_eq 0 "$?" "including success"
}

test_exec_reports_a_command_that_cannot_be_run() {
    mkenv a
    zenv exec --no-autoconfig a -- no-such-command-xyz 2>/dev/null
    assert_eq 127 "$?" "127, the shell's own not-found status"
}

test_exec_forwards_arguments_intact() {
    mkenv a
    mkargprint
    capture zenv exec --no-autoconfig a -- argprint 'two words' '' "it's" -x --flag -- last \
        || fail "exec should succeed"
    expected='[two words]
[]
[it'\''s]
[-x]
[--flag]
[--]
[last]'
    assert_eq "$expected" "$OUT" "every argument survives, separators included"
}

test_exec_takes_a_command_with_or_without_the_separator() {
    mkenv a
    mkargprint
    capture zenv exec --no-autoconfig a -- argprint -x || fail "no separator"
    assert_eq '[-x]' "$OUT" "a flag after the command name is the command's"
    capture zenv exec --no-autoconfig -- a argprint -x || fail "separator before the name"
    assert_eq '[-x]' "$OUT"
}

test_exec_never_steals_a_flag_from_the_command() {
    mkenv a
    mkargprint
    # zenv's own options are only recognised *before* the name. After it,
    # --no-autoconfig is the command's argument and nothing else -- the rule that
    # makes `zenv exec a -- zkg --user list` mean what it says.
    capture zenv exec --no-autoconfig a -- argprint --no-autoconfig --fix-paths \
        || fail "exec should succeed"
    assert_eq '[--no-autoconfig]
[--fix-paths]' "$OUT"
}

test_exec_writes_only_the_commands_output_to_stdout() {
    # The autoconfig chatter is exactly the kind of thing that would corrupt
    # `x=$(zenv exec a -- something)`, so it has to be on stderr.
    mkzkg
    mkenv a
    capture zenv exec a /bin/sh -c 'printf hello' || fail "exec should succeed"
    assert_eq hello "$OUT" "stdout is the command's and nothing else"
    assert_eq 1 "$(zkg_invocations)" "and zkg really did run"
}

test_exec_wires_zkg_once_and_no_autoconfig_skips_it() {
    mkzkg
    mkenv a
    zenv exec a /bin/sh -c 'exit 0' 2>/dev/null || fail "exec should succeed"
    assert_eq 1 "$(zkg_invocations)" "the missing config is wired up"
    zenv exec a /bin/sh -c 'exit 0' 2>/dev/null || fail "exec should succeed"
    assert_eq 1 "$(zkg_invocations)" "and not wired again"

    rm -f "$ZENV_ROOT/a/zkg/config"
    zenv exec --no-autoconfig a -- /bin/sh -c 'exit 0' 2>/dev/null || fail "exec should succeed"
    assert_eq 1 "$(zkg_invocations)" "--no-autoconfig leaves it alone"
}

test_exec_does_not_leak_its_prompt_suppression() {
    mkenv a
    capture zenv exec --no-autoconfig a -- /bin/sh -c \
        'printf "%s" "${ZENV_DISABLE_PROMPT-<unset>}"' || fail "exec should succeed"
    assert_eq '<unset>' "$OUT" "the child sees no variable zenv invented"
}

test_exec_reports_its_own_argument_errors() {
    mkenv a
    capture zenv exec && fail "a name is required"
    assert_contains "$ERR" 'expected an environment name'
    capture zenv exec a && fail "a command is required"
    assert_contains "$ERR" 'expected a command to run'
    capture zenv exec a -- && fail "an empty command is required to fail too"
    assert_contains "$ERR" 'expected a command to run'
    capture zenv exec --wat a -- true && fail "unknown option"
    assert_contains "$ERR" "unknown option '--wat'"
    capture zenv exec nope -- true && fail "unknown env"
    assert_contains "$ERR" 'no such environment'
}

test_exec_leaves_the_calling_shell_alone() {
    mkenv a
    # A separate process, so this is nearly free -- but it is the whole reason
    # `exec` exists next to `activate`, so it is asserted rather than assumed.
    zenv exec --no-autoconfig a -- /bin/sh -c 'exit 0' 2>/dev/null
    assert_eq "" "${ZENV:-}" "ZENV is not set in this shell"
    case ":${PATH}:" in
        *":$ZENV_ROOT/a/zeek/bin:"*) fail "PATH must not have been changed" ;;
    esac
}

# ---------------------------------------------------------------------------
# The standing guards
# ---------------------------------------------------------------------------

test_no_link_adopt_remove_or_exec_command_runs_a_build_tool() {
    mkbuildstubs
    mkprefix "$HOME/zeek"
    mkenv a
    zenv link a >/dev/null 2>&1
    zenv unlink >/dev/null 2>&1
    zenv adopt default >/dev/null 2>&1
    zenv exec --no-autoconfig a -- /bin/sh -c 'exit 0' >/dev/null 2>&1
    zenv remove a --yes >/dev/null 2>&1
    zenv help >/dev/null 2>&1
    assert_no_build_tool_ran "no zenv command may run configure/make/cmake"
}

test_help_lists_the_new_commands() {
    capture zenv help || fail "help should succeed"
    assert_contains "$OUT" 'adopt <name>'
    assert_contains "$OUT" 'link <name>'
    assert_contains "$OUT" 'unlink'
    assert_contains "$OUT" 'remove <name>'
    assert_contains "$OUT" 'exec <name>'
}

run_cases
