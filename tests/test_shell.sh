#!/bin/sh
# Step C's gate: the `shell activate` / `shell deactivate` emitters, `init`, and
# the PATH / PYTHONPATH / MANPATH surgery.
#
# Covers plan tests 3-6, the PATH hazard table, quoting and `eval` safety, the
# save/restore matrix for the six overridden variables, prompt handling and
# idempotence.
#
# The emitted code is always eval'd in a *fresh* shell with default options, via
# probe(), never in the harness. run.sh runs this file under sh, bash and zsh, so
# PROBE_SHELL below tracks whichever one is running and the three-shell coverage
# of the emitted code falls out of the outer loop.
#
# shellcheck disable=SC2016
#   Single-quoted `$` in this file is shell code for another shell to expand,
#   or the literal text an assertion looks for. Expanding it in this process is
#   the bug these cases exist to catch.

. "$REPO_ROOT/tests/lib.sh"

# ---------------------------------------------------------------------------
# Local helpers
# ---------------------------------------------------------------------------

# The interpreter running this file, so the emitted code is eval'd by the same
# shell the case is exercising.
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

# Run code in a fresh PROBE_SHELL and dump PROBE_VARS. Sets OUT.
sh_probe() { probe "$PROBE_SHELL" "$1"; }

# The activation line as a user's shell runs it. Names are validated, so a name
# can be spliced into generated code; paths never are.
act_line() { printf 'eval "$("$ZENV_BIN" shell activate %s)"' "$1"; }

# An environment with a fake install in it, which is the normal case: `zenv new`
# for the layout and metadata, then a prefix that answers zeek-config.
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

# An environment with no install at all -- created but never built.
mkbareenv() { zenv new "$1" >/dev/null 2>&1; }

# Give an env a zkg config, the way `zenv autoconfig` will in step D.
mkzkgconfig() {
    _mzn=$1
    _mzs=$2
    _mzp=$3
    mkdir -p "$ZENV_ROOT/$_mzn/zkg"
    {
        printf '[sources]\n'
        printf 'zeek = https://github.com/zeek/packages\n'
        printf '\n[paths]\n'
        printf 'state_dir = %s\n' "$ZENV_ROOT/$_mzn/zkg"
        printf 'script_dir = %s\n' "$_mzs"
        printf 'plugin_dir = %s\n' "$_mzp"
        printf 'bin_dir = %s\n' "$ZENV_ROOT/$_mzn/zeek/bin"
        printf 'zeek_dist = \n'
    } >"$ZENV_ROOT/$_mzn/zkg/config"
}

# Every symlink under the sandbox HOME, so "creates no symlinks" is asserted
# against the whole tree rather than against two guessed paths.
links_under_home() { find "$HOME" -type l 2>/dev/null | LC_ALL=C sort; }

# Split a colon-separated value into lines, so a component can be counted.
colon_lines() { printf '%s\n' "$1" | tr ':' '\n'; }

# How many components of a value equal <dir> exactly. A shell loop rather than
# grep, so a directory containing a regex metacharacter needs no escaping.
count_component() {
    _ccrest=$1
    _ccd=$2
    _ccn=0
    while :; do
        case $_ccrest in
            *:*)
                _ccc=${_ccrest%%:*}
                _ccrest=${_ccrest#*:}
                _cclast=
                ;;
            *)
                _ccc=$_ccrest
                _cclast=1
                ;;
        esac
        [ "$_ccc" = "$_ccd" ] && _ccn=$((_ccn + 1))
        [ -z "$_cclast" ] || break
    done
    printf '%s\n' "$_ccn"
}

# Stubs for every build tool, so "zenv never builds Zeek" keeps being asserted
# by behaviour as new commands appear. Mirrors test_paths.sh's copy.
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
    cp "$SANDBOX/bin/configure" "$SANDBOX/configure"
}

assert_no_build_tool_ran() {
    if [ ! -f "${BUILD_STUB_LOG:-/nonexistent}" ]; then return 0; fi
    fail "${1:-a build tool was executed}"
    fail_detail "log: $(cat "$BUILD_STUB_LOG")"
    return 1
}

# ---------------------------------------------------------------------------
# Plan test 3: activation adds the environment to this shell
# ---------------------------------------------------------------------------

test_activate_prepends_the_bin_python_and_man_directories() {
    mkenv a || return 1
    p=$(realpath_p "$ZENV_ROOT/a/zeek")

    sh_probe "$(act_line a)"

    got=$(probe_var PATH)
    case $got in
        "$p/bin":*) ;;
        *)
            fail "PATH must begin with the env's bin dir"
            fail_detail "want prefix: $p/bin:"
            fail_detail "got:         $got"
            ;;
    esac

    got=$(probe_var PYTHONPATH)
    case $got in
        "$p/lib/zeek/python"*) ;;
        *) fail "PYTHONPATH must begin with $p/lib/zeek/python, got: $got" ;;
    esac

    got=$(probe_var MANPATH)
    case $got in
        "$p/share/man"*) ;;
        *) fail "MANPATH must begin with $p/share/man, got: $got" ;;
    esac
}

test_activate_sets_every_marker_and_zkg_variable() {
    mkenv a || return 1
    p=$(realpath_p "$ZENV_ROOT/a/zeek")
    z=$(realpath_p "$ZENV_ROOT/a/zkg")

    sh_probe "$(act_line a)"

    assert_eq a "$(probe_var ZENV)" "ZENV names the env"
    assert_eq "$p" "$(probe_var ZENV_PREFIX)" "ZENV_PREFIX is the real prefix"
    assert_eq "$z" "$(probe_var ZENV_ZKG_DIR)" "ZENV_ZKG_DIR is the env's zkg dir"
    # All three, so behaviour is identical whichever zkg wins on PATH.
    assert_eq "$z/config" "$(probe_var ZKG_CONFIG_FILE)" "ZKG_CONFIG_FILE"
    assert_eq "$z" "$(probe_var ZEEK_ZKG_CONFIG_DIR)" "ZEEK_ZKG_CONFIG_DIR"
    assert_eq "$z" "$(probe_var ZEEK_ZKG_STATE_DIR)" "ZEEK_ZKG_STATE_DIR"
}

test_activate_takes_zeekpath_and_plugin_path_from_zeek_config() {
    mkenv a zeekpath=".:/from/zeek-config" plugin_dir=/from/zc/plugins || return 1

    sh_probe "$(act_line a)"

    assert_eq ".:/from/zeek-config" "$(probe_var ZEEKPATH)" \
        "ZEEKPATH comes from zeek-config --zeekpath"
    assert_eq /from/zc/plugins "$(probe_var ZEEK_PLUGIN_PATH)" \
        "ZEEK_PLUGIN_PATH comes from zeek-config --plugin_dir"
}

test_activate_unions_the_zkg_config_dirs_into_the_search_paths() {
    mkenv a zeekpath=".:/from/zc" plugin_dir=/from/zc/plugins || return 1
    mkzkgconfig a /from/zkg/site /from/zkg/plugins

    sh_probe "$(act_line a)"

    got=$(probe_var ZEEKPATH)
    assert_contains "$got" /from/zc "zeek-config's answer is kept"
    assert_contains "$got" /from/zkg/site "and zkg's script_dir is added"
    got=$(probe_var ZEEK_PLUGIN_PATH)
    assert_contains "$got" /from/zc/plugins "zeek-config's plugin dir is kept"
    assert_contains "$got" /from/zkg/plugins "and zkg's plugin_dir is added"
}

test_a_directory_named_by_both_zeek_config_and_zkg_appears_once() {
    mkenv a zeekpath=".:/shared/site" || return 1
    mkzkgconfig a /shared/site /shared/plugins

    sh_probe "$(act_line a)"

    got=$(probe_var ZEEKPATH)
    assert_eq 1 "$(count_component "$got" /shared/site)" \
        "a shared directory must be deduped, not listed twice"
}

test_activate_works_when_nothing_is_installed_yet() {
    # A created-but-never-built env must still activate: the layout is known, so
    # the search paths come from it rather than from a refusal.
    mkbareenv a
    p=$(realpath_p "$ZENV_ROOT/a/zeek")

    capture zenv shell activate a
    rc=$?
    assert_eq 0 "$rc" "activating an unbuilt env must succeed" || {
        fail_detail "stderr: $ERR"
        return 1
    }

    sh_probe "$(act_line a)"
    case $(probe_var PATH) in
        "$p/bin":*) ;;
        *) fail "PATH must still start with $p/bin, got: $(probe_var PATH)" ;;
    esac
    assert_contains "$(probe_var ZEEKPATH)" "$p/share/zeek/site" \
        "ZEEKPATH falls back to the standard layout"
    assert_eq "$p/lib/zeek/plugins" "$(probe_var ZEEK_PLUGIN_PATH)" \
        "ZEEK_PLUGIN_PATH falls back to the standard layout"
}

test_activate_creates_no_symlinks() {
    mkenv a || return 1
    before=$(links_under_home)
    zenv shell activate a >/dev/null 2>&1
    sh_probe "$(act_line a)"
    after=$(links_under_home)
    assert_eq "$before" "$after" \
        "activation is shell-local: it must create no symlinks"
}

test_activate_never_touches_zeek_dist_or_zeek_build_dir() {
    # Finding 5b makes this a deliberate contract, not an omission: nothing reads
    # ZEEK_DIST from the environment, and ZEEK_BUILD_DIR silently overrides the
    # source tree for any package that passes --zeek-dist.
    mkenv a || return 1
    for v in ZEEK_DIST ZEEK_BUILD_DIR; do
        for state in unset empty set; do
            case $state in
                unset)
                    pre="unset $v"
                    want='<unset>'
                    ;;
                empty)
                    pre="$v=''; export $v"
                    want=''
                    ;;
                set)
                    pre="$v='/sentinel/tree'; export $v"
                    want='/sentinel/tree'
                    ;;
            esac
            sh_probe "$pre
$(act_line a)"
            got=$(probe_var "$v")
            assert_eq "$want" "$got" "$v must survive activation ($state)" \
                || return 1
        done
    done
}

# ---------------------------------------------------------------------------
# Plan test 4: switching, and idempotence
# ---------------------------------------------------------------------------

test_switching_leaves_exactly_one_env_bin_in_path() {
    mkenv a || return 1
    mkenv b || return 1
    pa=$(realpath_p "$ZENV_ROOT/a/zeek")
    pb=$(realpath_p "$ZENV_ROOT/b/zeek")

    sh_probe "$(act_line a)
$(act_line b)"

    got=$(probe_var PATH)
    assert_eq 1 "$(count_component "$got" "$pb/bin")" \
        "b's bin dir appears exactly once"
    assert_eq 0 "$(count_component "$got" "$pa/bin")" \
        "a's bin dir is gone -- the finding-4 guard"
    case $got in
        "$pb/bin":*) ;;
        *) fail "PATH must begin with b's bin dir, got: $got" ;;
    esac
}

test_switching_removes_the_old_env_from_every_search_path() {
    mkenv a || return 1
    mkenv b || return 1
    pa=$(realpath_p "$ZENV_ROOT/a/zeek")

    sh_probe "$(act_line a)
$(act_line b)"

    for v in PATH PYTHONPATH MANPATH ZEEKPATH ZEEK_PLUGIN_PATH; do
        assert_not_contains "$(probe_var "$v")" "$pa" \
            "$v must hold no component of the previous env" || return 1
    done
}

test_activating_the_same_env_twice_is_a_no_op_on_the_paths() {
    mkenv a || return 1

    sh_probe "$(act_line a)"
    once_path=$(probe_var PATH)
    once_py=$(probe_var PYTHONPATH)
    once_man=$(probe_var MANPATH)

    sh_probe "$(act_line a)
$(act_line a)
$(act_line a)"

    assert_eq "$once_path" "$(probe_var PATH)" "PATH after 3 activations"
    assert_eq "$once_py" "$(probe_var PYTHONPATH)" "PYTHONPATH after 3 activations"
    assert_eq "$once_man" "$(probe_var MANPATH)" "MANPATH after 3 activations"
}

test_a_path_entry_added_between_activations_survives() {
    mkenv a || return 1
    mkenv b || return 1

    sh_probe "$(act_line a)
PATH=/added/by/hand:\$PATH
$(act_line b)"

    assert_eq 1 "$(count_component "$(probe_var PATH)" /added/by/hand)" \
        "a component the user added must survive a switch, exactly once"
}

test_switching_there_and_back_is_clean() {
    mkenv a || return 1
    mkenv b || return 1
    pa=$(realpath_p "$ZENV_ROOT/a/zeek")
    pb=$(realpath_p "$ZENV_ROOT/b/zeek")

    sh_probe "$(act_line a)"
    direct=$(probe_var PATH)

    sh_probe "$(act_line a)
$(act_line b)
$(act_line a)"
    roundabout=$(probe_var PATH)

    assert_eq "$direct" "$roundabout" \
        "a -> b -> a must land exactly where a alone does"
    assert_eq 0 "$(count_component "$roundabout" "$pb/bin")" "b is gone"
    assert_eq 1 "$(count_component "$roundabout" "$pa/bin")" "a is there once"
}

test_switching_keeps_the_pre_zenv_values_of_the_saved_variables() {
    # The save is guarded by "not already saved", so activating b while a is
    # active must not record a's ZEEKPATH as the value to restore.
    mkenv a || return 1
    mkenv b || return 1

    sh_probe "ZEEKPATH=/original; export ZEEKPATH
$(act_line a)
$(act_line b)
_zenv_deactivate"

    assert_eq /original "$(probe_var ZEEKPATH)" \
        "deactivate must restore the pre-zenv value, not the previous env's"
}

# ---------------------------------------------------------------------------
# Plan test 5: two shells, two environments, at once
# ---------------------------------------------------------------------------

test_two_shells_hold_different_environments_at_the_same_time() {
    mkenv a version=1.1.1 || return 1
    mkenv b version=2.2.2 || return 1
    pa=$(realpath_p "$ZENV_ROOT/a/zeek")
    pb=$(realpath_p "$ZENV_ROOT/b/zeek")

    sh_probe "$(act_line a)
(
  $(act_line b)
  printf 'INNER_PREFIX=%s\n' \"\$ZENV_PREFIX\"
  printf 'INNER_ZEEK=%s\n' \"\$(command -v zeek)\"
) >\"\$SANDBOX/inner.txt\"
printf 'OUTER_ZEEK=%s\n' \"\$(command -v zeek)\""

    inner=$(cat "$SANDBOX/inner.txt")
    assert_contains "$inner" "INNER_PREFIX=$pb" "the subshell holds b"
    assert_contains "$inner" "INNER_ZEEK=$pb/bin/zeek" "and resolves b's zeek"
    assert_eq "$pa" "$(probe_var ZENV_PREFIX)" \
        "the outer shell still holds a after the subshell switched"
    assert_contains "$OUT" "OUTER_ZEEK=$pa/bin/zeek" \
        "and still resolves a's zeek"
}

# ---------------------------------------------------------------------------
# Plan test 6: deactivation is the exact inverse
# ---------------------------------------------------------------------------

test_deactivate_leaves_the_environment_byte_identical() {
    # The whole environment, not just the variables zenv knows about: anything
    # activation leaks -- an exported PS1, a stray helper, a marker left behind --
    # shows up here.
    mkenv a || return 1

    sh_probe "PS1='prompt> '
_before=\$(env | LC_ALL=C sort)
$(act_line a)
_zenv_deactivate
_after=\$(env | LC_ALL=C sort)
printf '%s\n' \"\$_before\" >\"\$SANDBOX/env.before\"
printf '%s\n' \"\$_after\" >\"\$SANDBOX/env.after\"
if [ \"\$_before\" = \"\$_after\" ]; then printf 'ENVDIFF=none\n'; else printf 'ENVDIFF=differs\n'; fi"

    case $OUT in
        *'ENVDIFF=none'*) ;;
        *)
            fail "env must be unchanged after deactivate"
            fail_detail "$(diff "$SANDBOX/env.before" "$SANDBOX/env.after" 2>&1 | head -20)"
            ;;
    esac
    assert_eq 'prompt> ' "$(probe_var PS1)" "PS1 is back byte-for-byte"
}

test_deactivate_removes_every_component_activate_added() {
    mkenv a || return 1
    p=$(realpath_p "$ZENV_ROOT/a/zeek")

    sh_probe "$(act_line a)
_zenv_deactivate"

    for v in PATH PYTHONPATH MANPATH; do
        assert_not_contains "$(probe_var "$v")" "$p" \
            "$v must hold no component of the deactivated env" || return 1
    done
    for v in ZENV ZENV_PREFIX ZENV_ZKG_DIR; do
        assert_eq '<unset>' "$(probe_var "$v")" "$v must be unset again" || return 1
    done
}

test_deactivate_leaves_unrelated_components_untouched() {
    mkenv a || return 1

    sh_probe "PATH=/keep/one:\$PATH:/keep/two
PYTHONPATH=/keep/py; export PYTHONPATH
MANPATH=/keep/man; export MANPATH
_orig_path=\$PATH
$(act_line a)
_zenv_deactivate
if [ \"\$PATH\" = \"\$_orig_path\" ]; then printf 'PATHSAME=yes\n'; else printf 'PATHSAME=no\n'; fi"

    assert_contains "$OUT" 'PATHSAME=yes' "PATH must return to its exact prior value"
    assert_eq /keep/py "$(probe_var PYTHONPATH)" "PYTHONPATH is restored"
    assert_eq /keep/man "$(probe_var MANPATH)" "MANPATH is restored"
}

test_deactivate_twice_is_clean() {
    mkenv a || return 1

    sh_probe "$(act_line a)
_zenv_deactivate
_zenv_deactivate 2>/dev/null
printf 'RC=%s\n' \"\$?\""

    # The second call is gone: the function unsets itself, the way a venv's does.
    assert_ne 'RC=0' "$(printf '%s\n' "$OUT" | grep '^RC=' | head -1)" \
        "_zenv_deactivate must have unset itself"
    assert_eq '<unset>' "$(probe_var ZENV)" "and the environment stays restored"
}

test_the_fallback_deactivate_strips_the_env_without_the_function() {
    # `exec zsh` loses the shell-local function; `zenv shell deactivate` is the
    # fallback, and it must still get the paths right.
    mkenv a || return 1
    p=$(realpath_p "$ZENV_ROOT/a/zeek")

    sh_probe "$(act_line a)
unset -f _zenv_deactivate
eval \"\$(\"\$ZENV_BIN\" shell deactivate)\""

    for v in PATH PYTHONPATH MANPATH ZEEKPATH ZEEK_PLUGIN_PATH; do
        assert_not_contains "$(probe_var "$v")" "$p" \
            "$v must be stripped by the fallback too" || return 1
    done
    assert_eq '<unset>' "$(probe_var ZENV)" "ZENV is unset"
    assert_eq '<unset>' "$(probe_var ZKG_CONFIG_FILE)" "ZKG_CONFIG_FILE is unset"
}

test_shell_deactivate_with_nothing_active_is_clean() {
    capture zenv shell deactivate
    rc=$?
    assert_eq 0 "$rc" "it must exit 0" || fail_detail "stderr: $ERR"
    assert_status 0 /bin/sh -c "eval \"$OUT\"" || return 1
    assert_not_contains "$OUT" _zenv_strip \
        "with nothing to undo it must emit no machinery"
}

test_deactivate_when_the_environment_has_since_been_removed() {
    # The prefix list is baked into _zenv_deactivate at activation time, so a
    # shell can still restore itself after `zenv remove` (or a plain rm -rf).
    mkenv a || return 1
    p=$(realpath_p "$ZENV_ROOT/a/zeek")

    sh_probe "$(act_line a)
rm -rf \"\$ZENV_ROOT/a\"
_zenv_deactivate"

    assert_not_contains "$(probe_var PATH)" "$p" \
        "PATH must be cleaned even though the env is gone"
    assert_eq '<unset>' "$(probe_var ZENV)" "ZENV is unset"
}

# ---------------------------------------------------------------------------
# The save/restore matrix for the six overridden variables
# ---------------------------------------------------------------------------

test_the_six_overridden_variables_round_trip_from_unset_empty_and_set() {
    mkenv a || return 1
    for v in ZEEKPATH ZEEK_PLUGIN_PATH ZKG_CONFIG_FILE ZEEK_ZKG_CONFIG_DIR \
             ZEEK_ZKG_STATE_DIR PS1; do
        # PS1 is deliberately not exported, so its "set" case is a plain
        # assignment -- which is also how a real shell holds it.
        if [ "$v" = PS1 ]; then
            expo=
        else
            expo="; export $v"
        fi
        for state in unset empty set; do
            case $state in
                unset)
                    pre="unset $v"
                    want='<unset>'
                    ;;
                empty)
                    pre="$v=''$expo"
                    want=''
                    ;;
                set)
                    pre="$v='sentinel/$v'$expo"
                    want="sentinel/$v"
                    ;;
            esac
            sh_probe "$pre
$(act_line a)
_zenv_deactivate"
            assert_eq "$want" "$(probe_var "$v")" \
                "$v must round-trip from $state" || return 1
        done
    done
}

test_activation_actually_overwrites_the_six_it_saves() {
    # The matrix above would pass vacuously if activation never changed them.
    mkenv a || return 1
    sh_probe "ZEEKPATH=sentinel; export ZEEKPATH
ZEEK_PLUGIN_PATH=sentinel; export ZEEK_PLUGIN_PATH
ZKG_CONFIG_FILE=sentinel; export ZKG_CONFIG_FILE
ZEEK_ZKG_CONFIG_DIR=sentinel; export ZEEK_ZKG_CONFIG_DIR
ZEEK_ZKG_STATE_DIR=sentinel; export ZEEK_ZKG_STATE_DIR
PS1=sentinel
$(act_line a)"

    for v in ZEEKPATH ZEEK_PLUGIN_PATH ZKG_CONFIG_FILE ZEEK_ZKG_CONFIG_DIR \
             ZEEK_ZKG_STATE_DIR PS1; do
        assert_ne sentinel "$(probe_var "$v")" \
            "$v must be overwritten by activation" || return 1
    done
}

# ---------------------------------------------------------------------------
# Prompt handling
# ---------------------------------------------------------------------------

test_the_prompt_gains_exactly_one_prefix_however_often_you_activate() {
    mkenv a || return 1
    mkenv b || return 1

    sh_probe "PS1='base> '
$(act_line a)
$(act_line a)
$(act_line b)
$(act_line a)"

    assert_eq '(zenv:a) base> ' "$(probe_var PS1)" \
        "exactly one prefix, naming the environment actually active"
}

test_a_prompt_with_shell_escapes_survives_byte_for_byte() {
    mkenv a || return 1
    # zsh escapes, bash escapes, a literal $ and a backslash: all must come back
    # unchanged, which is why PS1 is restored from a saved variable rather than
    # rebuilt by stripping a prefix off the front.
    orig='%F{red}%n@%m\[\033[0m\] $PWD \\ %# '

    sh_probe "PS1='$orig'
$(act_line a)
_zenv_deactivate"

    assert_eq "$orig" "$(probe_var PS1)" "PS1 must be restored byte-for-byte"
}

test_the_prompt_prefix_keeps_a_prompt_with_escapes_intact() {
    mkenv a || return 1
    orig='%F{red}%n$ '
    sh_probe "PS1='$orig'
$(act_line a)"
    assert_eq "(zenv:a) $orig" "$(probe_var PS1)" \
        "the prefix is prepended to the original, not to a re-parsed copy"
}

test_zenv_disable_prompt_leaves_ps1_alone_and_saves_nothing() {
    mkenv a || return 1

    sh_probe "PS1='base> '
ZENV_DISABLE_PROMPT=1
$(act_line a)
printf 'DURING=[%s]\n' \"\$PS1\"
printf 'SAVED=[%s]\n' \"\${_ZENV_HAD_PS1-none}\"
_zenv_deactivate"

    assert_contains "$OUT" 'DURING=[base> ]' "PS1 is untouched during activation"
    assert_contains "$OUT" 'SAVED=[none]' "and nothing was saved for it"
    assert_eq 'base> ' "$(probe_var PS1)" "and it is still itself afterwards"
}

test_zenv_disable_prompt_works_unexported() {
    # Checked in the shell rather than read from the child's environment, so a
    # plain assignment in an rc file is enough.
    mkenv a || return 1
    sh_probe "PS1='base> '
ZENV_DISABLE_PROMPT=yes
$(act_line a)"
    assert_eq 'base> ' "$(probe_var PS1)" "an unexported value must still count"
}

test_ps1_is_never_exported() {
    # Exporting PS1 would change every child's environment, which is a change
    # deactivate could not undo -- and it would break the env-diff guarantee.
    mkenv a || return 1
    sh_probe "PS1='base> '
$(act_line a)
if env | grep -q '^PS1='; then printf 'EXPORTED=yes\n'; else printf 'EXPORTED=no\n'; fi"
    assert_contains "$OUT" 'EXPORTED=no' "PS1 must not be exported"
}

# ---------------------------------------------------------------------------
# The PATH hazard table, at the unit level
# ---------------------------------------------------------------------------

# _path_strip's contract: <value> <newline-separated dirs> -> value.
STRIP='printf "[%s]\n" "$(_path_strip "$1" "$2")"'

strip_case() {
    zenv_lib "$STRIP" "$1" "$2"
    assert_eq "[$3]" "$OUT" "${4:-_path_strip [$1] minus [$2]}"
}

test_path_surgery_preserves_empty_components() {
    # An empty component means the current directory. Dropping it, or turning it
    # into '.', changes which program runs.
    strip_case '/a::/b' /x '/a::/b' "a doubled colon in the middle survives"
    strip_case ':/a' /x ':/a' "a leading colon survives"
    strip_case '/a:' /x '/a:' "a trailing colon survives"
    strip_case '::' /x '::' "a value of nothing but colons survives"
    # ['', /gone, ''] minus /gone is ['', ''], which is written ':' -- the two
    # current-directory entries are still both there.
    strip_case ':/gone:' /gone ':' "and stays put when a neighbour is removed"
}

test_path_surgery_removes_every_occurrence_and_keeps_the_order() {
    strip_case '/gone:/a:/gone:/b:/gone' /gone '/a:/b' "all three occurrences"
    strip_case '/a:/gone:/b' /gone '/a:/b' "a mid-list entry"
    strip_case '/gone' /gone '' "the only entry"
    strip_case '/a:/b:/c' /x '/a:/b:/c' "no match changes nothing"
}

test_path_surgery_matches_a_trailing_slash() {
    strip_case '/a:/gone/:/b' /gone '/a:/b' "a trailing slash still matches"
    strip_case '/a:/gone///:/b' /gone '/a:/b' "so do several"
    strip_case '/a/:/b' /x '/a/:/b' "but a survivor keeps its own slash"
}

test_path_surgery_does_not_interpret_regex_metacharacters() {
    # Removal is a component-by-component shell loop, not sed. A root named
    # zenv.d+x[1] would otherwise be read as a pattern.
    strip_case '/r/zenv.d+x[1]/a/zeek/bin:/keep' '/r/zenv.d+x[1]/a/zeek/bin' \
        /keep "the literal path is removed"
    strip_case '/r/zenvXdXxX1X/a/zeek/bin:/keep' '/r/zenv.d+x[1]/a/zeek/bin' \
        '/r/zenvXdXxX1X/a/zeek/bin:/keep' "a path the pattern would match is not"
    strip_case '/a*b:/keep' '/a*b' /keep "a star is a character, not a glob"
    strip_case '/aXb:/keep' '/a*b' '/aXb:/keep' "so it matches nothing else"
}

test_path_surgery_takes_a_list_of_directories() {
    strip_case '/g1:/a:/g2:/b' "/g1
/g2" '/a:/b' "every directory in the list goes"
    strip_case '/a:/b' "
" '/a:/b' "an empty list is a no-op"
}

test_path_surgery_handles_a_directory_with_a_space_and_a_quote() {
    strip_case "/it's here/bin:/keep" "/it's here/bin" /keep \
        "a quote and a space in a component"
}

test_the_emitted_strip_agrees_with_the_internal_one() {
    # bin/zenv strips at activation time and the emitted _zenv_strip strips at
    # deactivation time. Two implementations of one rule, so run the whole table
    # through both and require identical answers.
    mkenv a || return 1
    zenv shell activate a >"$SANDBOX/act.sh" 2>/dev/null

    # value <TAB> dir, one case per line.
    cat >"$SANDBOX/table" <<'EOF'
/a::/b	/x
:/a	/x
/a:	/x
::	/x
:/gone:	/gone
/gone:/a:/gone:/b:/gone	/gone
/a:/gone:/b	/gone
/gone	/gone
/a:/gone/:/b	/gone
/a:/gone///:/b	/gone
/a/:/b	/x
/r/zenv.d+x[1]/a/zeek/bin:/keep	/r/zenv.d+x[1]/a/zeek/bin
/a*b:/keep	/a*b
/aXb:/keep	/a*b
	/x
/it's here/bin:/keep	/it's here/bin
EOF

    # The emitted side: source the activate output for _zenv_strip, then answer
    # the table. Run under PROBE_SHELL, so the agreement holds in every shell.
    {
        printf '. "$SANDBOX/act.sh" >/dev/null 2>&1\n'
        printf 'while IFS="\t" read -r v d; do\n'
        printf '  printf "[%%s]\\n" "$(_zenv_strip "$v" "$d")"\n'
        printf 'done <"$SANDBOX/table"\n'
    } >"$SANDBOX/emitted.sh"
    emitted=$("$PROBE_SHELL" "$SANDBOX/emitted.sh" 2>&1)

    # The internal side.
    {
        printf 'ZENV_LIB_ONLY=1\n'
        printf '. "$ZENV_BIN"\n'
        printf 'while IFS="\t" read -r v d; do\n'
        printf '  printf "[%%s]\\n" "$(_path_strip "$v" "$d")"\n'
        printf 'done <"$SANDBOX/table"\n'
    } >"$SANDBOX/internal.sh"
    internal=$(/bin/sh "$SANDBOX/internal.sh" 2>&1)

    assert_eq "$internal" "$emitted" \
        "_path_strip and the emitted _zenv_strip must agree on every case"
    assert_eq "$(grep -c . "$SANDBOX/table")" \
        "$(printf '%s\n' "$internal" | grep -c '^\[')" \
        "every table row must have produced an answer"
}

test_an_unrelated_zeek_bin_is_never_removed() {
    # Removal enumerates the root's environments; it does not pattern-match, so a
    # directory that merely looks like a Zeek install is left alone.
    mkenv a || return 1

    sh_probe "PATH=/opt/other/zeek/bin:\$PATH
$(act_line a)
_zenv_deactivate"

    assert_eq 1 "$(count_component "$(probe_var PATH)" /opt/other/zeek/bin)" \
        "an unrelated .../zeek/bin must survive activation and deactivation"
}

test_activate_with_an_empty_path_still_produces_a_usable_one() {
    # An empty PATH is inherited by the `zenv shell activate` subprocess, so this
    # also asserts nothing on the activation path forks: one `sed` in _shq was
    # enough to make recovering from a broken PATH impossible.
    mkenv a || return 1
    p=$(realpath_p "$ZENV_ROOT/a/zeek")
    sh_probe "PATH=''; export PATH
$(act_line a)"
    assert_eq "$p/bin" "$(probe_var PATH)" \
        "an empty PATH becomes the single entry, with no stray colon"
}

test_activate_with_a_root_full_of_metacharacters() {
    # The plan's named case: a root that is a regex if anything treats it as one.
    ZENV_ROOT="$SANDBOX/zenv.d+x[1] root"
    export ZENV_ROOT
    mkenv a || return 1
    p=$(realpath_p "$ZENV_ROOT/a/zeek")

    sh_probe "PATH=/before:\$PATH
$(act_line a)
$(act_line a)
_zenv_deactivate"

    assert_eq 0 "$(count_component "$(probe_var PATH)" "$p/bin")" \
        "the metacharacter path must be removed exactly"
    assert_eq 1 "$(count_component "$(probe_var PATH)" /before)" \
        "and nothing else disturbed"
}

test_manpath_unset_keeps_the_system_default() {
    mkenv a || return 1
    p=$(realpath_p "$ZENV_ROOT/a/zeek")

    sh_probe "unset MANPATH
$(act_line a)"

    # A bare value replaces man's built-in search path; the trailing empty
    # component is what keeps the system pages reachable.
    assert_eq "$p/share/man:" "$(probe_var MANPATH)" \
        "MANPATH must keep an empty trailing component when it was unset"
}

test_manpath_already_set_is_prepended_to() {
    mkenv a || return 1
    p=$(realpath_p "$ZENV_ROOT/a/zeek")
    sh_probe "MANPATH=/my/man; export MANPATH
$(act_line a)"
    assert_eq "$p/share/man:/my/man" "$(probe_var MANPATH)" \
        "an existing MANPATH is prepended to, not replaced"
}

# ---------------------------------------------------------------------------
# The export attribute
#
# Activation has to export what it sets, or the child processes that matter --
# man, zeek, zkg -- cannot see it. A variable that was set but *not* exported
# must therefore have its attribute given back, which is why the save records
# exportedness alongside the value. zsh makes this concrete: it gives every
# shell an unexported empty MANPATH.
# ---------------------------------------------------------------------------

exported_in_probe() {
    printf 'if env | grep -q "^%s="; then printf "%s=exported\\n"; else printf "%s=local\\n"; fi\n' \
        "$2" "$1" "$1"
}

test_an_unexported_variable_is_unexported_again_afterwards() {
    mkenv a || return 1

    sh_probe "MANPATH=/my/man
ZEEKPATH=/my/scripts
$(act_line a)
$(exported_in_probe MAN_DURING MANPATH)
$(exported_in_probe ZP_DURING ZEEKPATH)
_zenv_deactivate
$(exported_in_probe MAN_AFTER MANPATH)
$(exported_in_probe ZP_AFTER ZEEKPATH)"

    assert_contains "$OUT" 'MAN_DURING=exported' "man must be able to see MANPATH"
    assert_contains "$OUT" 'ZP_DURING=exported' "zeek must be able to see ZEEKPATH"
    assert_contains "$OUT" 'MAN_AFTER=local' "and the attribute comes back"
    assert_contains "$OUT" 'ZP_AFTER=local' "for both"
    assert_eq /my/man "$(probe_var MANPATH)" "with the value intact"
    assert_eq /my/scripts "$(probe_var ZEEKPATH)" "for both"
}

test_an_exported_variable_stays_exported_afterwards() {
    mkenv a || return 1

    sh_probe "MANPATH=/my/man; export MANPATH
ZEEKPATH=/my/scripts; export ZEEKPATH
$(act_line a)
_zenv_deactivate
$(exported_in_probe MAN_AFTER MANPATH)
$(exported_in_probe ZP_AFTER ZEEKPATH)"

    assert_contains "$OUT" 'MAN_AFTER=exported' "an exported MANPATH stays exported"
    assert_contains "$OUT" 'ZP_AFTER=exported' "and so does ZEEKPATH"
    assert_eq /my/man "$(probe_var MANPATH)" "with the value intact"
}

test_a_variable_this_shell_never_had_is_not_left_behind_in_the_environment() {
    # The unset case: nothing may appear in `env` at all, exported or otherwise.
    mkenv a || return 1

    sh_probe "unset MANPATH ZEEKPATH 2>/dev/null || true
$(act_line a)
_zenv_deactivate
if env | grep -qE '^(MANPATH|ZEEKPATH|ZENV|ZENV_PREFIX|ZENV_ZKG_DIR)='; then
    printf 'LEFTOVER=yes\n'
    env | grep -E '^(MANPATH|ZEEKPATH|ZENV)'
else
    printf 'LEFTOVER=no\n'
fi"

    assert_contains "$OUT" 'LEFTOVER=no' "nothing may be left in the environment"
}

# ---------------------------------------------------------------------------
# The shared-source-tree reminder
#
# Activating an environment does not check its source tree back out, and one
# checkout shared between environments is the normal way to work. So the moment
# of switching is where the reminder belongs: it is the only point at which zenv
# knows both which environment you want and which commit its tree is on.
#
# Every case here also asserts the reminder stayed on stderr, because stdout is
# eval'd by the caller's shell.
# ---------------------------------------------------------------------------

# An environment wired to a verified git checkout, with its build commit
# recorded. Prints the commit. Usage: mkenv_with_tree <name> <tree> <version>
mkenv_with_tree() {
    mkdist "$2" "$3"
    _mwtsha=$(mkgit "$2") || return 1
    mkenv "$1" version="$3" zeek_dist="$2" || return 1
    mkzkgstub "$ZENV_ROOT/$1/zeek/bin/zkg"
    zenv autoconfig "$1" >/dev/null 2>&1 || {
        fail "mkenv_with_tree: autoconfig $1 failed"
        return 1
    }
    printf '%s' "$_mwtsha"
}

test_activate_says_nothing_while_the_tree_is_on_the_build_commit() {
    have_git || return 0
    mkenv_with_tree a "$SANDBOX/src" 9.1.0-dev.42 >/dev/null || return 1

    capture zenv shell activate a || fail "activation must succeed"
    assert_not_contains "$ERR" 'checkout' "a tree in sync is not worth a word"
}

test_activate_names_the_commit_to_check_out_when_the_tree_has_moved() {
    have_git || return 0
    sha=$(mkenv_with_tree a "$SANDBOX/src" 9.1.0-dev.42) || return 1

    # What a `git pull` in a shared checkout looks like: the tree moves on, and
    # its version moves with it, so it no longer matches the install.
    mkdist "$SANDBOX/src" 9.1.0-dev.96
    mkgit_move "$SANDBOX/src" >/dev/null || return 1

    capture zenv shell activate a || fail "a moved tree must not block activation"
    assert_contains "$ERR" "git -C $SANDBOX/src checkout $sha" \
        "the reminder has to be the command that fixes it"
    assert_contains "$ERR" "$(printf '%.12s' "$sha")" 'the build commit'
    assert_contains "$ERR" '--zeek-dist' 'and what actually reads that tree'
    assert_not_contains "$OUT" 'checkout' 'stdout stays pure shell code'

    # And the emitted code is still usable: a reminder is not a refusal.
    sh_probe "$(act_line a)"
    assert_eq a "$(probe_var ZENV)" "the environment is still activated"
}

test_the_reminder_can_be_silenced() {
    have_git || return 0
    mkenv_with_tree a "$SANDBOX/src" 9.1.0-dev.42 >/dev/null || return 1
    mkdist "$SANDBOX/src" 9.1.0-dev.96
    mkgit_move "$SANDBOX/src" >/dev/null || return 1

    capture env ZENV_DISABLE_REMINDER=1 "$ZENV_BIN" shell activate a \
        || fail "activation must succeed"
    assert_not_contains "$ERR" 'checkout' 'ZENV_DISABLE_REMINDER silences it'
}

test_the_reminder_reports_drift_it_cannot_name_a_commit_for() {
    # No git, so no commit was ever recorded. The drift is still worth saying,
    # together with the way to make the next one nameable.
    mkdist "$SANDBOX/src" 9.1.0-dev.42
    mkenv a version=9.1.0-dev.42 zeek_dist="$SANDBOX/src" || return 1
    mkzkgstub "$ZENV_ROOT/a/zeek/bin/zkg"
    zenv autoconfig a >/dev/null 2>&1 || return 1
    mkdist "$SANDBOX/src" 9.1.0-dev.96

    capture zenv shell activate a || fail "activation must succeed"
    assert_contains "$ERR" 'disagree' 'the drift is named'
    assert_contains "$ERR" '9.1.0-dev.96' 'with the version that decided it'
    assert_not_contains "$ERR" 'git -C' 'but no commit is invented'
}

test_a_tree_that_is_gone_is_not_reminded_about() {
    # gone and none are normal states doctor reports as information; a warning on
    # every activation would be noise, and there is nothing to check out.
    mkenv a version=9.1.0-dev.42 zeek_dist="$SANDBOX/never-existed" || return 1

    capture zenv shell activate a || fail "activation must succeed"
    assert_not_contains "$ERR" 'disagree' 'a missing tree is not drift'
    assert_not_contains "$ERR" 'checkout'
}

# ---------------------------------------------------------------------------
# Quoting and eval safety
# ---------------------------------------------------------------------------

test_the_emitted_code_parses_as_posix_shell() {
    mkenv a || return 1
    zenv shell activate a >"$SANDBOX/act.sh" 2>"$SANDBOX/act.err"
    assert_eq 0 "$?" "shell activate must succeed"

    if ! /bin/sh -n "$SANDBOX/act.sh" 2>"$SANDBOX/n.err"; then
        fail "sh -n rejected the activate output"
        fail_detail "$(cat "$SANDBOX/n.err")"
    fi

    zenv shell deactivate >"$SANDBOX/deact.sh" 2>/dev/null
    if ! /bin/sh -n "$SANDBOX/deact.sh" 2>"$SANDBOX/n2.err"; then
        fail "sh -n rejected the deactivate output"
        fail_detail "$(cat "$SANDBOX/n2.err")"
    fi
}

test_activate_emits_shell_code_only_to_stdout() {
    # Anything human-readable on stdout would be eval'd. Diagnostics go to stderr
    # so autoconfig chatter can never corrupt the eval.
    mkenv a || return 1
    out=$(zenv shell activate a 2>/dev/null)
    case $out in
        '# zenv activate a'*) ;;
        *) fail "stdout must begin with the emitted comment header" ;;
    esac
    assert_not_contains "$out" 'prefix:' "no human-readable output on stdout"
    assert_not_contains "$out" 'next:' "no hints on stdout"
}

test_a_failing_activate_writes_nothing_evaluable() {
    # A half-applied environment is impossible only if a failure emits nothing at
    # all on stdout: the shell function evals unconditionally on success.
    mkenv a || return 1
    for bad in nosuch 'has space' ../escape config; do
        out=$(zenv shell activate "$bad" 2>"$SANDBOX/e")
        st=$?
        assert_ne 0 "$st" "activate '$bad' must fail"
        assert_eq '' "$out" "activate '$bad' must write nothing to stdout"
        if [ ! -s "$SANDBOX/e" ]; then
            fail "activate '$bad' must explain itself on stderr"
        fi
    done

    # And with no argument at all.
    out=$(zenv shell activate 2>/dev/null)
    assert_ne 0 $? "activate with no name must fail"
    assert_eq '' "$out" "and write nothing to stdout"

    # Eval'ing the empty output must leave the shell untouched.
    sh_probe 'eval "$("$ZENV_BIN" shell activate nosuch 2>/dev/null)" || true'
    assert_eq '<unset>' "$(probe_var ZENV)" "no marker after a failed activate"
}

test_shell_rejects_an_unknown_subcommand() {
    out=$(zenv shell wat 2>/dev/null)
    assert_ne 0 $? "shell wat must fail"
    assert_eq '' "$out" "and emit nothing evaluable"
    out=$(zenv shell 2>/dev/null)
    assert_ne 0 $? "bare 'shell' must fail"
    assert_eq '' "$out" "and emit nothing evaluable"
    out=$(zenv shell deactivate extra 2>/dev/null)
    assert_ne 0 $? "deactivate takes no argument"
    assert_eq '' "$out" "and emit nothing evaluable"
}

test_a_hostile_environment_name_survives_the_round_trip() {
    # The name is validated, so the hazard is in the *root*: it reaches PS1, the
    # marker variables and every emitted path. A quote in it must stay inert.
    ZENV_ROOT="$SANDBOX/it's a root"
    export ZENV_ROOT
    mkenv a || return 1
    p=$(realpath_p "$ZENV_ROOT/a/zeek")

    sh_probe "PS1='base> '
SENTINEL=untouched
$(act_line a)
printf 'SENTINEL=[%s]\n' \"\$SENTINEL\""

    assert_eq "$p" "$(probe_var ZENV_PREFIX)" "the quoted prefix survives eval"
    assert_contains "$OUT" 'SENTINEL=[untouched]' "and executed nothing of its own"
    assert_eq 1 "$(count_component "$(probe_var PATH)" "$p/bin")" \
        "and lands on PATH exactly once"
}

test_a_prefix_that_looks_like_shell_code_is_inert() {
    ZENV_ROOT="$SANDBOX/\$(touch pwned)\`touch pwned2\`"
    export ZENV_ROOT
    mkenv a || return 1

    sh_probe "$(act_line a)"

    assert_missing "$SANDBOX/pwned" "command substitution must not run"
    assert_missing "$SANDBOX/pwned2" "nor backticks"
    assert_contains "$(probe_var ZENV_PREFIX)" '$(touch pwned)' \
        "the literal text is what ends up in the variable"
}

# ---------------------------------------------------------------------------
# zenv init, and the activate stub
# ---------------------------------------------------------------------------

test_init_emits_a_function_that_intercepts_activate_and_deactivate() {
    mkenv a || return 1
    p=$(realpath_p "$ZENV_ROOT/a/zeek")

    probe "$PROBE_SHELL" 'eval "$("$ZENV_BIN" init sh)"
PATH="$(dirname "$ZENV_BIN"):$PATH"
zenv activate a
zenv deactivate'

    assert_eq '<unset>' "$(probe_var ZENV)" \
        "the round trip through the function is clean"
    assert_eq 0 "$(count_component "$(probe_var PATH)" "$p/bin")" \
        "and left nothing on PATH"
}

test_the_init_function_passes_other_subcommands_straight_through() {
    mkenv a || return 1
    probe "$PROBE_SHELL" 'eval "$("$ZENV_BIN" init sh)"
PATH="$(dirname "$ZENV_BIN"):$PATH"
printf "PREFIX=[%s]\n" "$(zenv prefix a)"'
    assert_contains "$OUT" "PREFIX=[$(realpath_p "$ZENV_ROOT/a/zeek")]" \
        "'zenv prefix' must reach the real command"
}

test_init_output_parses_in_every_shell_and_defines_nothing_else() {
    for arg in '' sh bash zsh posix; do
        # shellcheck disable=SC2086  # deliberately unquoted: '' means no argument
        out=$(zenv init $arg 2>"$SANDBOX/e")
        assert_eq 0 "$?" "zenv init $arg must succeed"
        printf '%s\n' "$out" >"$SANDBOX/init.sh"
        if ! /bin/sh -n "$SANDBOX/init.sh" 2>"$SANDBOX/e2"; then
            fail "sh -n rejected 'zenv init $arg'"
            fail_detail "$(cat "$SANDBOX/e2")"
        fi
        # A bare `deactivate` would clobber the Python venv's function.
        assert_not_contains "$out" '
deactivate()' "must never define a bare deactivate"
        assert_not_contains "$out" '
deactivate ()' "must never define a bare deactivate"
    done
}

test_init_leaves_an_existing_deactivate_function_alone() {
    # ~/.zshrc sources a Python venv's activate, which defines deactivate. Taking
    # that name would break it, and unset -f on the way out would delete theirs.
    mkenv a || return 1
    probe "$PROBE_SHELL" 'deactivate() { printf "THEIRS\n"; }
eval "$("$ZENV_BIN" init sh)"
PATH="$(dirname "$ZENV_BIN"):$PATH"
zenv activate a
zenv deactivate
deactivate'
    assert_contains "$OUT" THEIRS "their deactivate must still be callable"
}

test_init_rejects_fish_with_an_explanation() {
    out=$(zenv init fish 2>&1)
    assert_ne 0 $? "fish must not be silently accepted"
    assert_contains "$out" fish "the message names fish"
    assert_contains "$out" 'zenv exec' "and points at the supported route"
}

test_the_activate_stub_activates_when_sourced() {
    mkenv a || return 1
    p=$(realpath_p "$ZENV_ROOT/a/zeek")
    assert_file "$ZENV_ROOT/a/activate" "zenv new writes the stub"

    probe "$PROBE_SHELL" 'PATH="$(dirname "$ZENV_BIN"):$PATH"
. "$ZENV_ROOT/a/activate"'

    assert_eq a "$(probe_var ZENV)" "sourcing the stub activates"
    assert_eq 1 "$(count_component "$(probe_var PATH)" "$p/bin")" \
        "and edits PATH exactly once"
}

test_the_activate_stub_leaves_the_deactivate_function_behind() {
    mkenv a || return 1
    probe "$PROBE_SHELL" 'PATH="$(dirname "$ZENV_BIN"):$PATH"
. "$ZENV_ROOT/a/activate"
_zenv_deactivate'
    assert_eq '<unset>' "$(probe_var ZENV)" \
        "the stub's activation must leave _zenv_deactivate behind and working"
}

test_activate_without_the_shell_function_explains_itself() {
    mkenv a || return 1
    out=$(zenv activate a 2>&1)
    assert_ne 0 $? "the subprocess form must fail rather than pretend"
    assert_contains "$out" 'zenv init' "and name the permanent fix"
    # With a real name to hand, the one-liner offered is that env's own stub.
    assert_contains "$out" ". $ZENV_ROOT/a/activate" "and the stub for right now"

    out=$(zenv deactivate 2>&1)
    assert_ne 0 $? "same for deactivate"
    assert_contains "$out" 'zenv init' "and name the permanent fix"
    assert_contains "$out" 'zenv shell deactivate' "and the direct eval form"

    # An unknown name has no stub to point at, so it falls back to the eval form
    # rather than naming a file that does not exist.
    out=$(zenv activate nosuch 2>&1)
    assert_contains "$out" 'zenv shell activate nosuch' "eval form for a bare name"
}

test_help_lists_the_activation_commands() {
    out=$(zenv help 2>&1)
    for want in 'init' 'activate' 'deactivate' 'shell activate' \
        'shell deactivate' 'ZENV_DISABLE_PROMPT'; do
        assert_contains "$out" "$want" "help must mention $want"
    done
}

test_no_activation_command_runs_a_build_tool() {
    mkbuildstubs || return 1
    mkenv a || return 1
    zenv shell activate a >/dev/null 2>&1
    zenv shell deactivate >/dev/null 2>&1
    zenv init sh >/dev/null 2>&1
    zenv activate a >/dev/null 2>&1
    zenv deactivate >/dev/null 2>&1
    assert_no_build_tool_ran
}

run_cases
