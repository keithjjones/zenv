#!/bin/sh
# Step G's gate: install.sh, uninstall.sh, `zenv uninstall` and `zenv restore`.
#
# Plan test 13. The central assertion is not an inspection but a hash: snapshot
# the sandbox HOME as a machine looks before zenv, run the whole round trip
# through it, and require the diff to be *empty*. Inspecting a few paths would
# pass while a stray dotfile, an empty directory left by `mkdir -p`, or a
# trailing newline added to an rc file quietly accumulated -- and "leaves no
# trace" is a claim about everything, not about the paths a test remembered.
#
# The round trip is run through all four entry points -- the installed script,
# ./uninstall.sh, `make uninstall`, and once with the repo checkout deleted in
# between -- because they are documented as the same code path and a test is the
# only thing that keeps that true.
#
# A recording zkg stub is on PATH throughout, and every case that finishes
# asserts it was never invoked: constructing zkg's Manager is finding 6's hazard,
# so uninstall and restore must reach their conclusions without one.
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

INSTALL_SH="$REPO_ROOT/install.sh"

# ---------------------------------------------------------------------------
# Local helpers
# ---------------------------------------------------------------------------

# The interpreter running this file, so emitted code is eval'd by the shell the
# case is exercising.
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

# The machine as it is before zenv: a real Zeek install at ~/zeek, a real ~/.zkg
# beside it with an autoconfig'd config, and an rc file with lines of your own.
#
# The config is written as `key = value`, the exact spacing _ini_set writes, so
# that adopt's rewrite of state_dir and restore's revert of it round-trip to the
# same bytes. A fixture written any other way would fail the snapshot for a
# reason that has nothing to do with what uninstall does.
premachine() {
    mkprefix "$HOME/zeek"
    mkdir -p "$HOME/.zkg/clones/source/zeek"
    cat >"$HOME/.zkg/config" <<EOF
[sources]
zeek = https://example.invalid/packages

[paths]
state_dir = $HOME/.zkg
script_dir = $HOME/zeek/share/zeek/site
plugin_dir = $HOME/zeek/lib/zeek/plugins
bin_dir = $HOME/zeek/bin
zeek_dist =

[templates]
default = https://example.invalid/templates
EOF
    cat >"$HOME/.zkg/manifest.json" <<EOF
{"installed_packages": [], "script_dir": "$HOME/zeek/share/zeek/site",
 "plugin_dir": "$HOME/zeek/lib/zeek/plugins", "bin_dir": "$HOME/zeek/bin"}
EOF
    printf 'a clone\n' >"$HOME/.zkg/clones/source/zeek/HEAD"
    printf 'export EDITOR=vi\n# a line of my own\n' >"$HOME/.profile"

    # install.sh picks the rc file from $SHELL; pin it so every case edits the
    # same file whichever shell run.sh is using for this pass.
    SHELL=/bin/sh
    export SHELL

    # Anything that runs zkg has to be caught doing it.
    mkzkgstub "$SANDBOX/bin/zkg"

    T_BIN=$HOME/.local/bin/zenv
    T_BASH=$HOME/.local/share/bash-completion/completions/zenv
    T_ZSH=$HOME/.local/share/zsh/site-functions/_zenv
    T_RC=$HOME/.profile
    ZENV_INSTALLED=$T_BIN
    export ZENV_INSTALLED
}

# One line per path under HOME: its type, and either a hash of its contents or
# the target it stores. Deliberately not mtime -- moving a tree back is allowed
# to change timestamps, but not one byte of content or one entry of the path set.
snap_home() {
    (
        cd "$HOME" || exit 1
        find . | LC_ALL=C sort | while IFS= read -r t_p; do
            if [ -L "$t_p" ]; then
                printf 'l %s -> %s\n' "$t_p" "$(readlink "$t_p")"
            elif [ -d "$t_p" ]; then
                printf 'd %s\n' "$t_p"
            else
                printf 'f %s %s\n' "$t_p" "$(cksum <"$t_p")"
            fi
        done
    )
}

# Count matching lines without grep -c's zero-count exit status deciding
# anything: the number on stdout is the answer either way.
count_lines() { printf '%s\n' "$1" | grep -c "$2" || true; }

# install.sh writes only to stderr; merge so a case can assert on one string.
run_install() { assert_status 0 "$INSTALL_SH" "$@"; }

# The full round trip up to the point of removal: install, adopt ~/zeek as
# 'default' (which moves both trees into the root and leaves the symlinks), and
# leave OUT holding the adopt output.
install_and_adopt() {
    run_install >/dev/null || return 1
    assert_status 0 "$T_BIN" adopt default || return 1
    assert_symlink "$HOME/zeek" "adopt should leave a symlink at ~/zeek" || return 1
    assert_symlink "$HOME/.zkg" "adopt should leave a symlink at ~/.zkg" || return 1
}

# ---------------------------------------------------------------------------
# install.sh: the three paths, the one baked line, the block
# ---------------------------------------------------------------------------

test_install_puts_its_three_files_where_uninstall_looks() {
    premachine
    run_install --no-rc

    assert_file "$T_BIN" "the script should be installed"
    assert_file "$T_BASH" "the bash completion should be installed"
    assert_file "$T_ZSH" "the zsh completion should be installed"
    [ -x "$T_BIN" ] || fail "the installed script should be executable"

    # The agreement that matters: a path install.sh writes but uninstall does not
    # name is a file left on the machine forever.
    assert_status 0 "$T_BIN" uninstall --dry-run
    assert_contains "$OUT" "$T_BIN" "the dry run should name the script"
    assert_contains "$OUT" "$T_BASH" "the dry run should name the bash completion"
    assert_contains "$OUT" "$T_ZSH" "the dry run should name the zsh completion"
    assert_zkg_never_ran
}

test_install_bakes_only_the_one_root_line() {
    premachine
    t_root="$HOME/custom root"
    run_install --no-rc --root "$t_root"

    t_delta=$(diff "$REPO_ROOT/bin/zenv" "$T_BIN" | grep -c '^[<>]' || true)
    assert_eq 2 "$t_delta" "baking the root should change exactly one line"

    # And the value survives a path with a space in it, which is why bake() is a
    # read loop rather than a sed expression. Captured rather than merged: the
    # provenance line is on stderr on purpose, so `cd "$(zenv root)"` works.
    capture env -u ZENV_ROOT "$T_BIN" root || fail "zenv root should succeed"
    assert_eq "$t_root" "$OUT" "the baked root should be what --root asked for"
    assert_contains "$ERR" 'installed default' "and say where it came from"
}

test_a_default_install_is_byte_identical_to_the_repo_script() {
    premachine
    run_install --no-rc
    if ! cmp -s "$REPO_ROOT/bin/zenv" "$T_BIN"; then
        fail "an install with no --root should copy bin/zenv unchanged"
        fail_detail "$(diff "$REPO_ROOT/bin/zenv" "$T_BIN" | head -5)"
    fi
}

test_a_reinstall_keeps_a_baked_root_unless_root_says_otherwise() {
    premachine
    run_install --no-rc --root "$HOME/first"
    run_install --no-rc
    capture env -u ZENV_ROOT "$T_BIN" root || fail "zenv root should succeed"
    assert_eq "$HOME/first" "$OUT" "a reinstall should preserve the baked root"

    run_install --no-rc --root "$HOME/second"
    capture env -u ZENV_ROOT "$T_BIN" root || fail "zenv root should succeed"
    assert_eq "$HOME/second" "$OUT" "--root again should replace it"
}

test_install_and_zenv_agree_on_the_markers_and_the_subdir() {
    # Two files carrying the same three literals is the drift this asserts away:
    # a marker only one of them knows is a block nothing can remove.
    for t_lit in "ZENV_RC_BEGIN='# >>> zenv >>>'" "ZENV_RC_END='# <<< zenv <<<'"; do
        t_in_zenv=$(grep -c "^$t_lit\$" "$REPO_ROOT/bin/zenv" || true)
        t_in_inst=$(grep -c "^RC_${t_lit#ZENV_RC_}\$" "$INSTALL_SH" || true)
        assert_eq 1 "$t_in_zenv" "bin/zenv should define $t_lit once"
        assert_eq 1 "$t_in_inst" "install.sh should define the same literal once"
    done
    t_sub=$(grep -c '^ZENV_INSTALL_SUBDIR=\.local$' "$REPO_ROOT/bin/zenv" || true)
    assert_eq 1 "$t_sub" "bin/zenv should install under .local"
    t_sub=$(grep -c '^SUBDIR=\.local$' "$INSTALL_SH" || true)
    assert_eq 1 "$t_sub" "install.sh should use the same subdirectory"
}

test_the_block_goes_after_your_own_lines_and_the_file_is_backed_up() {
    premachine
    t_before=$(cat "$T_RC")
    run_install
    t_after=$(cat "$T_RC")

    case $t_after in
        "$t_before"*) : ;;
        *) fail "the block should be appended, leaving your own lines first" ;;
    esac
    assert_contains "$t_after" '# >>> zenv >>>' "the start marker should be there"
    assert_contains "$t_after" '# <<< zenv <<<' "the end marker should be there"
    assert_contains "$t_after" 'eval "$(zenv init sh)"' \
        "the block should eval the init for the rc file it went into"
    assert_file "$T_RC.zenv-pre-install" "the pre-zenv file should be kept"
    assert_eq "$t_before" "$(cat "$T_RC.zenv-pre-install")" \
        "the backup should be the file as it was"
}

test_a_second_install_does_not_add_a_second_block() {
    premachine
    run_install
    t_once=$(cat "$T_RC")
    run_install --rc "$HOME/.bashrc"
    assert_eq "$t_once" "$(cat "$T_RC")" "the rc file should not change"
    assert_missing "$HOME/.bashrc" "a second rc file should not get a block"
    assert_contains "$OUT" 'already in' "and install.sh should say why"
}

test_a_reinstall_leaves_one_copy_and_changes_nothing_else() {
    premachine
    run_install >/dev/null || return 1
    t_snap=$(snap_home)

    # Rerunning install.sh is the normal way to pick up a new zenv, so it has to
    # be safe to do on a machine that already has one: every path is overwritten
    # in place rather than added beside, the rc block is not doubled, and the
    # pre-zenv backup is not overwritten with the post-zenv file. A snapshot,
    # not an inspection, because "installs twice" would show up as an extra path
    # anywhere under HOME.
    run_install >/dev/null || return 1
    assert_eq "$t_snap" "$(snap_home)" "a second install should change nothing"

    # And what is left is the script from *this* checkout: a stale copy is
    # replaced, not kept, so the installed zenv is never behind the repo.
    printf '#!/bin/sh\nZENV_ROOT_DEFAULT=""\necho stale\n' >"$T_BIN"
    run_install >/dev/null || return 1
    assert_eq "$t_snap" "$(snap_home)" "and a stale copy should be overwritten"
}

test_a_failed_bake_leaves_no_half_written_script() {
    premachine
    run_install >/dev/null || return 1
    t_snap=$(snap_home)

    # A source with no line to rewrite makes bake give up after it has already
    # opened its temp file. The previous script has to survive whole -- it is
    # moved into place, never written through -- and the temp file has to go
    # with the failure: a stray bin/zenv.zenv-install.NNNN is the one artifact
    # `zenv uninstall` cannot know the name of.
    t_src="$SANDBOX/src"
    mkdir -p "$t_src/bin"
    printf '#!/bin/sh\necho no baked line here\n' >"$t_src/bin/zenv"
    cp "$INSTALL_SH" "$t_src/"
    assert_status 1 "$t_src/install.sh" --no-rc
    assert_contains "$OUT" 'no ZENV_ROOT_DEFAULT' "it should say what was wrong"
    assert_eq "$t_snap" "$(snap_home)" \
        "the installed script should be untouched and no temp file left"
}

test_install_refuses_a_relative_root_and_fish() {
    premachine
    assert_status 1 "$INSTALL_SH" --no-rc --root relative/dir
    assert_contains "$OUT" 'absolute' "a relative --root should be refused"
    assert_missing "$T_BIN" "and nothing should be installed"

    mkdir -p "$HOME/.config/fish"
    : >"$HOME/.config/fish/config.fish"
    assert_status 1 "$INSTALL_SH" --rc "$HOME/.config/fish/config.fish"
    assert_contains "$OUT" 'fish is not supported' \
        "fish should be refused, not given a POSIX block"
}

# ---------------------------------------------------------------------------
# The snapshot assertion, through every entry point
# ---------------------------------------------------------------------------

test_uninstall_leaves_no_trace() {
    premachine
    t_snap=$(snap_home)
    install_and_adopt || return 1

    assert_status 0 "$T_BIN" uninstall --yes
    t_out=$OUT

    # Two files rather than two pipes: `diff` needs two operands, and a snapshot
    # is the one assertion whose failure has to name the offending path.
    printf '%s\n' "$t_snap" >"$SANDBOX/snap.before"
    snap_home >"$SANDBOX/snap.after"
    t_diff=$(diff "$SANDBOX/snap.before" "$SANDBOX/snap.after" || true)
    if [ -n "$t_diff" ]; then
        fail "uninstall left a trace in HOME"
        fail_detail "$t_diff"
        fail_detail "output was: $t_out"
    fi

    # The sub-cases the diff proves, named individually so a failure says which
    # half of the round trip broke rather than only that something did.
    assert_missing "$T_BIN" "the script should be gone"
    assert_missing "$T_BASH" "the bash completion should be gone"
    assert_missing "$T_ZSH" "the zsh completion should be gone"
    assert_missing "$HOME/.local" "and the directories install.sh created with it"
    assert_missing "$ZENV_ROOT" "the root should be gone"
    assert_missing "$T_RC.zenv-pre-install" \
        "a backup identical to the stripped file should be gone too"
    assert_dir "$HOME/zeek" "the ~/zeek tree should be a real directory again"
    assert_dir "$HOME/.zkg" "the ~/.zkg tree should be a real directory again"
    [ -L "$HOME/zeek" ] && fail "the ~/zeek path should not still be a symlink"
    [ -L "$HOME/.zkg" ] && fail "the ~/.zkg path should not still be a symlink"
    assert_contains "$(cat "$HOME/.zkg/config")" "state_dir = $HOME/.zkg" \
        "state_dir should be reverted"
    assert_not_contains "$(cat "$T_RC")" 'zenv' "the rc file should mention no zenv"
    assert_contains "$t_out" 'nothing left' "and it should say so"
    assert_zkg_never_ran
}

test_uninstall_leaves_no_trace_through_uninstall_sh() {
    premachine
    t_snap=$(snap_home)
    install_and_adopt || return 1

    assert_status 0 "$REPO_ROOT/uninstall.sh" --yes
    assert_eq "$t_snap" "$(snap_home)" "./uninstall.sh should leave no trace either"
    assert_zkg_never_ran
}

test_uninstall_leaves_no_trace_through_make() {
    if ! command -v make >/dev/null 2>&1; then
        note 'make is not installed; skipping the make uninstall path'
        return 0
    fi
    premachine
    t_snap=$(snap_home)
    install_and_adopt || return 1

    assert_status 0 make -C "$REPO_ROOT" uninstall ARGS=--yes
    assert_eq "$t_snap" "$(snap_home)" "make uninstall should leave no trace either"
    assert_zkg_never_ran
}

test_uninstall_leaves_no_trace_with_the_repo_gone() {
    premachine
    t_snap=$(snap_home)

    # A checkout that is deleted after installing, which is the whole reason the
    # logic lives in the installed script rather than in uninstall.sh.
    t_repo=$SANDBOX/copied-repo
    mkdir -p "$t_repo"
    cp -R "$REPO_ROOT/bin" "$REPO_ROOT/completions" "$t_repo/"
    cp "$INSTALL_SH" "$REPO_ROOT/uninstall.sh" "$t_repo/"
    assert_status 0 "$t_repo/install.sh"
    assert_status 0 "$T_BIN" adopt default
    rm -rf "$t_repo"
    assert_missing "$t_repo" "the checkout should really be gone"

    assert_status 0 "$T_BIN" uninstall --yes
    assert_eq "$t_snap" "$(snap_home)" \
        "the installed script should be self-sufficient"
    assert_zkg_never_ran
}

test_uninstall_finds_a_baked_root_with_no_zenv_root_in_the_environment() {
    premachine
    # A root with a space in it, inside HOME so the snapshot can see it go.
    t_root="$HOME/custom root"
    t_snap=$(snap_home)

    run_install --root "$t_root"
    # The environment variable is level 1 and would mask the baked default, so
    # this is the only way to exercise level 2 at all.
    unset ZENV_ROOT

    assert_status 0 "$T_BIN" adopt default
    assert_dir "$t_root/default/zeek" "adopt should have used the baked root"

    assert_status 0 "$T_BIN" uninstall --yes
    assert_contains "$OUT" 'installed default' \
        "uninstall should say the root came from the installed script"
    assert_missing "$t_root" "the baked root should be gone"
    assert_eq "$t_snap" "$(snap_home)" "and nothing else should be left"
    assert_zkg_never_ran
}

# ---------------------------------------------------------------------------
# --dry-run
# ---------------------------------------------------------------------------

test_dry_run_changes_nothing_and_names_what_the_real_run_removes() {
    premachine
    install_and_adopt || return 1
    t_snap=$(snap_home)

    assert_status 0 "$T_BIN" uninstall --dry-run
    t_dry=$OUT
    assert_eq "$t_snap" "$(snap_home)" "a dry run must change nothing at all"

    for t_p in "$T_BIN" "$T_BASH" "$T_ZSH" "$T_RC" "$T_RC.zenv-pre-install" \
        "$ZENV_ROOT" "$HOME/zeek" "$HOME/.zkg"; do
        assert_contains "$t_dry" "$t_p" "the dry run should name $t_p"
    done

    assert_status 0 "$T_BIN" uninstall --yes
    t_real=$OUT

    # Every action the real run takes has a `would` line in the dry run. Counted
    # rather than matched line by line, because the two differ only in tense and
    # a count cannot be fooled by a path containing a space or a quote.
    t_nd=$(count_lines "$t_dry" '^  would ')
    t_nr=$(count_lines "$t_real" '^  \(removed\|moved\|reverted\) ')
    assert_eq "$t_nr" "$t_nd" \
        "the dry run should promise exactly as many actions as the real run takes"
    assert_zkg_never_ran
}

# ---------------------------------------------------------------------------
# The cases that must not be clean
# ---------------------------------------------------------------------------

test_an_environment_you_built_is_kept_and_named() {
    premachine
    install_and_adopt || return 1
    assert_status 0 "$T_BIN" new dev
    mkprefix "$ZENV_ROOT/dev/zeek"
    printf 'a binary\n' >"$ZENV_ROOT/dev/zeek/bin/zeek"

    assert_status 0 "$T_BIN" uninstall --yes
    assert_contains "$OUT" 'still on this machine' "it should say what is left"
    assert_contains "$OUT" "rm -rf $ZENV_ROOT/dev" "and print the command to remove it"
    assert_dir "$ZENV_ROOT/dev/zeek" "the install you built should be kept"
    assert_missing "$ZENV_ROOT/dev/env" "but its metadata should go"
    assert_missing "$ZENV_ROOT/dev/activate" "including the activate stub"
    assert_missing "$ZENV_ROOT/config" \
        "and the root's own metadata, even though the root itself has to stay"
    assert_missing "$T_BIN" "the script should still be gone"
    assert_dir "$HOME/zeek" "and the adopted install still restored"
    assert_zkg_never_ran
}

test_purge_deletes_the_environment_you_built() {
    premachine
    t_snap=$(snap_home)
    install_and_adopt || return 1
    assert_status 0 "$T_BIN" new dev
    mkprefix "$ZENV_ROOT/dev/zeek"

    assert_status 0 "$T_BIN" uninstall --yes --purge
    assert_eq "$t_snap" "$(snap_home)" "--purge should leave no trace either"
    assert_zkg_never_ran
}

test_an_unbuilt_environment_and_a_linked_one_leave_nothing_behind() {
    premachine
    install_and_adopt || return 1

    # Never built: two empty directories and zenv's own metadata, all of it
    # zenv's own doing, so none of it is anybody's to keep.
    assert_status 0 "$T_BIN" new empty

    # Adopted with --link: the prefix is a symlink zenv made to an install that
    # already existed somewhere else, so the symlink is zenv's to remove and the
    # install is not zenv's to touch.
    mkprefix "$SANDBOX/elsewhere"
    t_out_snap=$(cd "$SANDBOX/elsewhere" && find . | LC_ALL=C sort)
    assert_status 0 "$T_BIN" adopt other --from "$SANDBOX/elsewhere"
    assert_symlink "$ZENV_ROOT/other/zeek" "adopt --link should leave a symlink"

    assert_status 0 "$T_BIN" uninstall --yes
    assert_contains "$OUT" 'nothing was ever installed in it' \
        "an environment you never built should be named as such"
    assert_contains "$OUT" 'pointed at an install elsewhere' \
        "and a linked one distinguished from it"
    assert_missing "$ZENV_ROOT" \
        "neither should be left as a husk of empty directories keeping the root alive"
    assert_eq "$t_out_snap" "$(cd "$SANDBOX/elsewhere" && find . | LC_ALL=C sort)" \
        "the install the linked environment named must be untouched"
    assert_zkg_never_ran
}

test_a_real_unadopted_zeek_is_left_alone() {
    premachine
    # No adopt at all, so ~/zeek and ~/.zkg stay real directories zenv never
    # touched -- and the round trip is install then uninstall with nothing in
    # between, which is the strictest form of the snapshot assertion: no env was
    # ever created, so the whole of HOME must come back exactly as it was.
    t_snap=$(snap_home)
    run_install

    assert_status 0 "$T_BIN" uninstall --yes
    assert_dir "$HOME/zeek" "a real ~/zeek must not be removed"
    assert_file "$HOME/.zkg/config" "nor anything in a real ~/.zkg"
    assert_contains "$OUT" 'never adopted' "and it should say why it kept them"
    assert_missing "$HOME/.local" "the install should still be gone"
    assert_eq "$t_snap" "$(snap_home)" \
        "installing and uninstalling with no environment should be a no-op"
    assert_zkg_never_ran
}

test_mangled_markers_leave_the_rc_file_untouched() {
    premachine
    run_install
    # A hand-edit inside the block: the markers no longer bracket only zenv's
    # lines, so the block can no longer be removed exactly.
    printf 'export MY_OWN=1\n' >>"$T_RC"
    t_mangled=$(sed '/^# <<< zenv <<</d' "$T_RC")
    printf '%s\n# <<< zenv <<<\n' "$t_mangled" >"$T_RC"
    # The rc file only: uninstall is still expected to take its own three files
    # away, and refusing to touch them because one rc file is unreadable would be
    # a worse answer than removing what it can and naming what it cannot.
    t_rc=$(cksum <"$T_RC")

    assert_status 0 "$T_BIN" uninstall --yes
    assert_eq "$t_rc" "$(cksum <"$T_RC")" \
        "a hand-edited block leaves the whole rc file alone, byte for byte"
    assert_contains "$(cat "$T_RC")" 'MY_OWN' "including the line you added"
    assert_file "$T_RC.zenv-pre-install" \
        "and the backup is kept, since it is now the only pre-zenv copy"
    assert_missing "$T_BIN" "the script itself still goes"
    assert_contains "$OUT" 'left for you to remove' "and says so"
    assert_contains "$OUT" 'did not write' "naming what it found"
}

test_a_backup_that_differs_from_the_file_is_kept() {
    premachine
    run_install
    # A line added after the install: the pre-zenv copy is now genuinely
    # different from the file, so it is the only record of what was there.
    printf 'export ADDED_LATER=1\n' >>"$T_RC"

    assert_status 0 "$T_BIN" uninstall --yes
    assert_file "$T_RC.zenv-pre-install" "a backup that still differs is kept"
    assert_contains "$OUT" 'before zenv' "and explained"
    assert_contains "$(cat "$T_RC")" 'ADDED_LATER' "the file keeps your line"
    assert_not_contains "$(cat "$T_RC")" 'zenv init' "and loses the block"
}

test_an_rc_file_zenv_created_is_removed_with_its_block() {
    premachine
    rm -f "$T_RC"
    t_snap=$(snap_home)

    run_install
    assert_file "$T_RC" "install.sh should create the rc file it needs"
    assert_status 0 "$T_BIN" uninstall --yes
    assert_eq "$t_snap" "$(snap_home)" \
        "an rc file holding nothing but the block should go with it"
}

test_uninstall_without_a_tty_refuses_rather_than_guessing() {
    premachine
    run_install
    t_snap=$(snap_home)

    # No --yes and no terminal: removing things anyway would be the wrong guess.
    assert_status 1 "$T_BIN" uninstall <"$T_RC"
    assert_contains "$OUT" 'not a terminal' "it should say why it stopped"
    assert_eq "$t_snap" "$(snap_home)" "and nothing should have been removed"
}

# ---------------------------------------------------------------------------
# Nothing to undo
#
# Uninstall asked of a machine that has no zenv on it. That is exit 0 with no
# prompt, because ./uninstall.sh is the documented way to undo an install and a
# second run -- or a defensive one in a script or a make target -- must not
# report a failure for a job already done. The refusal above is the opposite
# case: state exists and the answer is genuinely unknown.
#
# The gate on the other side is that "nothing" is a question about *all* of
# zenv's state, not just the script: the last case here removes the script by
# hand and requires the block to still be found.
# ---------------------------------------------------------------------------

test_uninstall_on_a_machine_with_no_zenv_exits_zero_without_prompting() {
    premachine
    t_snap=$(snap_home)

    # Never installed, no --yes, no terminal. The prompt has nothing to ask
    # about, so it is not reached -- a real ~/zeek and ~/.zkg are not zenv's.
    assert_status 0 "$REPO_ROOT/bin/zenv" uninstall </dev/null
    assert_contains "$OUT" 'nothing to undo' "it should say there is nothing to do"
    assert_not_contains "$OUT" 'not a terminal' "and not stop for want of a prompt"
    assert_eq "$t_snap" "$(snap_home)" "the pre-zenv machine should be untouched"
    assert_zkg_never_ran
}

test_a_second_uninstall_is_a_no_op_that_exits_zero() {
    premachine
    t_snap=$(snap_home)
    run_install >/dev/null || return 1

    assert_status 0 "$T_BIN" uninstall --yes || return 1
    assert_eq "$t_snap" "$(snap_home)" "the first uninstall should leave no trace"

    # Through ./uninstall.sh, which is what a user actually reruns, and which by
    # now has only the repo copy left to find.
    assert_status 0 "$REPO_ROOT/uninstall.sh" --yes </dev/null
    assert_contains "$OUT" 'nothing to undo' "the second run should say so"
    assert_eq "$t_snap" "$(snap_home)" "and change nothing"
    assert_zkg_never_ran
}

test_a_block_with_no_script_left_is_still_something_to_undo() {
    premachine
    t_snap=$(snap_home)
    run_install >/dev/null || return 1

    # Deleting the script is not an uninstall: the block still evals
    # `zenv init` in every new shell, and it is the part that has to go. So the
    # "nothing to undo" check must not be answered by looking at the script
    # alone -- that is the shortcut that would leave the block forever.
    rm -f "$T_BIN" "$T_BASH" "$T_ZSH"
    assert_status 0 "$REPO_ROOT/bin/zenv" uninstall --yes
    assert_not_contains "$OUT" 'nothing to undo' "there was still a block to remove"
    assert_contains "$OUT" "removed the zenv block from $T_RC" \
        "and it should say it removed it"

    # The full snapshot, not just the block: install.sh's `mkdir -p` ran, so the
    # empty ~/.local chain those hand-deleted files left has to go too. Gating
    # the directory walk on the file still being there is what would leave it.
    assert_eq "$t_snap" "$(snap_home)" \
        "the empty directories the deleted files left should go with them"
    assert_zkg_never_ran
}

test_a_hand_deleted_install_still_leaves_no_empty_directories() {
    premachine
    run_install >/dev/null || return 1

    # The same case as above, asserted on the directories themselves rather than
    # through the snapshot, because they are the specific thing that used to be
    # left: the tidy-up was gated on the file still being there, so hand-deleting
    # the three files made ~/.local/share/bash-completion/completions permanent.
    rm -f "$T_BIN" "$T_BASH" "$T_ZSH"
    assert_dir "$HOME/.local/bin" "the directories should still be there to tidy"
    assert_dir "$HOME/.local/share/zsh/site-functions" "and the completion dirs"

    assert_status 0 "$REPO_ROOT/bin/zenv" uninstall --yes
    assert_missing "$HOME/.local" "the whole empty chain should be gone"
    assert_zkg_never_ran

    # What zenv cannot do is tidy up after an install it can no longer see at
    # all. With --no-rc there is no block either, so once the three files are
    # deleted by hand the only trace left is an empty ~/.local/bin -- and that is
    # indistinguishable from one you made yourself, so uninstall says there is
    # nothing to undo rather than deleting a directory that may not be its own.
    run_install --no-rc >/dev/null || return 1
    rm -f "$T_BIN" "$T_BASH" "$T_ZSH"
    assert_status 0 "$REPO_ROOT/bin/zenv" uninstall --yes
    assert_contains "$OUT" 'nothing to undo' "it should not guess at that one"
    assert_dir "$HOME/.local/bin" "and should leave the directory alone"
}

test_a_directory_of_your_own_stops_the_tidy_up() {
    premachine
    t_snap=$(snap_home)
    run_install --no-rc >/dev/null || return 1

    # _un_rmdirs walks up only while each directory is empty, so anything of
    # yours in the chain stops it -- and stops it at that directory, keeping
    # every parent above. Without this the walk would be a licence to delete
    # ~/.local.
    printf 'mine\n' >"$HOME/.local/bin/something-of-mine"
    assert_status 0 "$REPO_ROOT/bin/zenv" uninstall --yes
    assert_file "$HOME/.local/bin/something-of-mine" "your file should survive"
    assert_dir "$HOME/.local/bin" "and the directory holding it"
    assert_ne "$t_snap" "$(snap_home)" "so this machine is not back to pre-zenv"
    assert_missing "$HOME/.local/share" \
        "but the chain that did empty should still be gone"
}

test_uninstall_sh_exits_zero_when_it_finds_no_zenv_at_all() {
    premachine
    t_snap=$(snap_home)

    # uninstall.sh holds no logic, so with nothing on PATH, nothing in
    # ~/.local/bin and no bin/zenv beside it, it has nobody to delegate to. That
    # is still "nothing installed", not a failure -- but a bin/zenv that is there
    # and not executable is a broken checkout, and must not report the same.
    t_repo="$SANDBOX/repo"
    mkdir -p "$t_repo/bin"
    cp "$REPO_ROOT/uninstall.sh" "$t_repo/"
    assert_status 0 "$t_repo/uninstall.sh" --yes </dev/null
    assert_contains "$OUT" 'nothing to undo' "it should say there is nothing to do"
    assert_eq "$t_snap" "$(snap_home)" "and change nothing"

    cp "$REPO_ROOT/bin/zenv" "$t_repo/bin/zenv"
    chmod -x "$t_repo/bin/zenv"
    assert_status 1 "$t_repo/uninstall.sh" --yes </dev/null
    assert_contains "$OUT" 'not executable' "a broken checkout should say so instead"
    assert_eq "$t_snap" "$(snap_home)" "and still change nothing"
}

# ---------------------------------------------------------------------------
# An activated shell survives the uninstall
# ---------------------------------------------------------------------------

test_deactivate_still_restores_a_shell_after_uninstall() {
    premachine
    install_and_adopt || return 1

    # The restore code is emitted inline as _zenv_deactivate, so a shell that
    # activated before the uninstall can still put itself back with no zenv on
    # disk at all. That is what makes uninstalling from an activated shell safe.
    probe "$PROBE_SHELL" 'eval "$("$ZENV_INSTALLED" shell activate default)"
rm -f "$ZENV_INSTALLED"
_zenv_deactivate'
    assert_eq '<unset>' "$(probe_var ZENV)" "ZENV should be unset again"
    assert_eq '<unset>' "$(probe_var ZENV_PREFIX)" "ZENV_PREFIX should be unset again"
    assert_not_contains "$(probe_var PATH)" "$ZENV_ROOT/default/zeek/bin" \
        "the environment's bin should be off PATH"
    assert_missing "$T_BIN" "the probe really did remove the script"
}

# ---------------------------------------------------------------------------
# restore -- the inverse of adopt --move, on its own
# ---------------------------------------------------------------------------

test_restore_is_the_exact_inverse_of_adopt_move() {
    premachine
    t_snap=$(snap_home)
    assert_status 0 "$ZENV_BIN" adopt default

    assert_status 0 "$ZENV_BIN" restore default --yes
    assert_missing "$ZENV_ROOT/default" "the environment itself should be gone"

    # The root and its `config` are not restore's business: `config` records
    # *where* the two symlinks belong, which is a setting rather than a claim
    # that they exist, and other environments may still be registered beside it.
    # So it is accounted for here by hand, and asserted to be all that is left --
    # `zenv uninstall` is what takes the root itself away.
    assert_eq 'config' "$(cd "$ZENV_ROOT" && find . -mindepth 1 | sed 's|^\./||')" \
        "the root should hold nothing but its own config"
    rm -rf "$ZENV_ROOT"
    assert_eq "$t_snap" "$(snap_home)" "restore should undo adopt --move exactly"
    assert_zkg_never_ran
}

test_restore_dry_run_changes_nothing() {
    premachine
    assert_status 0 "$ZENV_BIN" adopt default
    t_snap=$(snap_home)

    assert_status 0 "$ZENV_BIN" restore default --dry-run
    assert_eq "$t_snap" "$(snap_home)" "a dry run must change nothing"
    assert_contains "$OUT" 'would move' "but should say what it would do"
    assert_contains "$OUT" "$HOME/zeek" "naming where the install goes back to"
}

test_restore_refuses_an_environment_it_did_not_move() {
    premachine
    assert_status 0 "$ZENV_BIN" new dev
    mkprefix "$ZENV_ROOT/dev/zeek"
    assert_status 1 "$ZENV_BIN" restore dev --yes
    assert_contains "$OUT" 'nowhere to' "an environment you built has nowhere to go"
    assert_dir "$ZENV_ROOT/dev/zeek" "and is left exactly as it was"

    # --link registers an install where it is, so nothing was ever moved.
    mkprefix "$SANDBOX/elsewhere"
    assert_status 0 "$ZENV_BIN" adopt other --from "$SANDBOX/elsewhere"
    assert_status 1 "$ZENV_BIN" restore other --yes
    assert_contains "$OUT" 'nothing was moved' "a linked adoption has nothing to undo"
    assert_symlink "$ZENV_ROOT/other/zeek" "and its symlink is left alone"
    assert_zkg_never_ran
}

test_restore_records_how_the_environment_was_adopted() {
    premachine
    assert_status 0 "$ZENV_BIN" adopt default
    assert_contains "$(cat "$ZENV_ROOT/default/env")" 'adopted=moved' \
        "adopt --move should record that it moved the install"

    mkprefix "$SANDBOX/elsewhere"
    assert_status 0 "$ZENV_BIN" adopt other --from "$SANDBOX/elsewhere"
    assert_contains "$(cat "$ZENV_ROOT/other/env")" 'adopted=linked' \
        "adopt --link should record that it did not"

    assert_status 0 "$ZENV_BIN" new dev
    assert_contains "$(cat "$ZENV_ROOT/dev/env")" 'adopted=' \
        "and zenv new should leave the key empty rather than absent"
}

run_cases
