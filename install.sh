#!/bin/sh
# Install zenv: the script, the shell completions, and one marked block in your
# rc file.
#
# This installer builds nothing -- no more than zenv itself does. It copies files
# into $HOME/.local, and every path it writes is one `zenv uninstall` takes away
# again. That is why the three locations below are derived from $HOME rather than
# configurable: uninstall has to be able to find them with nothing but $HOME to
# go on, and a location it cannot predict is a file left behind forever.
#
#   ./install.sh                install, and add the rc block
#   ./install.sh --root DIR     also bake DIR as this machine's default ZENV_ROOT
#   ./install.sh --rc FILE      add the block to FILE instead of the default
#   ./install.sh --no-rc        touch no rc file at all
#   ./install.sh --dry-run      say what would happen, change nothing
#
# Reinstalling is safe, and is how you pick up a new zenv: every path is
# overwritten in place rather than added beside, so what is left is one copy and
# it is this checkout's. Without --root the root already baked into the installed
# script is preserved; a block that is already in some rc file is left alone
# rather than added a second time; and the pre-zenv rc backup, taken once, is
# never overwritten with the post-zenv file.

set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
SRC=$HERE/bin/zenv

# The same three paths bin/zenv's _un_paths() derives, and the same two markers
# its _rc_scan() looks for. tests/test_uninstall.sh asserts the two files agree,
# because a drift here is a file nobody ever removes.
SUBDIR=.local
RC_BEGIN='# >>> zenv >>>'
RC_END='# <<< zenv <<<'

ROOT=
ROOT_GIVEN=
RC=
NO_RC=
DRY=

say() { printf '%s\n' "$*" >&2; }
die() {
    printf 'install.sh: %s\n' "$*" >&2
    exit 1
}

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case $1 in
        --root)
            [ $# -ge 2 ] || die "--root needs a directory"
            ROOT=$2
            ROOT_GIVEN=1
            shift
            ;;
        --root=*)
            ROOT=${1#--root=}
            ROOT_GIVEN=1
            ;;
        --rc)
            [ $# -ge 2 ] || die "--rc needs a file"
            RC=$2
            shift
            ;;
        --rc=*) RC=${1#--rc=} ;;
        --no-rc) NO_RC=1 ;;
        --dry-run | -n) DRY=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "unknown argument '$1' (try --help)" ;;
    esac
    shift
done

[ -f "$SRC" ] || die "no bin/zenv beside this script (looked for $SRC)"
[ -n "${HOME:-}" ] || die "HOME is not set, so there is nowhere to install to"

BASE=$HOME/$SUBDIR
BIN=$BASE/bin/zenv
BASH_COMP=$BASE/share/bash-completion/completions/zenv
ZSH_COMP=$BASE/share/zsh/site-functions/_zenv

if [ -n "$ROOT_GIVEN" ]; then
    case $ROOT in
        /*) : ;;
        *) die "--root must be an absolute path, got '$ROOT'" ;;
    esac
    # Deliberately not created: the root comes into existence with the first
    # `zenv new` or `zenv adopt`, so an install that is later undone leaves no
    # empty directory behind.
    [ -d "$ROOT" ] || say "note: $ROOT does not exist yet; 'zenv new' creates it"
fi

# ---------------------------------------------------------------------------
# The one baked line
# ---------------------------------------------------------------------------

# The value baked into an already-installed script, so a reinstall without
# --root preserves it. Read with a loop rather than sed, since the value may
# contain any character a path may.
installed_root() {
    [ -f "$1" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
            ZENV_ROOT_DEFAULT=*) : ;;
            *) continue ;;
        esac
        line=${line#ZENV_ROOT_DEFAULT=}
        case $line in
            '"'*'"') line=${line#\"}; line=${line%\"} ;;
            "'"*"'") line=${line#\'}; line=${line%\'} ;;
        esac
        printf '%s' "$line"
        return 0
    done <"$1"
    return 1
}

# Copy <src> to <dst>, rewriting exactly the one ZENV_ROOT_DEFAULT= assignment.
# A read loop, not sed: a root containing '|', '&' or a backslash is a path like
# any other, and sed would read all three as syntax.
bake() {
    _bsrc=$1
    _bdst=$2
    _bval=$3
    _btmp=$_bdst.zenv-install.$$
    _bseen=
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
            ZENV_ROOT_DEFAULT=*)
                if [ -z "$_bseen" ]; then
                    printf 'ZENV_ROOT_DEFAULT="%s"\n' "$_bval"
                    _bseen=1
                    continue
                fi
                ;;
        esac
        printf '%s\n' "$line"
    done <"$_bsrc" >"$_btmp" || bake_died "cannot write $_btmp"
    # Written to a temp file and moved into place, so an install that fails
    # partway leaves the previous script whole rather than a half-copied one --
    # and the temp file goes with it, since a stray bin/zenv.zenv-install.NNNN is
    # exactly the artifact `zenv uninstall` cannot know to remove.
    [ -n "$_bseen" ] || bake_died "$_bsrc has no ZENV_ROOT_DEFAULT= line to rewrite"
    chmod +x "$_btmp" || bake_died "cannot chmod $_btmp"
    mv -f "$_btmp" "$_bdst" || bake_died "cannot install $_bdst"
}

bake_died() {
    rm -f "$_btmp"
    die "$*"
}

if [ -n "$ROOT_GIVEN" ]; then
    BAKE_ROOT=$ROOT
    BAKE_WHY="from --root"
elif BAKE_ROOT=$(installed_root "$BIN") && [ -n "$BAKE_ROOT" ]; then
    BAKE_WHY="preserved from the installed $BIN"
else
    BAKE_ROOT=
    BAKE_WHY=
fi

# ---------------------------------------------------------------------------
# Which rc file
# ---------------------------------------------------------------------------

first_existing() {
    for _fe in "$@"; do
        [ -f "$_fe" ] && {
            printf '%s' "$_fe"
            return 0
        }
    done
    return 1
}

pick_rc() {
    case ${SHELL:-/bin/sh} in
        *zsh)
            first_existing "$HOME/.zprofile" "$HOME/.zshrc" \
                || printf '%s' "$HOME/.zprofile"
            ;;
        *bash)
            first_existing "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.profile" \
                || printf '%s' "$HOME/.bash_profile"
            ;;
        *)
            first_existing "$HOME/.profile" || printf '%s' "$HOME/.profile"
            ;;
    esac
}

# Which flavour of `zenv init` the block should eval, named after the rc file the
# block is going into rather than after $SHELL -- the file is what decides which
# shell will read the line.
init_shell_for() {
    case ${1##*/} in
        .zprofile | .zshrc | .zlogin) printf 'zsh' ;;
        .bash_profile | .bashrc | .bash_login) printf 'bash' ;;
        *) printf 'sh' ;;
    esac
}

# Every file `zenv uninstall` searches, so "already installed somewhere" is the
# same question in both directions.
rc_candidates() {
    printf '%s\n' "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile" \
        "$HOME/.bashrc" "$HOME/.profile" "$HOME/.config/fish/config.fish"
}

has_block() { [ -f "$1" ] && grep -qxF "$RC_BEGIN" "$1"; }

rc_block() {
    # An unquoted here-doc with escaped '$', so the block reads the *shell's*
    # PATH and HOME when it runs, not this installer's.
    cat <<EOF
$RC_BEGIN
# Added by zenv's install.sh. 'zenv uninstall' removes this block exactly.
case ":\$PATH:" in *":\$HOME/$SUBDIR/bin:"*) ;; *) PATH="\$HOME/$SUBDIR/bin:\$PATH" ;; esac
eval "\$(zenv init $1)"
$RC_END
EOF
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

say "zenv install"
say "  from    $SRC"
say "  script  $BIN"
say "  bash    $BASH_COMP"
say "  zsh     $ZSH_COMP"
if [ -n "$BAKE_ROOT" ]; then
    say "  root    $BAKE_ROOT   ($BAKE_WHY)"
else
    say "  root    \$ZENV_ROOT, else \$HOME/zenv   (no baked default)"
fi
say ""

do_or_say() {
    # do_or_say <would> <did> <command...>
    _dw=$1
    _dd=$2
    shift 2
    if [ -n "$DRY" ]; then
        say "  would $_dw"
        return 0
    fi
    "$@" || die "cannot $_dw"
    say "  $_dd"
}

for d in "${BIN%/*}" "${BASH_COMP%/*}" "${ZSH_COMP%/*}"; do
    [ -d "$d" ] && continue
    do_or_say "create $d" "created $d" mkdir -p "$d"
done

do_or_say "install $BIN" "installed $BIN" bake "$SRC" "$BIN" "$BAKE_ROOT"

if [ -f "$HERE/completions/zenv.bash" ]; then
    do_or_say "install $BASH_COMP" "installed $BASH_COMP" \
        cp "$HERE/completions/zenv.bash" "$BASH_COMP"
else
    say "  no completions/zenv.bash beside this script -- skipped"
fi
if [ -f "$HERE/completions/_zenv" ]; then
    do_or_say "install $ZSH_COMP" "installed $ZSH_COMP" \
        cp "$HERE/completions/_zenv" "$ZSH_COMP"
else
    say "  no completions/_zenv beside this script -- skipped"
fi

# ---------------------------------------------------------------------------
# The rc block
# ---------------------------------------------------------------------------

add_block() {
    _abf=$1
    _abs=$2
    # The backup is taken before the first edit and never overwritten, so it stays
    # the file as it was before zenv ever touched it -- 'mv <file>.zenv-pre-install
    # <file>' is then a byte-for-byte undo, including any line zenv did not write
    # and will not put back.
    if [ -f "$_abf" ] && [ ! -f "$_abf.zenv-pre-install" ]; then
        do_or_say "copy $_abf to $_abf.zenv-pre-install" \
            "backed up $_abf to $_abf.zenv-pre-install" \
            cp "$_abf" "$_abf.zenv-pre-install"
    fi
    if [ -n "$DRY" ]; then
        say "  would append the zenv block to $_abf:"
        rc_block "$_abs" | sed 's/^/            /' >&2
        return 0
    fi
    # A file whose last line has no newline would otherwise swallow the start
    # marker. Uninstall cannot put that missing newline back, so it says so and
    # keeps the backup instead of claiming a clean removal.
    if [ -s "$_abf" ] && [ -n "$(tail -c 1 "$_abf")" ]; then
        printf '\n' >>"$_abf" || die "cannot append to $_abf"
        say "  added the newline $_abf was missing at the end"
    fi
    rc_block "$_abs" >>"$_abf" || die "cannot append to $_abf"
    say "  added the zenv block to $_abf"
}

if [ -n "$NO_RC" ]; then
    say ""
    say "no rc file touched (--no-rc). Set zenv up by hand with:"
    rc_block "$(init_shell_for "$(pick_rc)")" | sed 's/^/    /' >&2
else
    RC_HAS=
    rcs=$(rc_candidates)
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        has_block "$f" && RC_HAS=$f
    done <<EOF
$rcs
EOF

    if [ -n "$RC_HAS" ]; then
        say ""
        say "  the zenv block is already in $RC_HAS -- left as it is"
        say "  (nothing is added twice: the environment must not be applied twice)"
    else
        if [ -z "$RC" ]; then
            case ${SHELL:-} in
                */csh | */tcsh)
                    die "cannot auto-detect an rc file for csh/tcsh: the block
      install.sh would add is POSIX shell, which csh/tcsh cannot source.
      Install with --no-rc and use 'zenv exec <name> -- <cmd>' instead of
      activate/deactivate, or pass --rc FILE yourself if you really want the
      block in a POSIX-shell rc file (csh/tcsh will not read it, so nothing
      here would still activate for you)"
                    ;;
            esac
        fi
        [ -n "$RC" ] || RC=$(pick_rc)
        case $RC in
            /*) : ;;
            *) die "--rc must be an absolute path, got '$RC'" ;;
        esac
        case ${RC##*/} in
            config.fish)
                die "fish is not supported yet: 'zenv init fish' does not exist.
      install with --no-rc and translate the block by hand"
                ;;
        esac
        say ""
        add_block "$RC" "$(init_shell_for "$RC")"
    fi
fi

# ---------------------------------------------------------------------------
# Confirm
# ---------------------------------------------------------------------------

say ""
case ":${PATH:-}:" in
    *":$BASE/bin:"*) : ;;
    *)
        say "$BASE/bin is not on this shell's PATH yet. The block above fixes that"
        say "for new shells; for this one: PATH=\"$BASE/bin:\$PATH\""
        say ""
        ;;
esac

if [ -f "$ZSH_COMP" ] || [ -n "$DRY" ]; then
    # Not written into the rc block: it has to come *before* a compinit whose
    # position only you know, and a line zenv cannot place exactly is a line
    # 'zenv uninstall' cannot remove exactly.
    say "For zsh completion, if it does not appear, add this line to ~/.zshrc,"
    say "above compinit:"
    say "    fpath=(\$HOME/$SUBDIR/share/zsh/site-functions \$fpath)"
    say ""
fi

if [ -n "$DRY" ]; then
    say "--dry-run: nothing above was actually done."
    exit 0
fi

say "installed. Confirm with:  zenv version   (expect $("$BIN" version 2>/dev/null || echo '?'))"
say "Then:  zenv new dev   creates an environment and prints the --prefix to"
say "install Zeek into. zenv never builds it for you."
say ""
say "To undo all of this:  ./uninstall.sh --dry-run   then without --dry-run."
