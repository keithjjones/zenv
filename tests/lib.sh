#!/bin/sh
# Test library for zenv: assertions, per-case sandbox, escape guard, and stubs.
#
# Sourced by every tests/test_*.sh. Must work when the test file is run by sh,
# bash and zsh, so: no arrays, no [[ ]], no ${x^^}. zsh does not word-split
# unquoted parameters by default, so anything that relies on splitting has to
# say so explicitly (see split_lines).
#
# shellcheck disable=SC2016
#   Single-quoted `$` in this file is shell code destined for somewhere else --
#   a probe shell, `zenv_lib`, or an emitted stub. Expanding it in this process
#   is exactly the bug these helpers exist to avoid.

if [ -n "${ZSH_VERSION:-}" ]; then
    # Only affects the harness itself. Emitted zenv code is always tested by
    # eval'ing it in a *fresh* shell with default options, never in here.
    setopt shwordsplit
fi

# The script that sourced us. zsh rebinds $0 to the *sourced* file, so under zsh
# $0 here is lib.sh, not the test file -- which silently made case discovery
# find nothing. ZSH_ARGZERO is the path zsh was invoked with and is immune.
if [ -n "${ZSH_VERSION:-}" ]; then
    ZENV_TEST_SELF=${ZSH_ARGZERO:-$0}
else
    ZENV_TEST_SELF=$0
fi

: "${ZENV_TEST_LIB_LOADED:=}"
if [ -n "$ZENV_TEST_LIB_LOADED" ]; then return 0; fi
ZENV_TEST_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# REPO_ROOT and RUNDIR are exported by run.sh. When a test file is executed
# directly (handy while developing) derive them here instead.
if [ -z "${REPO_ROOT:-}" ]; then
    REPO_ROOT=$(cd "$(dirname "$ZENV_TEST_SELF")/.." && pwd -P)
    export REPO_ROOT
fi
if [ -z "${RUNDIR:-}" ]; then
    RUNDIR=$(mktemp -d "${TMPDIR:-/tmp}/zenv-run.XXXXXX")
    export RUNDIR
fi
if [ -z "${ZENV_BIN:-}" ]; then
    ZENV_BIN="$REPO_ROOT/bin/zenv"
    export ZENV_BIN
fi
if [ -z "${REAL_HOME:-}" ]; then
    REAL_HOME=$HOME
    export REAL_HOME
fi

TEST_FILE=$ZENV_TEST_SELF
TEST_NAME=$(basename "$TEST_FILE" .sh)

# ---------------------------------------------------------------------------
# Result recording
#
# Assertions run inside a subshell (one per case), so counts cannot live in
# shell variables. Each failure appends a line to $FAILFILE; the parent decides
# pass/fail by whether that file is empty.
# ---------------------------------------------------------------------------

fail() {
    printf '    FAIL: %s\n' "$*" >>"$FAILFILE"
    printf '    FAIL: %s\n' "$*" >&2
    return 1
}

# Print context that makes a failure diagnosable without a re-run.
fail_detail() {
    printf '          %s\n' "$*" >>"$FAILFILE"
    printf '          %s\n' "$*" >&2
}

note() { printf '    note: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

assert_eq() {
    if [ "$1" = "$2" ]; then return 0; fi
    fail "${3:-values differ}"
    fail_detail "expected: [$1]"
    fail_detail "actual:   [$2]"
    return 1
}

assert_ne() {
    if [ "$1" != "$2" ]; then return 0; fi
    fail "${3:-values should differ}"
    fail_detail "both: [$1]"
    return 1
}

assert_contains() {
    case "$1" in
        *"$2"*) return 0 ;;
    esac
    fail "${3:-substring not found}"
    fail_detail "needle:   [$2]"
    fail_detail "haystack: [$1]"
    return 1
}

assert_not_contains() {
    case "$1" in
        *"$2"*)
            fail "${3:-substring should be absent}"
            fail_detail "needle:   [$2]"
            fail_detail "haystack: [$1]"
            return 1
            ;;
    esac
    return 0
}

assert_dir() {
    if [ -d "$1" ]; then return 0; fi
    fail "${2:-not a directory: $1}"
    return 1
}

assert_file() {
    if [ -f "$1" ]; then return 0; fi
    fail "${2:-not a regular file: $1}"
    return 1
}

assert_symlink() {
    if [ -L "$1" ]; then return 0; fi
    fail "${2:-not a symlink: $1}"
    return 1
}

assert_missing() {
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then return 0; fi
    fail "${2:-should not exist: $1}"
    return 1
}

# assert_symlink_to <link> <expected target as stored> [msg]
# Compares the *stored* target, so relative links stay relative.
assert_symlink_to() {
    if [ ! -L "$1" ]; then
        fail "${3:-not a symlink: $1}"
        return 1
    fi
    _got=$(readlink "$1")
    assert_eq "$2" "$_got" "${3:-symlink target differs for $1}"
}

# Run a command, capture stdout+stderr into $OUT, and check the exit status.
# Usage: assert_status <expected> <cmd> [args...]
assert_status() {
    _want=$1
    shift
    OUT=$("$@" 2>&1)
    _rc=$?
    if [ "$_rc" = "$_want" ]; then return 0; fi
    fail "exit status $_rc, expected $_want: $*"
    fail_detail "output: $OUT"
    return 1
}

# Capture stdout and stderr separately: sets OUT and ERR, returns the status.
# shellcheck disable=SC2034  # OUT and ERR are read by the test files, not here
capture() {
    _o="$SANDBOX/.capture.out"
    _e="$SANDBOX/.capture.err"
    "$@" >"$_o" 2>"$_e"
    _rc=$?
    OUT=$(cat "$_o")
    ERR=$(cat "$_e")
    return $_rc
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# zsh does not split unquoted parameters, so iterate lines through this.
# Usage: split_lines "$text" | while read -r line; do ...; done
split_lines() { printf '%s\n' "$1"; }

# Run the zenv under test.
zenv() { "$ZENV_BIN" "$@"; }

# zenv_lib <snippet> [arg...]
#
# Run a snippet with bin/zenv's functions loaded but no command dispatched, so
# the internal helpers are unit-tested as themselves. Always /bin/sh: that is the
# interpreter bin/zenv really runs under. Emitted *shell code* is what needs
# per-shell coverage, and that goes through probe() instead.
#
# Paths are passed as positional arguments and referenced as "$1", "$2" -- never
# spliced into the snippet text. An earlier version interpolated them, which the
# --hostile sandbox path (containing an apostrophe) broke immediately.
zenv_lib() {
    _snip=$1
    shift
    _s="$SANDBOX/.libunit.sh"
    {
        printf 'ZENV_LIB_ONLY=1\n'
        printf '. "$ZENV_BIN"\n'
        printf '%s\n' "$_snip"
    } >"$_s"
    OUT=$(/bin/sh "$_s" "$@" 2>&1)
}

# Resolve a path the way the tests expect: physical, no symlinks.
realpath_p() {
    if [ -d "$1" ]; then
        (cd -P "$1" 2>/dev/null && pwd -P)
    else
        _d=$(dirname "$1")
        _b=$(basename "$1")
        _r=$(cd -P "$_d" 2>/dev/null && pwd -P) || return 1
        case "$_r" in
            */) printf '%s%s\n' "$_r" "$_b" ;;
            *) printf '%s/%s\n' "$_r" "$_b" ;;
        esac
    fi
}

# ---------------------------------------------------------------------------
# Fake install prefix
#
# Builds enough of a Zeek install for zenv and the zkg stub to interrogate:
# a zeek-config answering every flag either one uses, plus the directories a
# real install would have. Every answer is overridable so a test can make a
# prefix *lie* about itself, which is how the finding-6 gate gets exercised.
#
# Usage: mkprefix <dir> [key=value ...]
#   keys: version prefix site_dir plugin_dir script_dir zeekpath zeek_dist
#         python_dir build_type include_dir broker_root config_dir cmake_dir
#         lib_dir bin_dir btest_tools_dir binpac_root
# ---------------------------------------------------------------------------

mkprefix() {
    _pfx=$1
    shift

    mkdir -p "$_pfx/bin" \
             "$_pfx/lib/zeek/python" \
             "$_pfx/lib/zeek/plugins" \
             "$_pfx/include/zeek" \
             "$_pfx/include/broker" \
             "$_pfx/share/zeek/site" \
             "$_pfx/share/zeek/base" \
             "$_pfx/share/zeek/policy" \
             "$_pfx/share/zeek/builtin-plugins" \
             "$_pfx/share/zeek/cmake" \
             "$_pfx/share/man/man1" \
             "$_pfx/etc/zeek"

    : >"$_pfx/include/broker/expected.hh"

    # Defaults, all derived from the prefix.
    _v_version=9.1.0-dev.1
    _v_prefix=$_pfx
    _v_site_dir="$_pfx/share/zeek/site"
    _v_plugin_dir="$_pfx/lib/zeek/plugins"
    _v_script_dir="$_pfx/share/zeek"
    _v_zeekpath=".:$_pfx/share/zeek:$_pfx/share/zeek/policy:$_pfx/share/zeek/site:$_pfx/share/zeek/builtin-plugins"
    _v_zeek_dist=""
    _v_python_dir="$_pfx/lib/zeek/python"
    _v_build_type=relwithdebinfo
    _v_include_dir="$_pfx/include"
    _v_broker_root="$_pfx"
    _v_config_dir="$_pfx/etc/zeek"
    _v_cmake_dir="$_pfx/share/zeek/cmake"
    _v_lib_dir="$_pfx/lib"
    _v_bin_dir="$_pfx/bin"
    _v_btest_tools_dir="$_pfx/share/zeek/btest"
    _v_binpac_root=$_pfx

    for _kv in "$@"; do
        _k=${_kv%%=*}
        _val=${_kv#*=}
        case $_k in
            version) _v_version=$_val ;;
            prefix) _v_prefix=$_val ;;
            site_dir) _v_site_dir=$_val ;;
            plugin_dir) _v_plugin_dir=$_val ;;
            script_dir) _v_script_dir=$_val ;;
            zeekpath) _v_zeekpath=$_val ;;
            zeek_dist) _v_zeek_dist=$_val ;;
            python_dir) _v_python_dir=$_val ;;
            build_type) _v_build_type=$_val ;;
            include_dir) _v_include_dir=$_val ;;
            broker_root) _v_broker_root=$_val ;;
            config_dir) _v_config_dir=$_val ;;
            cmake_dir) _v_cmake_dir=$_val ;;
            lib_dir) _v_lib_dir=$_val ;;
            bin_dir) _v_bin_dir=$_val ;;
            btest_tools_dir) _v_btest_tools_dir=$_val ;;
            binpac_root) _v_binpac_root=$_val ;;
            *) fail "mkprefix: unknown key '$_k'" ;;
        esac
    done

    # zeek-config: a real one answers several flags in a single invocation,
    # printing one line per flag in argument order. zkg autoconfig depends on
    # that, so the stub must do it too.
    {
        printf '#!/bin/sh\n'
        printf '# generated by tests/lib.sh mkprefix\n'
        printf 'v_version=%s\n' "$(quote_sh "$_v_version")"
        printf 'v_prefix=%s\n' "$(quote_sh "$_v_prefix")"
        printf 'v_site_dir=%s\n' "$(quote_sh "$_v_site_dir")"
        printf 'v_plugin_dir=%s\n' "$(quote_sh "$_v_plugin_dir")"
        printf 'v_script_dir=%s\n' "$(quote_sh "$_v_script_dir")"
        printf 'v_zeekpath=%s\n' "$(quote_sh "$_v_zeekpath")"
        printf 'v_zeek_dist=%s\n' "$(quote_sh "$_v_zeek_dist")"
        printf 'v_python_dir=%s\n' "$(quote_sh "$_v_python_dir")"
        printf 'v_build_type=%s\n' "$(quote_sh "$_v_build_type")"
        printf 'v_include_dir=%s\n' "$(quote_sh "$_v_include_dir")"
        printf 'v_broker_root=%s\n' "$(quote_sh "$_v_broker_root")"
        printf 'v_config_dir=%s\n' "$(quote_sh "$_v_config_dir")"
        printf 'v_cmake_dir=%s\n' "$(quote_sh "$_v_cmake_dir")"
        printf 'v_lib_dir=%s\n' "$(quote_sh "$_v_lib_dir")"
        printf 'v_bin_dir=%s\n' "$(quote_sh "$_v_bin_dir")"
        printf 'v_btest_tools_dir=%s\n' "$(quote_sh "$_v_btest_tools_dir")"
        printf 'v_binpac_root=%s\n' "$(quote_sh "$_v_binpac_root")"
        cat <<'EOF'

if [ -n "${ZEEK_CONFIG_STUB_LOG:-}" ]; then
    printf '%s\n' "$*" >>"$ZEEK_CONFIG_STUB_LOG"
fi

if [ $# -eq 0 ]; then
    echo "Usage: zeek-config [OPTIONS]" >&2
    exit 1
fi

status=0
for arg in "$@"; do
    case $arg in
        --version) echo "$v_version" ;;
        --prefix) echo "$v_prefix" ;;
        --site_dir) echo "$v_site_dir" ;;
        --plugin_dir) echo "$v_plugin_dir" ;;
        --script_dir) echo "$v_script_dir" ;;
        --zeekpath) echo "$v_zeekpath" ;;
        --zeek_dist) echo "$v_zeek_dist" ;;
        --python_dir) echo "$v_python_dir" ;;
        --build_type) echo "$v_build_type" ;;
        --include_dir) echo "$v_include_dir" ;;
        --broker_root) echo "$v_broker_root" ;;
        --config_dir) echo "$v_config_dir" ;;
        --cmake_dir) echo "$v_cmake_dir" ;;
        --lib_dir) echo "$v_lib_dir" ;;
        --bin_dir) echo "$v_bin_dir" ;;
        --btest_tools_dir) echo "$v_btest_tools_dir" ;;
        --binpac_root) echo "$v_binpac_root" ;;
        --have-*) echo no; status=1 ;;
        *) echo "zeek-config: unknown option $arg" >&2; exit 1 ;;
    esac
done
exit $status
EOF
    } >"$_pfx/bin/zeek-config"
    chmod +x "$_pfx/bin/zeek-config"

    # A zeek stub, so tests can check what ends up first on PATH.
    {
        printf '#!/bin/sh\n'
        printf 'prefix=%s\n' "$(quote_sh "$_pfx")"
        printf 'version=%s\n' "$(quote_sh "$_v_version")"
        cat <<'EOF'
case ${1:-} in
    --version|-v) printf '%s/bin/zeek version %s\n' "$prefix" "$version" ;;
    -N) printf 'stub plugin list for %s\n' "$prefix" ;;
    *) printf 'zeek stub %s args: %s\n' "$prefix" "$*" ;;
esac
EOF
    } >"$_pfx/bin/zeek"
    chmod +x "$_pfx/bin/zeek"

    : >"$_pfx/share/man/man1/zeek.1"
}

# Single-quote a string for safe inclusion in generated sh.
quote_sh() {
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

# Give a fake prefix a matching source tree, so zeek_dist verification passes.
# Usage: mkdist <tree> <version> [--no-build]
mkdist() {
    _tree=$1
    _ver=$2
    _nobuild=${3:-}
    mkdir -p "$_tree"
    printf '%s\n' "$_ver" >"$_tree/VERSION"
    if [ "$_nobuild" != "--no-build" ]; then
        mkdir -p "$_tree/build"
        _mangled=$(printf '%s' "$_ver" | tr '.-' '__')
        # The real header's shape, not just the one line zenv looks for. It names
        # ZEEK_VERSION_FUNCTION twice -- the #define, then an `extern` declaration
        # that carries no version -- and a stub with only the #define let zenv
        # keep the *last* matching line and call every real install drifted. A
        # stub that is easier to satisfy than the thing it stands for is worse
        # than no stub, so this one is copied from
        # ~/Source/zeek/build/zeek-version.h verbatim apart from the version.
        {
            printf '// See the file "COPYING" in the main distribution directory for copyright.\n\n'
            printf '#pragma once\n\n'
            printf '/* Version number of package */\n'
            printf '#define VERSION "%s"\n\n' "$_ver"
            printf '#define ZEEK_VERSION_NUMBER 90100\n\n'
            printf '/* A C function that has the Zeek version encoded into its name. */\n'
            printf '#define ZEEK_VERSION_FUNCTION zeek_version_%s_plugin_7\n' "$_mangled"
            printf '#ifdef __cplusplus\n'
            printf 'extern "C" {\n'
            printf '#endif\n'
            printf 'extern const char* ZEEK_VERSION_FUNCTION();\n'
            printf '#ifdef __cplusplus\n'
            printf '}\n'
            printf '#endif\n'
        } >"$_tree/build/zeek-version.h"
    fi
}

# Make a source tree a git checkout with one commit in it, and print the commit.
# zenv records the commit an environment was built from so it can name the one to
# check out again, and that is only testable against a real repository.
#
# The sandbox HOME has no gitconfig and the system one must not be consulted
# either, so identity comes from -c on every invocation. `mkgit_move` adds a
# second commit, which is what a `git pull` in a shared tree looks like.
# Usage: mkgit <tree> -> prints the sha ; mkgit_move <tree> -> prints the new sha
GIT_ID="-c user.name=zenv-tests -c user.email=tests@zenv.invalid"
mkgit() {
    have_git || return 1
    mkdir -p "$1"
    (
        GIT_CONFIG_NOSYSTEM=1
        GIT_TERMINAL_PROMPT=0
        export GIT_CONFIG_NOSYSTEM GIT_TERMINAL_PROMPT
        # shellcheck disable=SC2086  # GIT_ID is a deliberate word list of flags
        git -C "$1" -c init.defaultBranch=main init -q \
            && git -C "$1" $GIT_ID add -A \
            && git -C "$1" $GIT_ID commit -q -m 'zeek sources'
    ) >/dev/null 2>&1 || {
        fail "mkgit: could not make $1 a git checkout"
        return 1
    }
    git -C "$1" rev-parse HEAD
}

mkgit_move() {
    have_git || return 1
    (
        GIT_CONFIG_NOSYSTEM=1
        export GIT_CONFIG_NOSYSTEM
        printf 'moved on\n' >"$1/NEWFILE"
        # shellcheck disable=SC2086  # as above
        git -C "$1" $GIT_ID add -A \
            && git -C "$1" $GIT_ID commit -q -m 'a later commit'
    ) >/dev/null 2>&1 || {
        fail "mkgit_move: could not commit in $1"
        return 1
    }
    git -C "$1" rev-parse HEAD
}

# git is a stated requirement of zenv, but a case that needs one should skip
# rather than fail on a machine without it.
have_git() { command -v git >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Recording zkg stub
#
# Writes a plausible config the way `zkg autoconfig` would, and appends what it
# saw to $ZKG_STUB_LOG so a test can assert the exact invocation -- including
# "was never invoked" for the cases where zenv must refuse.
# ---------------------------------------------------------------------------

mkzkgstub() {
    _path=$1
    mkdir -p "$(dirname "$_path")"
    cat >"$_path" <<'EOF'
#!/bin/sh
# Recording zkg stub (tests/lib.sh mkzkgstub).
log=${ZKG_STUB_LOG:-/dev/null}
{
    printf '=== invocation\n'
    printf 'argv: %s\n' "$*"
    printf 'cwd: %s\n' "$(pwd -P)"
    printf 'ZKG_CONFIG_FILE: %s\n' "${ZKG_CONFIG_FILE-<unset>}"
    printf 'ZEEK_ZKG_CONFIG_DIR: %s\n' "${ZEEK_ZKG_CONFIG_DIR-<unset>}"
    printf 'ZEEK_ZKG_STATE_DIR: %s\n' "${ZEEK_ZKG_STATE_DIR-<unset>}"
    printf 'PATH: %s\n' "$PATH"
    for d in "${ZEEK_ZKG_CONFIG_DIR:-}" "${ZEEK_ZKG_STATE_DIR:-}"; do
        [ -n "$d" ] || continue
        if [ -d "$d" ]; then
            printf 'isdir %s: yes\n' "$d"
        else
            printf 'isdir %s: no\n' "$d"
        fi
    done
} >>"$log"

# Resolve the state/config dir the way the real zkg does: the environment
# override only counts when it is an existing directory.
statedir=$HOME/.zkg
if [ -n "${ZEEK_ZKG_STATE_DIR:-}" ] && [ -d "${ZEEK_ZKG_STATE_DIR:-}" ]; then
    statedir=$ZEEK_ZKG_STATE_DIR
fi
confdir=$HOME/.zkg
if [ -n "${ZEEK_ZKG_CONFIG_DIR:-}" ] && [ -d "${ZEEK_ZKG_CONFIG_DIR:-}" ]; then
    confdir=$ZEEK_ZKG_CONFIG_DIR
fi

cmd=${1:-}
case $cmd in
    autoconfig)
        zc=$(command -v zeek-config 2>/dev/null) || {
            echo "zkg stub: no zeek-config on PATH" >&2
            exit 1
        }
        site=$("$zc" --site_dir)
        plug=$("$zc" --plugin_dir)
        pfx=$("$zc" --prefix)
        dist=$("$zc" --zeek_dist)
        mkdir -p "$confdir"
        cfg=$confdir/config
        if [ ! -f "$cfg" ]; then
            {
                printf '[sources]\n'
                printf 'zeek = https://github.com/zeek/packages\n'
                printf '\n[paths]\n'
                printf 'state_dir = %s\n' "$statedir"
                printf 'script_dir = %s\n' "$site"
                printf 'plugin_dir = %s\n' "$plug"
                printf 'bin_dir = %s/bin\n' "$pfx"
                printf 'zeek_dist = %s\n' "$dist"
                printf '\n[templates]\n'
                printf 'default = https://github.com/zeek/package-template\n'
            } >"$cfg"
        else
            # Rewrite only the four keys real autoconfig writes, in place.
            tmp=$cfg.stub.$$
            while IFS= read -r line; do
                case $line in
                    script_dir\ =*) printf 'script_dir = %s\n' "$site" ;;
                    plugin_dir\ =*) printf 'plugin_dir = %s\n' "$plug" ;;
                    bin_dir\ =*) printf 'bin_dir = %s/bin\n' "$pfx" ;;
                    zeek_dist\ =*) printf 'zeek_dist = %s\n' "$dist" ;;
                    *) printf '%s\n' "$line" ;;
                esac
            done <"$cfg" >"$tmp"
            mv "$tmp" "$cfg"
        fi
        echo "zkg stub: wrote $cfg"
        ;;
    config)
        cfg=$confdir/config
        key=${2:-all}
        if [ ! -f "$cfg" ]; then
            echo "zkg stub: no config at $cfg" >&2
            exit 1
        fi
        if [ "$key" = all ]; then
            cat "$cfg"
        else
            sed -n "s/^$key = //p" "$cfg"
        fi
        ;;
    '')
        echo "zkg stub: no command" >&2
        exit 2
        ;;
    *)
        echo "zkg stub: unhandled command '$cmd'" >&2
        exit 3
        ;;
esac
EOF
    chmod +x "$_path"
}

# How many times the zkg stub ran.
#
# `grep -c` exits 1 on a *zero* count, so `grep -c … || echo 0` prints "0\n0" for
# an existing-but-empty log -- which reads as "not zero" to every caller. Capture
# the count and fall back only when grep itself failed.
zkg_invocations() {
    if _zin=$(grep -c '^=== invocation' "$ZKG_STUB_LOG" 2>/dev/null); then
        printf '%s\n' "$_zin"
    else
        printf '0\n'
    fi
}

assert_zkg_never_ran() {
    _n=$(zkg_invocations)
    if [ "$_n" = 0 ]; then return 0; fi
    fail "${1:-zkg should not have been invoked, but ran $_n time(s)}"
    fail_detail "log: $(cat "$ZKG_STUB_LOG")"
    return 1
}

zkg_log() { cat "$ZKG_STUB_LOG" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Shell probe
#
# Runs emitted code in a *fresh* shell with default options and dumps the
# resulting environment, so tests exercise what a user's shell would do rather
# than harness internals.
#
# Usage: probe <shell> <setup-code> ; sets OUT to the captured "VAR=value" dump
# ---------------------------------------------------------------------------

PROBE_VARS='PATH PYTHONPATH MANPATH ZEEKPATH ZEEK_PLUGIN_PATH ZKG_CONFIG_FILE ZEEK_ZKG_CONFIG_DIR ZEEK_ZKG_STATE_DIR ZEEK_DIST ZEEK_BUILD_DIR ZENV ZENV_PREFIX ZENV_ZKG_DIR PS1'

# The dump has to distinguish unset from empty, so it uses `eval` for indirect
# expansion (POSIX has no ${!v}). The variable list is inlined as literal words
# on one line: a newline inside `for x in ...` would end the list.
probe() {
    _shell=$1
    _code=$2
    _script="$SANDBOX/.probe.$$.sh"
    {
        printf '%s\n' "$_code"
        printf '\n_zenv_dump() {\n'
        printf '  for _v in %s; do\n' "$PROBE_VARS"
        printf '    eval "_set=\\${$_v+yes}"\n'
        printf '    eval "_val=\\${$_v-}"\n'
        printf '    if [ -n "$_set" ]; then\n'
        printf '      printf "%%s=%%s\\n" "$_v" "$_val"\n'
        printf '    else\n'
        printf '      printf "%%s<unset>\\n" "$_v"\n'
        printf '    fi\n'
        printf '  done\n'
        printf '}\n_zenv_dump\n'
    } >"$_script"
    OUT=$("$_shell" "$_script" 2>&1)
}

# Pull one variable out of a probe dump. Prints "<unset>" when unset.
probe_var() {
    printf '%s\n' "$OUT" | sed -n "s/^$1=//p;s/^$1<unset>$/<unset>/p" | head -1
}

# ---------------------------------------------------------------------------
# Escape guard
#
# The real ~/zeek, ~/.zkg and ~/zenv must be untouched by the suite. Checked
# three ways: the set of paths is unchanged, the *content* of the files a stray
# zkg would damage is unchanged, and nothing under them is newer than the
# reference stamp taken at guard_init.
#
# The mtime arm alone cannot say *who* touched a file, and one thing outside the
# suite touches these paths routinely: `eval `zkg env`` in ~/.zprofile, which
# every login shell runs. Constructing zkg's Manager no-op-refreshes the package
# source clone (a `git checkout master` into the same commit) and rewrites the
# autoloader with identical bytes -- so opening a terminal mid-run used to fail
# the whole suite. guard_check therefore separates two verdicts: a real escape
# (1), and activity that the suite provably cannot produce (2). The narrow
# allowance is safe because it is *not* the only thing standing between a case
# and the real home: sandbox_init fails any case whose HOME or ZENV_ROOT is not
# inside its sandbox, and a stray zkg that did more than refresh would change the
# path set or an autoloader's content, both of which still fail hard.
# ---------------------------------------------------------------------------

GUARD_PATHS="$REAL_HOME/zeek $REAL_HOME/.zkg $REAL_HOME/zenv"

guard_init() {
    GUARD_REF="$RUNDIR/guard.ref"
    GUARD_SNAP="$RUNDIR/guard.snap"
    GUARD_HASH="$RUNDIR/guard.hash"
    export GUARD_REF GUARD_SNAP GUARD_HASH
    guard_snapshot >"$GUARD_SNAP"
    guard_hashes >"$GUARD_HASH"
    # Stamp last, so only modifications made from here on are strictly newer.
    : >"$GUARD_REF"
}

guard_snapshot() {
    for _p in $GUARD_PATHS; do
        if [ -e "$_p" ] || [ -L "$_p" ]; then
            find "$_p" 2>/dev/null | LC_ALL=C sort
        else
            printf '%s: ABSENT\n' "$_p"
        fi
    done
}

# The files whose *bytes* matter: zkg's autoloaders -- the file finding 6 blanks
# -- and the real state dir's own bookkeeping.
# Symlinks are collected too, not just regular files: zkg's own layout makes
# site/packages/__load__.zeek a symlink to packages.zeek beside it, and leaving
# it out of the snapshot left the classifier with nothing to compare it against.
guard_sensitive() {
    for _p in $GUARD_PATHS; do
        [ -d "$_p" ] || continue
        find "$_p" ! -type d \( -name packages.zeek -o -name '__load__.zeek' \) \
            2>/dev/null
    done
    for _p in "$REAL_HOME/.zkg/config" "$REAL_HOME/.zkg/manifest.json" \
        "$REAL_HOME/zenv/config"; do
        [ -f "$_p" ] && printf '%s\n' "$_p"
    done
    return 0
}

# Content for anything that reads as a file (following symlinks), plus the target
# of every symlink -- so repointing one at different bytes is a content change and
# repointing it at identical bytes still shows up as a changed snapshot.
guard_hashes() {
    guard_sensitive | LC_ALL=C sort | while IFS= read -r _gf; do
        if [ -L "$_gf" ]; then
            printf 'link %s -> %s\n' "$_gf" "$(readlink "$_gf" 2>/dev/null)"
        fi
        [ -f "$_gf" ] || continue
        cksum "$_gf" 2>/dev/null || printf 'UNREADABLE %s\n' "$_gf"
    done
}

# One touched path: prints "ext <path>" for a change the suite cannot have made,
# "bad <path>" for anything else, and nothing at all when there is nothing to
# explain.
guard_classify() {
    _ge=$1
    # A directory's own mtime says nothing the path-set arm did not already check.
    if [ -d "$_ge" ] && [ ! -L "$_ge" ]; then
        return 0
    fi
    # git bookkeeping inside the real state dir's package source clones.
    case $_ge in
        "$REAL_HOME"/.zkg/clones/*/.git|"$REAL_HOME"/.zkg/clones/*/.git/*)
            printf 'ext %s\n' "$_ge"
            return 0
            ;;
    esac
    # A rewrite that changed no bytes. guard_hashes already covers these files,
    # so finding the same cksum line means nothing was lost.
    _gline=$(cksum "$_ge" 2>/dev/null) || _gline=
    if [ -n "$_gline" ] && grep -qxF "$_gline" "$GUARD_HASH"; then
        printf 'ext %s\n' "$_ge"
        return 0
    fi
    printf 'bad %s\n' "$_ge"
}

# 0 = untouched, 1 = escape (the suite reached the real home), 2 = changed only
# in ways the suite cannot produce (reported, not fatal).
guard_check() {
    _gbad=0
    _gext=
    _gnow="$RUNDIR/guard.now"
    guard_snapshot >"$_gnow"
    if ! cmp -s "$GUARD_SNAP" "$_gnow"; then
        printf 'ESCAPE GUARD: the set of real paths changed\n' >&2
        diff "$GUARD_SNAP" "$_gnow" 2>&1 | head -20 >&2
        _gbad=1
    fi

    _ghnow="$RUNDIR/guard.hash.now"
    guard_hashes >"$_ghnow"
    if ! cmp -s "$GUARD_HASH" "$_ghnow"; then
        printf 'ESCAPE GUARD: a zkg autoloader or state file changed content\n' >&2
        diff "$GUARD_HASH" "$_ghnow" 2>&1 | head -20 >&2
        _gbad=1
    fi

    for _p in $GUARD_PATHS; do
        [ -e "$_p" ] || continue
        _gtouched=$(find "$_p" -newer "$GUARD_REF" 2>/dev/null)
        [ -n "$_gtouched" ] || continue
        # Classified with a `while read`, not a `for`, so a path containing a
        # space is one entry rather than several. The classifier is a function
        # because a `case` inside `$( )` is mis-parsed by bash-as-sh, which reads
        # the `)` closing a pattern as the one closing the substitution.
        _gclass=$(
            printf '%s\n' "$_gtouched" | while IFS= read -r _gent; do
                guard_classify "$_gent"
            done
        )
        _gunex=$(printf '%s\n' "$_gclass" | sed -n 's/^bad //p')
        if [ -n "$_gunex" ]; then
            printf 'ESCAPE GUARD: modified under %s:\n' "$_p" >&2
            printf '%s\n' "$_gunex" | head -10 >&2
            _gbad=1
        fi
        _gseen=$(printf '%s\n' "$_gclass" | sed -n 's/^ext //p')
        if [ -n "$_gseen" ]; then
            _gext=$(printf '%s\n%s' "$_gext" "$_gseen")
        fi
    done

    [ "$_gbad" = 0 ] || return 1
    if [ -n "$_gext" ]; then
        printf 'GUARD NOTE: the real home was touched while the suite ran, but only\n' >&2
        printf '            in ways the suite cannot produce -- git bookkeeping under\n' >&2
        printf '            ~/.zkg/clones and byte-identical rewrites. A login shell\n' >&2
        printf '            running `eval `zkg env`` from ~/.zprofile does exactly this.\n' >&2
        printf '%s\n' "$_gext" | sed '/^$/d' | head -10 >&2
        return 2
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Per-case sandbox
# ---------------------------------------------------------------------------

# Sandbox root template. Overridden by run.sh --hostile to a path containing a
# space and an apostrophe, so the whole suite reruns against nasty quoting.
: "${ZENV_TEST_TMPL:=${TMPDIR:-/tmp}/zenv-sb.XXXXXX}"

sandbox_setup() {
    SANDBOX=$(mktemp -d "$ZENV_TEST_TMPL")
    SANDBOX=$(cd -P "$SANDBOX" && pwd -P)
    HOME="$SANDBOX/home"
    ZENV_ROOT="$HOME/zenv"
    ZKG_STUB_LOG="$SANDBOX/zkg-stub.log"
    ZEEK_CONFIG_STUB_LOG="$SANDBOX/zeek-config-stub.log"
    mkdir -p "$HOME" "$SANDBOX/bin"
    # A minimal PATH: system tools plus a sandbox bin for stubs. Deliberately
    # excludes the real ~/zeek/bin so a test can never reach the real install.
    PATH="$SANDBOX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    export HOME ZENV_ROOT PATH ZKG_STUB_LOG ZEEK_CONFIG_STUB_LOG SANDBOX
    # zenv must never see a stale activation from the harness.
    unset ZENV ZENV_PREFIX ZENV_ZKG_DIR 2>/dev/null || true
    unset ZEEKPATH ZEEK_PLUGIN_PATH ZKG_CONFIG_FILE 2>/dev/null || true
    unset ZEEK_ZKG_CONFIG_DIR ZEEK_ZKG_STATE_DIR 2>/dev/null || true
    unset ZEEK_DIST ZEEK_BUILD_DIR PYTHONPATH MANPATH 2>/dev/null || true
    cd "$SANDBOX" || exit 1
}

# Refuse to run a case whose sandbox is not actually isolated.
sandbox_verify() {
    case "$ZENV_ROOT" in
        "$SANDBOX"/*) ;;
        *)
            printf 'ESCAPE GUARD: ZENV_ROOT (%s) is outside the sandbox (%s)\n' \
                "$ZENV_ROOT" "$SANDBOX" >&2
            return 1
            ;;
    esac
    case "$HOME" in
        "$SANDBOX"/*) ;;
        *)
            printf 'ESCAPE GUARD: HOME (%s) is outside the sandbox (%s)\n' \
                "$HOME" "$SANDBOX" >&2
            return 1
            ;;
    esac
    if [ "$HOME" = "$REAL_HOME" ]; then
        printf 'ESCAPE GUARD: HOME still equals the real home\n' >&2
        return 1
    fi
    return 0
}

# The directory sandboxes are created in, resolved physically once. Derived
# from the template rather than hardcoded, because TMPDIR on macOS is
# /private/var/folders/... and --hostile puts sandboxes under $RUNDIR.
_sandbox_parent() {
    if [ -z "${ZENV_TEST_SBPARENT:-}" ]; then
        _p=$(dirname "$ZENV_TEST_TMPL")
        ZENV_TEST_SBPARENT=$(cd -P "$_p" 2>/dev/null && pwd -P) || ZENV_TEST_SBPARENT=$_p
        export ZENV_TEST_SBPARENT
    fi
    printf '%s\n' "$ZENV_TEST_SBPARENT"
}

sandbox_teardown() {
    cd / || return 0
    if [ -n "${ZENV_TEST_KEEP:-}" ]; then
        printf '    kept sandbox: %s\n' "$SANDBOX" >&2
        return 0
    fi
    # Remove only a path that is a direct child of the sandbox parent *and*
    # carries the template's basename prefix. Anything else is a bug in the
    # harness, and deleting it would be worse than leaking it.
    _parent=$(_sandbox_parent)
    _pfxname=$(basename "$ZENV_TEST_TMPL")
    _pfxname=${_pfxname%%X*}
    case "$SANDBOX" in
        "$_parent"/"$_pfxname"*)
            rm -rf "$SANDBOX"
            ;;
        *)
            printf '    refusing to remove unexpected sandbox: %s\n' "$SANDBOX" >&2
            printf '      (expected a %s/%s* path)\n' "$_parent" "$_pfxname" >&2
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Case runner
#
# Cases are the test file's own `test_*()` functions, discovered by reading the
# file rather than by shell introspection (which differs across sh/bash/zsh).
# ---------------------------------------------------------------------------

discover_cases() {
    sed -n 's/^\(test_[A-Za-z0-9_]*\)[[:space:]]*().*/\1/p' "$TEST_FILE"
}

run_cases() {
    _only=${ZENV_TEST_ONLY:-}
    _cases=$(discover_cases)
    if [ -z "$_cases" ]; then
        printf '%s: no test_* functions found\n' "$TEST_NAME" >&2
        exit 1
    fi

    _pass=0
    _failed=0
    for _case in $_cases; do
        if [ -n "$_only" ]; then
            case "$_case" in
                *"$_only"*) ;;
                *) continue ;;
            esac
        fi

        FAILFILE="$RUNDIR/fail.$$"
        : >"$FAILFILE"
        export FAILFILE

        sandbox_setup
        if ! sandbox_verify; then
            printf '  %-56s GUARD\n' "$_case"
            _failed=$((_failed + 1))
            sandbox_teardown
            continue
        fi

        # Subshell: a case cannot leak variables, cwd or traps into the next.
        ( "$_case" ) >"$SANDBOX/.case.out" 2>&1
        _rc=$?
        _out=$(cat "$SANDBOX/.case.out" 2>/dev/null)

        if [ -s "$FAILFILE" ] || [ "$_rc" != 0 ]; then
            printf '  %-56s FAIL\n' "$_case"
            if [ "$_rc" != 0 ] && [ ! -s "$FAILFILE" ]; then
                printf '    exited %s with no assertion failure\n' "$_rc"
            fi
            [ -n "$_out" ] && printf '%s\n' "$_out" | sed 's/^/    /'
            _failed=$((_failed + 1))
        else
            printf '  %-56s ok\n' "$_case"
            _pass=$((_pass + 1))
        fi
        sandbox_teardown
    done

    printf '%s: %s passed, %s failed\n' "$TEST_NAME" "$_pass" "$_failed"
    [ "$_failed" = 0 ]
}
